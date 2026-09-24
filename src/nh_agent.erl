%
% SPDX-License-Identifier: Apache-2.0 OR LGPL-2.1-or-later
%

%%-----------------------------------------------------------------------------
%% @doc The device agent: socket, channel, heartbeat, and dispatch.
%%
%% This is the only long-lived process. `nh_channel' holds the protocol and
%% `nh_metadata' reads the firmware description; both are pure, and this loop
%% is what gives them a socket and a clock. Anything that blocks — a download,
%% a location lookup, a support script — runs in a process of its own and
%% reports back here.
%%
%% == The transport ==
%%
%% The transport is a module, not a hard dependency, so the agent can be driven
%% on a desktop against a real NervesHub before it runs on a chip:
%%
%% ```
%% Transport:open(Config)             -> {ok, Handle} | {error, term()}
%% Transport:send_text(Handle, Binary) -> ok | {error, term()}
%% Transport:close(Handle)            -> ok
%% '''
%%
%% and it delivers `{websocket, Handle, connected | {text, B} | {closed, R} |
%% {error, R}}'. `websocket_client' from atomvm_websocket_client already has
%% this shape.
%%
%% == Reconnection ==
%%
%% The agent reconnects, not the transport. A shared-secret signature is only
%% good for 90 seconds, and a transport that reconnects on its own replays the
%% headers it was opened with — so after the first minute and a half every
%% reconnect would be refused, and keep being refused, with the device looking
%% as though it were merely offline. So the transport is opened with its own
%% reconnection off, and when a connection is lost the agent closes it, waits a
%% backoff, and opens a new one with freshly signed headers.
%%
%% Every connection starts a fresh channel join, because a Phoenix channel does
%% not survive a socket reconnect.
%%
%% == Timers ==
%%
%% Everything this process waits for is kept as an absolute deadline in one
%% table, and the loop sleeps until the earliest. A `receive ... after' per
%% concern would not work: a steady stream of incoming messages would keep
%% pushing every timeout out, and a device would stop heartbeating while it
%% looked busy and healthy.
%% @end
%%-----------------------------------------------------------------------------
-module(nh_agent).

-export([start/1, start_link/1, stop/1]).

%% Exported so a supervisor or a test can run the loop directly.
-export([init/2, loop/1]).

%% What this agent tells NervesHub it speaks. 2.4.0 is the version that brings
%% device-managed updates; below 2.1.0 NervesHub types support scripts into the
%% console instead of sending them, and below 2.2.0 it never advertises
%% extensions. Claiming it is claiming all of them, so it moves with them.
-define(DEVICE_API_VERSION, <<"2.4.0">>).

%% The console version gates file transfer in NervesHub's UI, from 2.0.0. This
%% console declines file transfer, so it does not claim to take it.
-define(CONSOLE_VERSION, <<"1.0.0">>).

-define(EXTENSIONS, <<"extensions">>).
-define(LOGGING, <<"logging">>).

%% Long enough for a frame to leave the socket, short enough that an operator
%% does not notice.
-define(REBOOT_GRACE_MS, 250).

-define(DEFAULT_HEARTBEAT_MS, 30000).
-define(DEFAULT_RECONNECT_BACKOFF, {1000, 60000}).
%% A connection that has not come up in this long is not going to.
-define(DEFAULT_CONNECT_TIMEOUT_MS, 30000).
%% How long after joining to wait for `extensions:get' before joining the
%% extensions topic anyway, as an older NervesHub will never send it.
-define(EXTENSIONS_FALLBACK_MS, 5000).
%% What NervesHub gives a device-initiated request before it gives up.
-define(REQUEST_TIMEOUT_MS, 30000).
%% A download that has said nothing for this long has stalled: `ahttp_client'
%% has no receive timeout of its own, so without this it would wait forever.
-define(DEFAULT_DOWNLOAD_IDLE_MS, 120000).
-define(DEFAULT_LOG_FLUSH_MS, 10000).
-define(DEFAULT_LOG_BUFFER, 100).
-define(DEFAULT_NETWORK_INTERFACE, <<"wlan0">>).
-define(DEFAULT_TRIAL, #{boot_attempts => 3, join_timeout_ms => 300000}).
%% Replies to extension pushes are matched by reference; this many are kept.
-define(EXT_REFS_KEPT, 16).

-type config() :: #{
    url => binary() | string(),
    host => binary() | string(),
    identifier := binary(),
    transport => module(),
    shared_secret => {binary(), binary()},
    client_cert => {binary(), binary()},
    verify => term(),
    metadata => map(),
    handler => pid(),
    heartbeat_ms => pos_integer(),
    reconnect_backoff => {pos_integer(), pos_integer()},
    network_interface => binary(),
    firmware_trial => #{boot_attempts => pos_integer(), join_timeout_ms => pos_integer()} | off,
    log_flush_ms => pos_integer(),
    log_buffer => pos_integer()
}.

-export_type([config/0]).

%%-----------------------------------------------------------------------------
%% @doc Start the agent, linked to the caller.
%% @end
%%-----------------------------------------------------------------------------
-spec start_link(config()) -> {ok, pid()} | {error, term()}.
start_link(Config) ->
    Owner = maps:get(handler, Config, self()),
    named(spawn_link(?MODULE, init, [Config, Owner]), Config).

-spec start(config()) -> {ok, pid()} | {error, term()}.
start(Config) ->
    Owner = maps:get(handler, Config, self()),
    named(spawn(?MODULE, init, [Config, Owner]), Config).

%% `register => Name' gives the agent a name so that something configured
%% before it existed can find it later -- `nh_logger' is the reason, since a
%% `logger' handler is set up at startup and the agent connects afterwards.
%%
%% A name already taken is an error rather than something to take over: the
%% holder may be a working agent, and stealing its name would leave logs going
%% to a process nothing else can reach.
named(Pid, Config) ->
    case maps:get(register, Config, undefined) of
        undefined ->
            {ok, Pid};
        Name when is_atom(Name) ->
            try
                true = register(Name, Pid),
                {ok, Pid}
            catch
                _:_ ->
                    Pid ! stop,
                    {error, {name_taken, Name}}
            end;
        Other ->
            Pid ! stop,
            {error, {invalid_register, Other}}
    end.

