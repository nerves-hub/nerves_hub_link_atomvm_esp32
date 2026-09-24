%
% SPDX-License-Identifier: Apache-2.0 OR LGPL-2.1-or-later
%

%%-----------------------------------------------------------------------------
%% @doc Connect an AtomVM device to NervesHub.
%%
%% ```
%% {ok, _Pid} = nerves_hub_link:start(#{
%%     identifier    => <<"my-device">>,
%%     shared_secret => {Key, Secret},
%%     firmware      => boot
%% }).
%% '''
%%
%% A keyword list works as well as a map, which is what an Elixir caller will
%% write:
%%
%% ```
%% :nerves_hub_link.start(identifier: "my-device", shared_secret: {key, secret})
%% '''
%%
%% == Where it connects ==
%%
%% Nothing above says where, because there is only one URL a device sensibly
%% wants and it can be worked out. `host' names a different server, `url' takes
%% one written out in as much detail as you like, and whatever is missing is
%% filled in:
%%
%% ```
%% (nothing)                          wss://devices.nervescloud.com/device-socket/websocket?vsn=2.0.0
%% #{host => "nh.example.com"}        wss://nh.example.com/device-socket/websocket?vsn=2.0.0
%% #{url => "ws://192.168.1.10:4000"} ws://192.168.1.10:4000/device-socket/websocket?vsn=2.0.0
%% '''
%%
%% The path depends on how the device authenticates: a shared secret goes
%% through NervesHub's web endpoint, where the device socket is mounted at
%% `/device-socket' because `/socket' is the browser socket, and a client
%% certificate goes to the device endpoint, where it is at `/socket'. See
%% `nh_url'.
%%
%% `url' and `host' together is an error rather than a precedence rule.
%%
%% The calling process receives `{nerves_hub, Event}':
%%
%% ```
%% {joined, Response}
%% {join_error, Reason}
%% {message, Event, Payload}    %% "update" and friends
%% {update_started, Pid}
%% {update_ready, Slot}         %% written and armed; reboot when ready
%% {update_failed, Reason}
%% {firmware_committed, Slot}   %% the running update proved itself
%% {firmware_trial, Slot, Boot} %% booted an update not yet proved
%% {firmware_reverted, Slot}    %% it never proved itself; Slot boots next
%% {update_mode, Mode, Allowed}
%% {update_rejected, Reason}
%% identify                     %% blink something
%% reboot_requested
%% console_joined
%% {extensions_attached, Names}
%% {extension_detached, Name}
%% {disconnected, Reason}       %% the agent reconnects
%% {transport_error, Reason}
%% '''
%%
%% == Updates the device decides on ==
%%
%% `updates => manual' reports an offer and waits for `apply_update/2',
%% `ignore_update/2' or `reschedule_update/3'. A product that allows it can
%% put a device in `device_managed' mode with `set_update_mode/2', after which
%% NervesHub stops pushing and the device asks: `check_for_update/1' and
%% `request_update/1'.
%%
%% == Authentication ==
%%
%% Either `shared_secret => {Key, Secret}' or `client_cert => {CertPem, KeyPem}'.
%% Which one to use is an organization's choice, and NervesHub accepts both.
%%
%% A shared-secret signature is time-bound: NervesHub refuses one signed more
%% than 90 seconds ago. An ESP32 boots at the epoch, so the clock has to be set
%% — by SNTP, say — before connecting, or every signature is decades stale.
%% `start/1' refuses with `{error, {clock_not_set, Now}}' rather than letting
%% the socket answer a bare 401.
%%
%% == The remote console ==
%%
%% `console => true' joins NervesHub's console channel, off by default. On
%% Nerves `nerves_hub_link' answers that channel with a real IEx session; AtomVM
%% has no shell, so this answers it with a debug terminal instead — a fixed set
%% of commands, listed by `help'. See `nh_console'.
%%
%% It reports, and it reboots. It will not evaluate Erlang, and it is not a way
%% in to a running system.
%%
%% == Actions ==
%%
%% NervesHub can ask a device to do three things from its page. Two arrive as
%% messages on the device topic and one does not:
%%
%% <ul>
%%   <li>`identify' is passed straight through. Only the application knows what
%%       identifying looks like on its hardware, so nothing is done for it.</li>
%%   <li>`reboot' announces itself with `rebooting' and then restarts the
%%       device. `reboot => manual' reports `reboot_requested' and leaves the
%%       decision alone.</li>
%%   <li>`reconnect' is not a device message at all — NervesHub drops the
%%       socket and the agent reconnects, signing the new connection afresh,
%%       so there is nothing to implement.</li>
%% </ul>
%%
%% == Sending logs ==
%%
%% `nerves_hub_link:send_log/3' sends one line. To send everything an
%% application logs, add `nh_logger' to `logger''s handlers and start the agent
%% with `register => nerves_hub_link' so the handler can find it:
%%
%% ```
%% logger_manager:start_link(#{
%%     log_level => info,
%%     logger => [
%%         {handler, default, logger_std_h, #{}},
%%         nh_logger:handler(#{level => info})
%%     ]
%% })
%% '''
%%
%% Elixir has no `Logger' on AtomVM, so Elixir code calls `:logger' and is
%% caught by the same handler.
%%
%% Log a charlist or a map, never a binary: AtomVM's logger raises `badarg' on
%% a binary message, which takes down the process that logged it. See
%% `nh_logger'.
%%
%% That handler catches everything going through `logger' and nothing else, and
%% a great deal of AtomVM code -- including most of the examples -- reports what
%% it is doing with `io:format/2'. `capture_io => true' sends that too:
%%
%% ```
%% nerves_hub_link:start(Config#{capture_io => true})
%% '''
%%
%% It makes a capture process the calling process's group leader, so what that
%% process and everything it starts afterwards print is forwarded as well as
%% shown on the console. The text arrives unstructured, at one level, timed on
%% arrival -- there is no level or module in an `io:format' call to carry over.
%% ESP-IDF's own `I (1234) wifi: ...' lines are written from C and are not
%% caught by anything here.
%%
%% One thing to change when turning it on: `logger' runs its handlers in the
%% process that logged, so `logger_std_h' -- which reports by printing -- is
%% captured as well, and every logged line arrives twice. `nh_console_h' prints
%% the same line straight to the console and is not captured:
%%
%% ```
%% logger_manager:start_link(#{
%%     log_level => info,
%%     logger => [
%%         {handler, default, nh_console_h, #{level => info}},
%%         nh_logger:handler(#{level => info})
%%     ]
%% })
%% '''
%%
%% Read `nh_io_capture' before turning it on. The failure mode of a group
%% leader is a printing process that waits forever, so the module is written to
%% answer every request whatever it is, and it is off by default.
%%
%% == Verifying firmware ==
%%
%% `firmware_keys' are the organization's Ed25519 public keys, as base64 or raw
%% bytes. An fwup `.pub' file is exactly what goes here, because a packbeam is
%% signed with the same key.
%%
%% Configuring them is what asks for signatures. A device with keys refuses any
%% update they do not cover, including one carrying no signature at all, and
%% refuses it *before* the boot path moves — so a rejected archive sits in a
%% slot nothing boots from and the device keeps running what it had. A device
%% with no keys installs what NervesHub sent it.
%%
%% == Updates ==
%%
%% `updates => auto' (the default) downloads and installs an update NervesHub
%% offers, into the slot the device is not running, and reports
%% `{update_ready, Slot}' when it is armed. Rebooting is left to the
%% application. `updates => manual' reports the message and does nothing else.
%%
%% == Firmware description ==
%%
%% `firmware' says where the running firmware's description comes from:
%%
%% <ul>
%%   <li>`boot' — the packbeam AtomVM booted, found through the boot path
%%       `esp32init' records in NVS. This is the default.</li>
%%   <li>`{partition, Label}' — a named partition instead, for a device whose
%%       loader is not `esp32init'.</li>
%%   <li>`{metadata, Map}' — supply it directly, as built by
%%       `nh_metadata:describe/2'.</li>
%%   <li>`none' — join without describing the firmware. NervesHub will not know
%%       what the device is running, so it cannot decide whether to update it.</li>
%% </ul>
%%
%% `boot' can be the default because it is not a guess. An ESP-IDF device cannot
%% ask which of `ota_0'/`ota_1' it is running, so naming a partition there was a
%% claim that quietly became false after the first update. AtomVM records the
%% boot path, so this stays correct across updates and there is nothing left for
%% a caller to get wrong.
%% @end
%%-----------------------------------------------------------------------------
-module(nerves_hub_link).

-export([start/1, start_link/1, stop/1]).

%% 2023-11-14. A lower bound on "the clock has been set at all", not a real
%% date check — anything this library runs against postdates it comfortably.
-define(EARLIEST_PLAUSIBLE_TIME, 1700000000).
-export([update_progress/2, update_progress/3, firmware_validated/1, update_failed/2]).
-export([push/3]).
-export([send_log/3, send_log/4]).
-export([check_for_update/1, request_update/1, set_update_mode/2, update_mode/1]).
-export([apply_update/2, ignore_update/2, reschedule_update/3]).

-type firmware_source() :: boot | {partition, binary()} | {metadata, map()} | none.

-type config() :: #{
    url => binary() | string(),
    host => binary() | string(),
    identifier := binary(),
    firmware => firmware_source(),
    shared_secret => {binary(), binary()},
    client_cert => {binary(), binary()},
    verify => crt_bundle | {cacert_pem, binary()} | none,
    console => boolean(),
    extensions => all | [health | geo | logging],
    reboot => auto | manual,
    updates => auto | manual,
    firmware_keys => [binary() | string()],
    request_firmware_keys => boolean(),
    firmware_trial => #{boot_attempts => pos_integer(), join_timeout_ms => pos_integer()} | off,
    network_interface => binary(),
    reconnect_backoff => {pos_integer(), pos_integer()},
    log_flush_ms => pos_integer(),
    log_buffer => pos_integer(),
    capture_io => boolean() | map(),
    register => atom(),
    handler => pid(),
    heartbeat_ms => pos_integer(),
    transport => module()
}.

-type update_mode() :: #{
    mode := automatic | device_managed | off | unknown,
    managed_updates_allowed := boolean()
}.

-export_type([config/0, firmware_source/0, update_mode/0]).

%%-----------------------------------------------------------------------------
%% @doc Connect, linked to the calling process.
%% @end
%%-----------------------------------------------------------------------------
-spec start_link(config() | [{atom(), term()}]) -> {ok, pid()} | {error, term()}.
start_link(Config) ->
    with_agent_config(options(Config), fun nh_agent:start_link/1).

-spec start(config() | [{atom(), term()}]) -> {ok, pid()} | {error, term()}.
start(Config) ->
    with_agent_config(options(Config), fun nh_agent:start/1).

-spec stop(pid()) -> ok.
stop(Pid) ->
    nh_agent:stop(Pid).

%%-----------------------------------------------------------------------------
%% @equiv send_log(Pid, Level, Message, #{})
%% @end
%%-----------------------------------------------------------------------------
-spec send_log(pid(), binary(), binary()) -> ok | {error, term()}.
send_log(Pid, Level, Message) ->
    send_log(Pid, Level, Message, #{}).

%%-----------------------------------------------------------------------------
%% @doc Send a log line to NervesHub, if the logging extension is attached.
%%
%% `{error, no_clock}' when the device's clock has never been set: NervesHub
%% requires a timestamp and drops a line without one, and a line dated 1970 is
%% worse than no line. See `nh_ext_logs'.
%% @end
%%-----------------------------------------------------------------------------
-spec send_log(pid(), binary(), binary(), map()) -> ok | {error, term()}.
send_log(Pid, Level, Message, Meta) ->
    case nh_ext_logs:line(Level, Message, Meta) of
        {ok, Line} ->
            Pid ! {push_extension, nh_ext_logs:event(), Line},
            ok;
        {error, _} = Error ->
            Error
    end.

%%-----------------------------------------------------------------------------
%% @doc Report how far through an update the device is, as a percentage.
%% @end
%%-----------------------------------------------------------------------------
-spec update_progress(pid(), 0..100) -> ok.
update_progress(Pid, Percent) ->
    push(Pid, <<"update_progress">>, #{<<"value">> => Percent}).

%%-----------------------------------------------------------------------------
%% @doc As `update_progress/2', naming the stage: `downloading' or `updating'.
%% @end
%%-----------------------------------------------------------------------------
-spec update_progress(pid(), 0..100, binary()) -> ok.
update_progress(Pid, Percent, Stage) ->
    push(Pid, <<"update_progress">>, #{<<"value">> => Percent, <<"stage">> => Stage}).

%%-----------------------------------------------------------------------------
%% @doc Confirm that the newly booted firmware works.
%%
%% Pairs with `esp_ota_mark_app_valid_cancel_rollback()': until something calls
%% it, the bootloader will roll back to the previous image on the next boot.
%% @end
%%-----------------------------------------------------------------------------
-spec firmware_validated(pid()) -> ok.
firmware_validated(Pid) ->
    push(Pid, <<"firmware_validated">>, #{}).

%%-----------------------------------------------------------------------------
%% @doc Report that an update did not complete.
%% @end
%%-----------------------------------------------------------------------------
-spec update_failed(pid(), binary()) -> ok.
update_failed(Pid, Reason) ->
    push(Pid, <<"status_update">>, #{<<"status">> => <<"failed">>, <<"reason">> => Reason}).

%%-----------------------------------------------------------------------------
%% @doc Send an arbitrary event on the device channel.
%% @end
%%-----------------------------------------------------------------------------
-spec push(pid(), binary(), map()) -> ok.
push(Pid, Event, Payload) ->
    Pid ! {push, Event, Payload},
    ok.

%%-----------------------------------------------------------------------------
%% @doc Ask NervesHub whether there is an update for this device.
%%
%% Asks, and does nothing else: `request_update/1' is what fetches it. Answered
%% for a device in either update mode.
%% @end
%%-----------------------------------------------------------------------------
-spec check_for_update(pid()) ->
    {ok, #{available := boolean(), firmware_meta := map() | null}} | {error, term()}.
check_for_update(Pid) ->
    call(Pid, check_update).

%%-----------------------------------------------------------------------------
%% @doc Ask NervesHub for the update, and install it when it comes.
%%
%% This is how a device in `device_managed' mode updates: NervesHub does not
%% push to it, and waits to be asked. `ok' means NervesHub sent the update and
%% the download has begun; how it ends arrives as `{update_ready, Slot}' or
%% `{update_failed, Reason}', as for any other update. Installed even with
%% `updates => manual', since asking was the decision.
%%
%% Refused with `{error, Reason}' where `Reason' is NervesHub's —
%% `no_update', `no_deployment_group', `already_updating' — or `updating' when
%% this device is already part way through one.
%% @end
%%-----------------------------------------------------------------------------
-spec request_update(pid()) -> ok | {error, term()}.
request_update(Pid) ->
    call(Pid, request_update).

%%-----------------------------------------------------------------------------
%% @doc Choose who decides when this device updates.
%%
%% `automatic' is NervesHub's deployments pushing updates as they always have.
%% `device_managed' stops the pushes and leaves it to `request_update/1'. A
%% device may only switch to `device_managed' when its product allows it, and
%% NervesHub answers `{error, not_permitted}' otherwise. Setting `off' is
%% reserved for an operator.
%% @end
%%-----------------------------------------------------------------------------
-spec set_update_mode(pid(), automatic | device_managed) -> {ok, update_mode()} | {error, term()}.
set_update_mode(Pid, Mode) when Mode =:= automatic; Mode =:= device_managed ->
    call(Pid, {set_update_mode, atom_to_binary(Mode, utf8)});
set_update_mode(_Pid, Mode) ->
    {error, {invalid_update_mode, Mode}}.

%%-----------------------------------------------------------------------------
%% @doc The update mode NervesHub last reported, without asking it again.
%%
%% NervesHub reports it after every join and whenever it changes, and each
%% report also reaches the handler as `{update_mode, Mode, ManagedAllowed}'.
%% `{error, unknown}' until the first one arrives.
%% @end
%%-----------------------------------------------------------------------------
-spec update_mode(pid()) -> {ok, update_mode()} | {error, term()}.
update_mode(Pid) ->
    call(Pid, update_mode).

%%-----------------------------------------------------------------------------
%% @doc Install an update that `updates => manual' reported and did not act on.
%%
%% `Payload' is the one from `{message, <<"update">>, Payload}'.
%% @end
%%-----------------------------------------------------------------------------
-spec apply_update(pid(), map()) -> ok.
apply_update(Pid, Payload) when is_map(Payload) ->
    Pid ! {update_decision, {apply, Payload}},
    ok.

%%-----------------------------------------------------------------------------
%% @doc Decline an update, telling NervesHub why.
%%
%% NervesHub holds further updates back for the deployment's penalty timeout,
%% rather than offering the same one again at once.
%% @end
%%-----------------------------------------------------------------------------
-spec ignore_update(pid(), binary()) -> ok.
ignore_update(Pid, Reason) when is_binary(Reason) ->
    Pid ! {update_decision, {ignore, Reason}},
    ok.

%%-----------------------------------------------------------------------------
%% @doc Not now: ask NervesHub to offer the update again in `DelayMs'.
%% @end
%%-----------------------------------------------------------------------------
-spec reschedule_update(pid(), pos_integer(), binary()) -> ok.
reschedule_update(Pid, DelayMs, Reason) when is_integer(DelayMs), DelayMs > 0, is_binary(Reason) ->
    Pid ! {update_decision, {reschedule, DelayMs, Reason}},
    ok.

%% ------------------------------------------------------------------- internals

%% NervesHub gives a request 30 seconds and the agent times it out then; this
%% waits a little longer so the agent's answer is the one that arrives.
-define(CALL_TIMEOUT_MS, 35000).

call(Pid, Request) ->
    Monitor = erlang:monitor(process, Pid),
    Tag = make_ref(),
    Pid ! {call, self(), Tag, Request},
    receive
        {Tag, Reply} ->
            erlang:demonitor(Monitor, [flush]),
            Reply;
        {'DOWN', Monitor, process, Pid, Reason} ->
            {error, {agent_down, Reason}}
    after ?CALL_TIMEOUT_MS ->
        erlang:demonitor(Monitor, [flush]),
        {error, timeout}
    end.

%% A keyword list is what an Elixir caller reaches for, and this library is
%% meant to be usable from Elixir without a wrapper in between.
options(Config) when is_map(Config) -> Config;
options(Config) when is_list(Config) -> maps:from_list(Config).

with_agent_config(Config, Start) ->
    case validate(Config) of
        {ok, AgentConfig} ->
            case Start(maps:remove(capture_io, AgentConfig)) of
                {ok, Agent} = Started ->
                    ok = capture_io(Config, Agent),
                    Started;
                {error, _} = Error ->
                    Error
            end;
        {error, _} = Error ->
            Error
    end.

%% Done here rather than in the agent because here is the calling process, and
%% `erlang:group_leader/2' is only immediate for the process doing the calling.
%% Processes the caller starts afterwards inherit it; ones it started already do
%% not.
capture_io(Config, Agent) ->
    case maps:get(capture_io, Config, false) of
        false -> ok;
        true -> capture(#{agent => Agent});
        Options when is_map(Options) -> capture(Options#{agent => Agent})
    end.

capture(Options) ->
    {ok, Capture} = nh_io_capture:start(Options),
    nh_io_capture:attach(Capture).

validate(Config) ->
    case missing_keys(Config) of
        [] ->
            case usable_clock(Config) of
                ok -> resolve_url(Config);
                {error, _} = Error -> Error
            end;
        Missing ->
            {error, {missing_config, Missing}}
    end.

%% Resolved here so that a config naming a host it cannot build a URL from
%% fails at startup rather than inside the transport.
resolve_url(Config) ->
    case nh_url:resolve(Config) of
        {ok, _Url} -> resolve_keys(Config);
        {error, _} = Error -> Error
    end.

%% Checked at startup rather than when an update arrives. A mistyped key would
%% otherwise sit unnoticed until the first update, and then look like the
%% firmware was tampered with.
resolve_keys(Config) ->
    Configured = maps:get(firmware_keys, Config, []),

    case decode_keys(Configured, []) of
        {ok, Keys} -> resolve_firmware(Config#{firmware_keys => Keys});
        {error, _} = Error -> Error
    end.

decode_keys([], Acc) ->
    {ok, lists:reverse(Acc)};
decode_keys([Key | Rest], Acc) ->
    case nh_signature:public_key(Key) of
        {ok, Decoded} -> decode_keys(Rest, [Decoded | Acc]);
        {error, Reason} -> {error, {invalid_firmware_key, Reason}}
    end.

%% A shared-secret signature carries the time it was signed at, and NervesHub
%% refuses one older than 90 seconds. An ESP32 boots at the epoch and stays
%% there until something sets the clock, so without SNTP every signature is
%% decades stale and the socket answers a bare 401 with nothing to say why.
%%
%% Failing here names the actual problem. It is only checked for shared secrets
%% because that is the scheme whose signature is time-bound.
usable_clock(Config) ->
    case maps:is_key(shared_secret, Config) of
        false ->
            ok;
        true ->
            Now = erlang:system_time(second),
            case Now >= ?EARLIEST_PLAUSIBLE_TIME of
                true -> ok;
                false -> {error, {clock_not_set, Now}}
            end
    end.

missing_keys(Config) ->
    Required = [identifier],
    Absent = [Key || Key <- Required, not maps:is_key(Key, Config)],

    case has_credentials(Config) of
        true -> Absent;
        false -> Absent ++ [shared_secret_or_client_cert]
    end.

has_credentials(Config) ->
    maps:is_key(shared_secret, Config) orelse maps:is_key(client_cert, Config).

resolve_firmware(Config) ->
    case maps:get(firmware, Config, boot) of
        none ->
            {ok, maps:remove(firmware, Config)};
        {metadata, Metadata} when is_map(Metadata) ->
            {ok, maps:put(metadata, Metadata, maps:remove(firmware, Config))};
        boot ->
            from_flash(Config, fun nh_flash:read_metadata/0);
        {partition, Partition} ->
            from_flash(Config, fun() -> nh_flash:read_metadata(Partition) end);
        Other ->
            {error, {invalid_firmware_source, Other}}
    end.

from_flash(Config, Read) ->
    case Read() of
        {ok, Metadata} ->
            {ok, maps:put(metadata, Metadata, maps:remove(firmware, Config))};
        {error, Reason} ->
            %% Refusing to start beats joining with no firmware description,
            %% which looks like a device that never needs updating.
            {error, {firmware_unreadable, Reason}}
    end.