-spec stop(pid()) -> ok.
stop(Pid) ->
    Pid ! stop,
    ok.

%% @private
init(Config, Owner) ->
    Transport = maps:get(transport, Config, websocket_client),
    Extensions = nh_extensions:new(Config),

    State0 = #{
        config => Config,
        transport => Transport,
        handle => undefined,
        socket_up => false,
        owner => Owner,
        esp => maps:get(esp, Config, esp),
        updates => maps:get(updates, Config, auto),
        firmware_keys => stash_keys(maps:get(firmware_keys, Config, [])),
        reboot => maps:get(reboot, Config, auto),
        console => nh_console:new(),
        extensions => Extensions,
        log_buffer => nh_log_buffer:new(maps:get(log_buffer, Config, ?DEFAULT_LOG_BUFFER)),
        ext_refs => [],
        heartbeat_ms => maps:get(heartbeat_ms, Config, ?DEFAULT_HEARTBEAT_MS),
        reconnect_attempt => 0,
        requests => #{},
        scripts => #{},
        update_mode => undefined,
        timers => #{}
    },

    State1 = begin_trial(State0),
    Channel = maybe_add_extensions(
        maybe_add_console(nh_channel:new(join_params(State1)), Config), Extensions
    ),

    case open(State1#{channel => Channel}) of
        {ok, State2} ->
            loop(State2);
        {error, Reason} ->
            Owner ! {nerves_hub, {transport_error, Reason}},
            exit({transport_error, Reason})
    end.

%% Opening signs the headers, so a reopen is signed at the moment it is made.
%% A config the URL cannot be built from is reported the same way a refused
%% connection is, rather than crashing on a badmatch here. `nerves_hub_link'
%% catches it earlier; this is the path for using the agent directly.
open(#{transport := Transport, config := Config} = State) ->
    case nh_url:resolve(Config) of
        {ok, Url} ->
            case Transport:open(transport_config(Config, Url)) of
                {ok, Handle} ->
                    Deadline = maps:get(connect_timeout_ms, Config, ?DEFAULT_CONNECT_TIMEOUT_MS),
                    {ok, set_timer(connect_timeout, Deadline, State#{handle => Handle})};
                {error, _} = Error ->
                    Error
            end;
        {error, _} = Error ->
            Error
    end.

%% @private
loop(State) ->
    {Timer, Timeout} = next_timer(State),

    receive
        {websocket, Handle, Event} ->
            loop(socket_event(Handle, Event, State));
        {nh_ext_geo, _Pid, Location} ->
            loop(push_extension(nh_ext_geo:event(), Location, State));
        {nh_ota, Pid, Message} ->
            loop(updater_message(Pid, Message, State));
        {nh_scripts, Ref, Result} ->
            loop(script_finished(Ref, Result, State));
        {'DOWN', _Ref, process, Pid, Reason} ->
            loop(process_down(Pid, Reason, State));
        {push_extension, Event, Payload} ->
            loop(extension_out(Event, Payload, State));
        {push, Event, Payload} ->
            loop(push_event(Event, Payload, State));
        {call, From, Tag, Request} ->
            loop(call(Request, From, Tag, State));
        {update_decision, Decision} ->
            loop(update_decision(Decision, State));
        stop ->
            case maps:get(handle, State) of
                undefined -> ok;
                Handle -> (maps:get(transport, State)):close(Handle)
            end,
            ok;
        Other ->
            notify(State, {unexpected, Other}),
            loop(State)
    after Timeout ->
        loop(fire(Timer, cancel_timer(Timer, State)))
    end.

%% ------------------------------------------------------------------ the socket

%% Anything from a handle that is not the current one is from a connection
%% already given up on, and a late `closed' from it must not tear down the one
%% that replaced it.
socket_event(Handle, Event, #{handle := Handle} = State) ->
    socket_event(Event, State);
socket_event(_Stale, _Event, State) ->
    State.

socket_event(connected, State0) ->
    %% A fresh join on every connection, including reconnections.
    State1 = cancel_timer(connect_timeout, State0),
    {Channel, Actions} = nh_channel:connected(maps:get(channel, State1)),
    State2 = run(Actions, State1#{channel => Channel, socket_up => true, reconnect_attempt => 0}),
    schedule_heartbeat(State2);
socket_event({text, Text}, State) ->
    {Channel, Actions} = nh_channel:handle_text(Text, maps:get(channel, State)),
    run(Actions, State#{channel => Channel});
socket_event({closed, Reason}, State) ->
    lost({disconnected, Reason}, State);
socket_event({error, Reason}, #{socket_up := true} = State) ->
    %% Reported, but the connection is not given up on for it: the transport
    %% follows an error that ends the connection with `closed'.
    notify(State, {transport_error, Reason}),
    State;
socket_event({error, Reason}, State) ->
    %% Before `connected', an error is the connection attempt failing.
    lost({transport_error, Reason}, State).

%% The join is gone with the socket, but the channel is not rebuilt: that would
%% restart reference numbering and drop the join parameters, so a reconnected
%% device would report no firmware at all.
lost(Why, #{transport := Transport, handle := Handle} = State0) ->
    notify(State0, Why),
    _ = Transport:close(Handle),
    State1 = fail_requests(disconnected, State0),
    State2 = lists:foldl(
        fun cancel_timer/2,
        State1,
        [heartbeat, connect_timeout, extensions_fallback, log_flush]
    ),
    schedule_reconnect(State2#{
        handle => undefined,
        socket_up => false,
        channel => nh_channel:disconnected(maps:get(channel, State2)),
        %% Nothing is attached without a channel to be attached on. Log lines
        %% are held until the next join says where they can go.
        extensions => nh_extensions:disconnected(maps:get(extensions, State2))
    }).

schedule_reconnect(#{config := Config, reconnect_attempt := Attempt} = State) ->
    {Min, Max} = maps:get(reconnect_backoff, Config, ?DEFAULT_RECONNECT_BACKOFF),
    Delay = nh_backoff:delay(Attempt, Min, Max),
    set_timer(reconnect, Delay, State#{reconnect_attempt => Attempt + 1}).

reconnect(State) ->
    case open(State) of
        {ok, Opened} ->
            Opened;
        {error, Reason} ->
            notify(State, {transport_error, Reason}),
            schedule_reconnect(State)
    end.

%% -------------------------------------------------------------------- timers

fire(heartbeat, State) ->
    {Channel, Actions} = nh_channel:heartbeat(maps:get(channel, State)),
    schedule_heartbeat(run(Actions, State#{channel => Channel}));
fire(reconnect, State) ->
    reconnect(State);
fire(connect_timeout, State) ->
    lost({transport_error, connect_timeout}, State);
fire(extensions_fallback, State) ->
    join_extensions(undefined, State);
fire(log_flush, State) ->
    flush_logs(State);
fire(trial_deadline, State) ->
    trial_expired(State);
fire(update_idle, State) ->
    update_stalled(State);
fire({request, Kind}, State) ->
    reply_request(Kind, {error, timeout}, State);
fire({script, Ref}, State) ->
    script_timed_out(Ref, State);
fire(none, State) ->
    State.

set_timer(Name, Ms, #{timers := Timers} = State) ->
    State#{timers => Timers#{Name => now_ms() + Ms}}.

cancel_timer(Name, #{timers := Timers} = State) ->
    State#{timers => maps:remove(Name, Timers)}.

next_timer(#{timers := Timers}) ->
    case maps:to_list(Timers) of
        [] ->
            {none, infinity};
        Pairs ->
            {Name, At} = lists:foldl(
                fun
                    ({_, A} = P, {_, Best}) when A < Best -> P;
                    (_, Acc) -> Acc
                end,
                hd(Pairs),
                Pairs
            ),
            {Name, max(0, At - now_ms())}
    end.

schedule_heartbeat(#{heartbeat_ms := Ms} = State) ->
    set_timer(heartbeat, Ms, State).

%% ------------------------------------------------------------------ dispatch

run(Actions, State) ->
    lists:foldl(fun run_action/2, State, Actions).

run_action({send, Frame}, State) ->
    Transport = maps:get(transport, State),
    case maps:get(handle, State) of
        undefined ->
            State;
        Handle ->
            case Transport:send_text(Handle, Frame) of
                ok ->
                    State;
                {error, Reason} ->
                    notify(State, {send_failed, Reason}),
                    State
            end
    end;
run_action({event, Event}, State) ->
    handle_event(Event, State).

%% The device topic is the one the owner hears about unqualified, because it is
%% the one that means "this device is talking to NervesHub". Any other topic is
%% reported by name.
handle_event({joined, <<"device">>, Response}, State) ->
    notify(State, {joined, Response}),
    State1 = validate_pending(State),
    State2 = push_event(
        <<"report_network_interface">>, #{<<"interface">> => network_interface(State1)}, State1
    ),
    case nh_extensions:enabled(maps:get(extensions, State2)) of
        [] ->
            State2;
        _Some ->
            Wait = maps:get(
                extensions_fallback_ms, maps:get(config, State2), ?EXTENSIONS_FALLBACK_MS
            ),
            set_timer(extensions_fallback, Wait, State2)
    end;
handle_event({joined, ?EXTENSIONS, Response}, State) ->
    {Extensions, Actions} = nh_extensions:attach(Response, maps:get(extensions, State)),
    notify(State, {extensions_attached, nh_extensions:attached(Extensions)}),
    flush_logs(run_extension_actions(Actions, State#{extensions => Extensions}));
handle_event({message, ?EXTENSIONS, Event, Payload}, State) ->
    {Extensions, Actions} = nh_extensions:handle_event(Event, Payload, maps:get(extensions, State)),
    flush_logs(run_extension_actions(Actions, State#{extensions => Extensions}));
handle_event({reply, ?EXTENSIONS, Ref, <<"error">>, <<"detach">>}, State) ->
    extension_refused(Ref, State);
handle_event({joined, <<"console">>, _Response}, State) ->
    notify(State, console_joined),
    console_out(nh_console:banner(), State);
handle_event({joined, Topic, Response}, State) ->
    notify(State, {joined, Topic, Response}),
    State;
handle_event({join_error, <<"device">>, Reason}, State) ->
    notify(State, {join_error, Reason}),
    State;
handle_event({join_error, Topic, Reason}, State) ->
    notify(State, {join_error, Topic, Reason}),
    State;
handle_event({message, <<"console">>, <<"dn">>, Payload}, State) ->
    Data = maps:get(<<"data">>, Payload, <<>>),
    {Console, Output} = nh_console:handle_input(Data, maps:get(console, State)),
    console_out(Output, State#{console => Console});
handle_event({message, <<"console">>, <<"restart">>, _Payload}, State) ->
    {Console, Output} = nh_console:restart(maps:get(console, State)),
    console_out(Output, State#{console => Console});
%% Sent whenever the operator resizes their terminal. Nothing here wraps text,
%% so there is nothing to do with it — but it must not read as unhandled.
handle_event({message, <<"console">>, <<"window_size">>, _Payload}, State) ->
    State;
%% `file-data/*' pushes a file at a device with a filesystem to put it in. This
%% one has partitions, and silently accepting bytes nothing will ever write
%% would be worse than saying so.
handle_event({message, <<"console">>, <<"file-data/start">>, _Payload}, State) ->
    console_out(
        <<"\r\nfile transfer is not supported on this device\r\n", (nh_console:prompt())/binary>>,
        State
    );
handle_event({message, <<"console">>, <<"file-data">>, _Payload}, State) ->
    State;
handle_event({message, <<"console">>, <<"file-data/stop">>, _Payload}, State) ->
    State;
%% NervesHub answers a join that asked for them. Added to the configured keys
%% rather than replacing them: a key that arrived over the socket is only as
%% trustworthy as the server that sent it, so it can widen what a device
%% accepts but must never be the reason it accepts something.
handle_event({message, _Topic, <<"fwup_public_keys">>, Payload}, State) ->
    Received = decode_keys(maps:get(<<"keys">>, Payload, [])),
    Keys = lists:usort(maps:get(firmware_keys, State, []) ++ Received),

    notify(State, {firmware_keys, length(Keys)}),
    State#{firmware_keys => stash_keys(Keys)};
%% An operator asked for this one explicitly, so it is not deferred to the
%% application the way an armed update is.
handle_event({message, _Topic, <<"reboot">>, _Payload}, State) ->
    notify(State, reboot_requested),
    State1 = push_event(<<"rebooting">>, #{}, State),

    case maps:get(reboot, State1, auto) of
        auto -> reboot(State1);
        _Manual -> State1
    end;
%% Only the application knows what identifying looks like on its hardware --
%% an LED, a buzzer, a line on a display -- so this is reported, not acted on.
handle_event({message, _Topic, <<"identify">>, _Payload}, State) ->
    notify(State, identify),
    State;
handle_event({message, _Topic, <<"update">>, Payload}, State) ->
    notify(State, {message, <<"update">>, Payload}),
    update_offered(Payload, State);
handle_event({message, <<"device">>, <<"update_available">>, Payload}, State) ->
    Result = #{
        available => maps:get(<<"available">>, Payload, false) =:= true,
        firmware_meta => maps:get(<<"firmware_meta">>, Payload, null)
    },
    reply_request(check_update, {ok, Result}, State);
handle_event({message, <<"device">>, <<"update_rejected">>, Payload}, State) ->
    Reason = rejection(maps:get(<<"reason">>, Payload, undefined)),
    notify(State, {update_rejected, Reason}),
    reply_request(request_update, {error, Reason}, State);
handle_event({message, <<"device">>, <<"update_mode">>, Payload}, State) ->
    update_mode_changed(Payload, State);
handle_event({message, <<"device">>, <<"extensions:get">>, Payload}, State) ->
    join_extensions(Payload, State);
handle_event({message, <<"device">>, <<"scripts/run">>, Payload}, State) ->
    start_script(Payload, State);
handle_event({message, _Topic, Event, Payload}, State) ->
    notify(State, {message, Event, Payload}),
    State;
handle_event(Other, State) ->
    notify(State, Other),
    State.

%% --------------------------------------------------------------- the trial

%% Counted before anything else can go wrong, so a firmware that crashes on the
%% way to connecting still uses up a boot. See `nh_ota:begin_trial/2'.
begin_trial(#{config := Config} = State) ->
    case maps:get(firmware_trial, Config, ?DEFAULT_TRIAL) of
        off ->
            State#{trial => none};
        Trial when is_map(Trial) ->
            Settings = maps:merge(?DEFAULT_TRIAL, Trial),
            case nh_ota:begin_trial(maps:get(boot_attempts, Settings), ota_opts(State)) of
                none ->
                    State#{trial => none};
                {trial, Slot, Attempt} ->
                    notify(State, {firmware_trial, Slot, Attempt}),
                    set_timer(
                        trial_deadline,
                        maps:get(join_timeout_ms, Settings),
                        State#{trial => {Slot, Attempt}}
                    );
                {reverted, Previous} ->
                    notify(State, {firmware_reverted, Previous}),
                    after_revert(State#{trial => none})
            end
    end.

%% Firmware that cannot reach NervesHub in the time it was given is firmware
%% nothing could recover remotely, so it goes back to what worked.
trial_expired(State) ->
    case nh_ota:revert(ota_opts(State)) of
        {ok, Previous} ->
            notify(State, {firmware_reverted, Previous}),
            after_revert(State#{trial => none});
        {error, Reason} ->
            notify(State, {firmware_revert_failed, Reason}),
            State#{trial => none}
    end.

%% The boot path already points back; nothing has changed until a restart.
%% `reboot => manual' leaves that to the application as it does for every
%% other restart, having told it why.
after_revert(State) ->
    case maps:get(reboot, State, auto) of
        auto -> reboot(State);
        _Manual -> State
    end.

%% A device that has just taken an update is on trial until it gets here.
%% Joining is the evidence this library accepts: firmware that cannot reach
%% NervesHub is firmware nothing could recover from remotely, so it is exactly
%% what must not be committed.
validate_pending(State0) ->
    State = cancel_timer(trial_deadline, State0),
    case nh_ota:pending(ota_opts(State)) of
        none ->
            State;
        {ok, Slot} ->
            case nh_ota:commit(ota_opts(State)) of
                ok ->
                    notify(State, {firmware_committed, Slot}),
                    State1 = refresh_join_params(State#{trial => none}),
                    push_event(<<"firmware_validated">>, #{}, State1);
                {error, Reason} ->
                    notify(State, {firmware_commit_failed, Reason}),
                    State
            end
    end.

ota_opts(#{esp := Esp}) -> #{esp => Esp}.

%% ------------------------------------------------------------------ updates

%% `updates => auto' installs what NervesHub offers. `manual' only reports the
%% offer, as `{message, <<"update">>, Payload}', and waits for the application
%% to decide with `nerves_hub_link:apply_update/2', `ignore_update/2' or
%% `reschedule_update/3'. An update the device asked for with
%% `request_update/1' is installed either way: asking was the decision.
update_offered(Payload, State) ->
    Available = maps:get(<<"update_available">>, Payload, false) =:= true,
    Requested = maps:is_key(request_update, maps:get(requests, State)),
    Busy = maps:is_key(update, State),

    case {Available, Busy, Requested orelse maps:get(updates, State, auto) =:= auto} of
        {false, _, _} ->
            State;
        {true, true, _} ->
            %% One at a time. A second `update' while a download is in flight
            %% is the server repeating itself, not a new job.
            State;
        {true, false, true} ->
            reply_request(request_update, ok, start_update(Payload, State));
        {true, false, false} ->
            State
    end.

update_decision(_Decision, #{update := _Pid} = State) ->
    notify(State, {update_decision_ignored, updating}),
    State;
update_decision({apply, Payload}, State) ->
    start_update(Payload, State);
update_decision({ignore, Reason}, State) ->
    status_update(<<"ignored">>, #{<<"reason">> => Reason}, State);
update_decision({reschedule, DelayMs, Reason}, State) ->
    status_update(<<"rescheduled">>, #{<<"delay_for">> => DelayMs, <<"reason">> => Reason}, State).

start_update(Payload, State0) ->
    State = status_update(<<"received">>, #{}, State0),
    Pid = nh_ota:start_update(Payload, self(), #{keys => maps:get(firmware_keys, State, [])}),
    notify(State, {update_started, Pid}),
    download_alive(State#{update => Pid}).

%% Everything the downloader says is a sign it is still getting somewhere.
download_alive(#{config := Config} = State) ->
    set_timer(update_idle, maps:get(download_idle_ms, Config, ?DEFAULT_DOWNLOAD_IDLE_MS), State).

updater_message(Pid, Message, #{update := Pid} = State) ->
    updater(Message, State);
updater_message(_Stale, _Message, State) ->
    State.

updater(started, State) ->
    download_alive(
        status_update(
            <<"started">>, #{<<"downloader_network_interface">> => network_interface(State)}, State
        )
    );
updater({progress, Percent}, State) ->
    download_alive(
        push_event(
            <<"update_progress">>,
            #{<<"value">> => Percent, <<"stage">> => <<"downloading">>},
            State
        )
    );
updater({ok, Slot}, State) ->
    %% Written and armed, not yet running. Rebooting is the application's
    %% call: it may have work to finish first, and a library that restarts a
    %% device on its own is a library that surprises someone.
    notify(State, {update_ready, Slot}),
    State1 = status_update(<<"completed">>, #{}, State),
    cancel_timer(update_idle, maps:remove(update, State1));
updater({error, Reason}, State) ->
    update_failed(Reason, describe(Reason), State).

update_stalled(#{update := Pid} = State) ->
    exit(Pid, kill),
    update_failed(download_stalled, <<"download_stalled">>, State);
update_stalled(State) ->
    State.

update_failed(Reason, Described, State) ->
    notify(State, {update_failed, Reason}),
    State1 = status_update(<<"failed">>, #{<<"reason">> => Described}, State),
    cancel_timer(update_idle, maps:remove(update, State1)).

status_update(Status, Extra, State) ->
    push_event(<<"status_update">>, Extra#{<<"status">> => Status}, State).

%% A downloader that exits normally has already sent its result. One that dies
%% any other way has not, and nothing else would ever say so.
process_down(Pid, Reason, #{update := Pid} = State) when Reason =/= normal ->
    update_failed({updater_crashed, Reason}, <<"updater_crashed">>, State);
process_down(Pid, Reason, #{scripts := Scripts} = State) when is_map_key(Pid, Scripts) ->
    script_crashed(Pid, Reason, State);
process_down(_Pid, _Reason, State) ->
    State.

%% ------------------------------------------------------- device-managed updates

%% Requests the application makes of NervesHub, answered by a message NervesHub
%% sends back later. One of each kind at a time, and none without a channel to
%% send it on.
call(update_mode, From, Tag, State) ->
    reply(From, Tag, update_mode_reply(maps:get(update_mode, State))),
    State;
call(Request, From, Tag, State) ->
    Kind = request_kind(Request),
    Requests = maps:get(requests, State),
    Joined = nh_channel:joined(maps:get(channel, State)),

    if
        not Joined ->
            reply(From, Tag, {error, disconnected}),
            State;
        is_map_key(Kind, Requests) ->
            reply(From, Tag, {error, already_in_progress}),
            State;
        Kind =:= request_update, is_map_key(update, State) ->
            reply(From, Tag, {error, updating}),
            State;
        true ->
            send_request(Request, Kind, From, Tag, State)
    end.

request_kind(check_update) -> check_update;
request_kind(request_update) -> request_update;
request_kind({set_update_mode, _Mode}) -> set_update_mode.

send_request(check_update, Kind, From, Tag, State) ->
    track(Kind, From, Tag, push_event(<<"check_update">>, #{}, State));
send_request(request_update, Kind, From, Tag, State) ->
    track(Kind, From, Tag, push_event(<<"request_update">>, #{}, State));
send_request({set_update_mode, Mode}, Kind, From, Tag, State) ->
    track(Kind, From, Tag, push_event(<<"set_update_mode">>, #{<<"mode">> => Mode}, State)).

track(Kind, From, Tag, #{requests := Requests} = State) ->
    set_timer({request, Kind}, ?REQUEST_TIMEOUT_MS, State#{
        requests => Requests#{Kind => {From, Tag}}
    }).

%% Not `maps:take/2', which AtomVM does not have.
reply_request(Kind, Reply, #{requests := Requests} = State) ->
    case maps:find(Kind, Requests) of
        {ok, {From, Tag}} ->
            reply(From, Tag, Reply),
            cancel_timer({request, Kind}, State#{requests => maps:remove(Kind, Requests)});
        error ->
            State
    end.

fail_requests(Reason, #{requests := Requests} = State) ->
    lists:foldl(
        fun(Kind, Acc) -> reply_request(Kind, {error, Reason}, Acc) end,
        State,
        maps:keys(Requests)
    ).

reply(From, Tag, Reply) ->
    From ! {Tag, Reply},
    ok.

%% Sent unasked after the join and whenever an operator changes the mode or the
%% grant, and as the answer to `set_update_mode'. An answer that carries an
%% error is a refusal of the request, but still says what the mode is.
update_mode_changed(Payload, State) ->
    Mode = #{
        mode => mode(maps:get(<<"mode">>, Payload, undefined)),
        managed_updates_allowed => maps:get(<<"managed_updates_allowed">>, Payload, false) =:= true
    },
    notify(State, {update_mode, maps:get(mode, Mode), maps:get(managed_updates_allowed, Mode)}),
    Reply =
        case maps:get(<<"error">>, Payload, undefined) of
            undefined -> {ok, Mode};
            Error -> {error, rejection(Error)}
        end,
    reply_request(set_update_mode, Reply, State#{update_mode => Mode}).

update_mode_reply(undefined) -> {error, unknown};
update_mode_reply(Mode) -> {ok, Mode}.

mode(<<"automatic">>) -> automatic;
mode(<<"device_managed">>) -> device_managed;
mode(<<"off">>) -> off;
mode(_Other) -> unknown.

%% NervesHub's reasons, as atoms where they are ones it documents.
rejection(<<"no_deployment_group">>) -> no_deployment_group;
rejection(<<"no_update">>) -> no_update;
rejection(<<"already_updating">>) -> already_updating;
rejection(<<"busy">>) -> busy;
rejection(<<"not_permitted">>) -> not_permitted;
rejection(<<"unknown_mode">>) -> unknown_mode;
rejection(<<"error">>) -> error;
rejection(Other) when is_binary(Other) -> Other;
rejection(_Other) -> error.

%% ------------------------------------------------------------------ scripts

start_script(#{<<"ref">> := Ref, <<"text">> := Text} = Payload, State) ->
    Timeout =
        case maps:get(<<"timeout">>, Payload, undefined) of
            Ms when is_integer(Ms), Ms > 0 -> Ms;
            _ -> nh_scripts:default_timeout()
        end,
    Pid = nh_scripts:start(Ref, Text, self(), maps:get(firmware_keys, State, [])),
    Scripts = maps:get(scripts, State),
    set_timer({script, Ref}, Timeout, State#{scripts => Scripts#{Pid => Ref}});
start_script(Payload, State) ->
    notify(State, {message, <<"scripts/run">>, Payload}),
    State.

script_finished(Ref, Result, State) ->
    case take_script(Ref, State) of
        {ok, State1} -> push_event(nh_scripts:event(), Result#{<<"ref">> => Ref}, State1);
        error -> State
    end.

script_timed_out(Ref, State) ->
    case take_script(Ref, State) of
        {ok, State1} ->
            script_error(Ref, <<"timeout">>, <<"Error running script: timeout exceeded">>, State1);
        error ->
            State
    end.

script_crashed(Pid, Reason, #{scripts := Scripts} = State) ->
    Ref = maps:get(Pid, Scripts),
    {ok, State1} = take_script(Ref, State),
    Described = describe(Reason),
    script_error(Ref, Described, <<"Error running script: ", Described/binary>>, State1).

take_script(Ref, #{scripts := Scripts} = State) ->
    case [Pid || {Pid, R} <- maps:to_list(Scripts), R =:= Ref] of
        [Pid | _] ->
            exit(Pid, kill),
            {ok, cancel_timer({script, Ref}, State#{scripts => maps:remove(Pid, Scripts)})};
        [] ->
            error
    end.

script_error(Ref, Reason, Output, State) ->
    push_event(
        nh_scripts:event(),
        #{
            <<"ref">> => Ref,
            <<"result">> => <<"error">>,
            <<"reason">> => Reason,
            <<"output">> => Output,
            <<"return">> => <<>>
        },
        State
    ).

%% --------------------------------------------------------------- extensions

maybe_add_extensions(Channel, Extensions) ->
    case nh_extensions:enabled(Extensions) of
        [] ->
            Channel;
        _Some ->
            %% Not joined on connect: what it joins with depends on what
            %% NervesHub advertises once the device has joined.
            nh_channel:add_topic(?EXTENSIONS, #{}, #{auto_join => false}, Channel)
    end.

%% `Advert' is the `extensions:get' payload, or `undefined' when the wait for
%% one ran out.
join_extensions(Advert, State0) ->
    State = cancel_timer(extensions_fallback, State0),
    case nh_channel:joined(maps:get(channel, State)) of
        false ->
            State;
        true ->
            {Extensions, Offer} = nh_extensions:offer(Advert, maps:get(extensions, State)),
            State1 = State#{extensions => Extensions},
            case map_size(Offer) of
                0 ->
                    %% Nothing both ends speak, so nothing to join for.
                    notify(State1, {extensions_attached, []}),
                    State1;
                _ ->
                    {Channel, Actions} = nh_channel:join(
                        ?EXTENSIONS, Offer, maps:get(channel, State1)
                    ),
                    run(Actions, State1#{channel => Channel})
            end
    end.

run_extension_actions(Actions, State) ->
    lists:foldl(fun run_extension_action/2, State, Actions).

run_extension_action({push, Event, Payload}, State) ->
    push_extension(Event, Payload, State);
run_extension_action({resolve_location}, State) ->
    _ = nh_ext_geo:start_resolve(self()),
    State;
run_extension_action(Other, State) ->
    notify(State, Other),
    State.

%% Remembers which extension each push was for, so that NervesHub answering one
%% with `detach' — it does not know that extension — can be traced back to it.
push_extension(Event, Payload, #{ext_refs := Refs} = State) ->
    Channel0 = maps:get(channel, State),
    Ref = nh_channel:peek_ref(Channel0),
    {Channel, Actions} = nh_channel:push(?EXTENSIONS, Event, Payload, Channel0),
    Kept =
        case nh_extensions:scope(Event) of
            {Name, _} -> lists:sublist([{Ref, Name} | Refs], ?EXT_REFS_KEPT);
            error -> Refs
        end,
    run(Actions, State#{channel => Channel, ext_refs => Kept}).

extension_refused(Ref, #{ext_refs := Refs} = State) ->
    case lists:keyfind(Ref, 1, Refs) of
        {Ref, Name} ->
            notify(State, {extension_detached, Name}),
            Extensions = nh_extensions:detach(Name, maps:get(extensions, State)),
            State#{extensions => Extensions, ext_refs => lists:keydelete(Ref, 1, Refs)};
        false ->
            State
    end.

%% Log lines arrive here from `nh_logger', `send_log' and `nh_io_capture'.
%% Version 0.0.1 sends each as it comes. 0.1.0 batches them, and so does a
%% device that has not yet heard which it is — including across a disconnect,
%% which is when a device has most to say. Anything else goes straight out.
extension_out(<<"logging:send">>, Line, State) ->
    Extensions = maps:get(extensions, State),
    case lists:member(?LOGGING, nh_extensions:enabled(Extensions)) of
        false ->
            State;
        true ->
            case logging_mode(State) of
                single ->
                    push_extension(nh_ext_logs:event(), Line, State);
                batched ->
                    Buffer = nh_log_buffer:add(Line, maps:get(log_buffer, State)),
                    maybe_flush_logs(State#{log_buffer => Buffer})
            end
    end;
extension_out(Event, Payload, State) ->
    push_extension(Event, Payload, State).

logging_mode(State) ->
    Extensions = maps:get(extensions, State),
    case
        {
            nh_extensions:is_attached(?LOGGING, Extensions),
            nh_extensions:version(?LOGGING, Extensions)
        }
    of
        {true, <<"0.0.1">>} -> single;
        _ -> batched
    end.

%% A full batch goes now; anything less waits for the flush timer, so a chatty
%% moment costs one message rather than one per line.
maybe_flush_logs(State) ->
    case nh_log_buffer:size(maps:get(log_buffer, State)) >= nh_ext_logs:max_batch() of
        true -> flush_logs(State);
        false -> arm_log_flush(State)
    end.

arm_log_flush(#{timers := Timers, config := Config} = State) ->
    Waiting = nh_log_buffer:size(maps:get(log_buffer, State)) > 0,
    Attached = nh_extensions:is_attached(?LOGGING, maps:get(extensions, State)),
    case Waiting andalso Attached andalso not is_map_key(log_flush, Timers) of
        true -> set_timer(log_flush, maps:get(log_flush_ms, Config, ?DEFAULT_LOG_FLUSH_MS), State);
        false -> State
    end.

%% Sends what is waiting, if logging is attached to send it on. Called on the
%% timer, and whenever the extensions change, so that lines held while
%% disconnected go as soon as there is somewhere to send them.
flush_logs(State0) ->
    State = cancel_timer(log_flush, State0),
    Buffer = maps:get(log_buffer, State),
    Attached = nh_extensions:is_attached(?LOGGING, maps:get(extensions, State)),
    Waiting = nh_log_buffer:size(Buffer) > 0 orelse nh_log_buffer:dropped(Buffer) > 0,

    case Attached andalso Waiting of
        false ->
            State;
        true ->
            case logging_mode(State) of
                batched ->
                    {Lines, Rest} = nh_log_buffer:take(nh_ext_logs:max_batch(), Buffer),
                    State1 = push_extension(
                        nh_ext_logs:event(), nh_ext_logs:batch(Lines), State#{log_buffer => Rest}
                    ),
                    arm_log_flush(State1);
                single ->
                    {Lines, Rest} = nh_log_buffer:take(nh_log_buffer:size(Buffer) + 1, Buffer),
                    lists:foldl(
                        fun(Line, Acc) -> push_extension(nh_ext_logs:event(), Line, Acc) end,
                        State#{log_buffer => Rest},
                        Lines
                    )
            end
    end.

%% ------------------------------------------------------------------- console

maybe_add_console(Channel, Config) ->
    case maps:get(console, Config, false) of
        true ->
            nh_channel:add_topic(
                <<"console">>,
                #{
                    <<"console_version">> => ?CONSOLE_VERSION,
                    <<"device_api_version">> => ?DEVICE_API_VERSION
                },
                Channel
            );
        _ ->
            Channel
    end.

%% Console output only goes anywhere if the channel joined, and `push/4'
%% already refuses on a topic that has not.
console_out(<<>>, State) ->
    State;
console_out(Output, State) ->
    {Channel, Actions} = nh_channel:push(
        <<"console">>, <<"up">>, #{<<"data">> => Output}, maps:get(channel, State)
    ),
    run(Actions, State#{channel => Channel}).

%% ------------------------------------------------------------------ helpers

%% `rebooting' has to reach NervesHub before the device goes. A send returns
%% once the frame is handed to the socket, not once it leaves, and `esp:restart/0'
%% is immediate -- so without a pause the platform never learns why the device
%% vanished. The same gap swallowed the update messages on the ESP-IDF agent.
reboot(State) ->
    _ = timer:sleep(?REBOOT_GRACE_MS),
    _ =
        try
            apply(maps:get(esp, State, esp), restart, [])
        catch
            _:_ -> ok
        end,
    State.

%% An organization's keys are not all Ed25519 -- a Secure Boot v2 RSA key is a
%% PEM -- so anything that is not a 32 byte Ed25519 public key is passed over
%% rather than treated as an error.
decode_keys(Keys) when is_list(Keys) ->
    lists:foldr(
        fun(Key, Acc) ->
            case nh_signature:public_key(Key) of
                {ok, Decoded} -> [Decoded | Acc];
                {error, _} -> Acc
            end
        end,
        [],
        Keys
    );
decode_keys(_Other) ->
    [].

%% The console reports on the same keys the updater uses, and it runs on this
%% process, so they are put where it can reach them.
stash_keys(Keys) ->
    _ = erlang:put(nh_firmware_keys, Keys),
    Keys.

push_event(Event, Payload, State) ->
    {Channel, Actions} = nh_channel:push(Event, Payload, maps:get(channel, State)),
    run(Actions, State#{channel => Channel}).

%% NervesHub wants a string for a failure reason, and an Erlang term is not
%% one. Kept crude on purpose: the detail that matters is in the device log.
describe(Reason) when is_binary(Reason) -> Reason;
describe(Reason) when is_atom(Reason) -> atom_to_binary(Reason, utf8);
describe(Reason) when is_tuple(Reason), tuple_size(Reason) > 0 -> describe(element(1, Reason));
describe(_Reason) -> <<"update_failed">>.

notify(State, Message) ->
    maps:get(owner, State) ! {nerves_hub, Message},
    ok.

now_ms() ->
    erlang:system_time(millisecond).

network_interface(#{config := Config}) ->
    maps:get(network_interface, Config, ?DEFAULT_NETWORK_INTERFACE).

%% What the device reports about itself on every join: its firmware, which
%% protocol version it speaks, whether that firmware has proved itself, and
%% whether it is running because another did not.
join_params(#{config := Config} = State) ->
    Firmware =
        case maps:get(metadata, Config, undefined) of
            undefined -> #{};
            Metadata -> nh_metadata:join_params(Metadata)
        end,
    Validated = nh_ota:pending(ota_opts(State)) =:= none,
    Reverted = nh_ota:reverted(ota_opts(State)),

    maybe_request_keys(
        Firmware#{
            <<"device_api_version">> => ?DEVICE_API_VERSION,
            <<"meta">> => #{
                <<"firmware_validated">> => Validated,
                <<"firmware_auto_revert_detected">> => Reverted
            }
        },
        Config
    ).

refresh_join_params(State) ->
    Channel = nh_channel:set_params(<<"device">>, join_params(State), maps:get(channel, State)),
    State#{channel => Channel}.

%% Asking is opt-in. A device that verifies against keys it was built with does
%% not need them, and asking would only widen what it accepts.
maybe_request_keys(Params, Config) ->
    case maps:get(request_firmware_keys, Config, false) of
        true -> Params#{<<"fwup_public_keys">> => <<"on_connect">>};
        _ -> Params
    end.

transport_config(Config, Url) ->
    Base = #{
        url => Url,
        owner => self(),
        verify => maps:get(verify, Config, crt_bundle),
        %% The agent reconnects, so that each attempt is signed afresh. See
        %% the module documentation.
        disable_auto_reconnect => true
    },

    WithAuth =
        case maps:get(shared_secret, Config, undefined) of
            {Key, Secret} ->
                Identifier = maps:get(identifier, Config),
                Base#{headers => nh_shared_secret:headers(Identifier, Key, Secret)};
            undefined ->
                Base
        end,

    case maps:get(client_cert, Config, undefined) of
        undefined -> WithAuth;
        CertAndKey -> WithAuth#{client_cert => CertAndKey}
    end.
