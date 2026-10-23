%
% SPDX-License-Identifier: Apache-2.0 OR LGPL-2.1-or-later
%

%%-----------------------------------------------------------------------------
%% @doc The extensions channel: health, geo, logs and alarms.
%%
%% Extensions are optional capabilities a device offers and the platform turns
%% on. After the device joins, NervesHub advertises the extensions it knows and
%% the versions of each it speaks, newest first. The device joins the
%% `extensions' topic with the ones it can do, one version each, and the join
%% reply names the subset the platform wants attached — a device may support an
%% extension the product has switched off.
%%
%% ```
%% extensions:get #{<<"extensions">> => #{<<"logging">> => [<<"0.1.0">>, ..]}}  server -> device
%% join payload   #{<<"logging">> => <<"0.1.0">>, ...}                         device -> server
%% join reply     [<<"logging">>, <<"geo">>]                                   server -> device
%% '''
%%
%% A server that never advertises is an older one, and it is offered the oldest
%% version of each: the one every NervesHub that has extensions at all speaks.
%%
%% == Scoped events ==
%%
%% Every event on this topic is prefixed with the extension it belongs to, so
%% `health:check' is `check' for `health'. Splitting on the first colon is the
%% whole of the routing — the rest of the event name may contain colons of its
%% own, as `geo:location:request' does.
%%
%% == Turning them on and off ==
%%
%% An operator can switch an extension on or off while the device is connected.
%% NervesHub sends `attach' or `detach' naming it, and the device answers
%% `&lt;key&gt;:attached' or `&lt;key&gt;:detached'. Asked to attach something it cannot
%% run, it answers `&lt;key&gt;:error', which NervesHub records as a failure rather
%% than waiting for an answer that will never come.
%%
%% == What this module does not do ==
%%
%% It has no side effects. Building a health report reads the system, resolving
%% a location makes an HTTP request, and neither belongs in a routing table, so
%% both come back as actions for the caller to carry out. See `nh_agent'.
%% @end
%%-----------------------------------------------------------------------------
-module(nh_extensions).

-export([new/1, available/1, offer/2, enabled/1, version/2]).
-export([attach/2, attached/1, is_attached/2, detach/2, disconnected/1]).
-export([handle_event/3, scope/1, polls_alarms/1, poll_alarms/1]).

-define(ALARMS, <<"alarms">>).
-define(GEO, <<"geo">>).
-define(HEALTH, <<"health">>).
-define(LOGGING, <<"logging">>).

-type state() :: #{
    enabled := [binary()],
    offered := #{binary() => binary()},
    attached := [binary()],
    %% Whatever the application returns: checked on each report.
    alarms := undefined | fun(() -> term()) | fun((map()) -> term()),
    %% What the application last said was raised, and since when.
    raised := nh_ext_alarms:raised()
}.

-export_type([state/0]).

%%-----------------------------------------------------------------------------
%% @doc Build the registry from configuration.
%%
%% `extensions => [health, geo, logging, alarms]', or `all'. Nothing is
%% enabled by default: each one costs traffic a device may not want to spend.
%%
%% `alarms => Fun' gives the application's alarms: it returns the complete set
%% raised right now, `#{Name => Description}'. It is called for each health
%% report and, with the `alarms' extension, every `alarms_interval_ms' (see
%% `nh_agent'). A `Fun' of one argument is given what it returned last time,
%% so an alarm can be cleared at a different level from the one that raised it
%% without the application keeping state of its own.
%% @end
%%-----------------------------------------------------------------------------
-spec new(map()) -> state().
new(Config) ->
    Enabled =
        case maps:get(extensions, Config, []) of
            all -> [?HEALTH, ?GEO, ?LOGGING, ?ALARMS];
            List when is_list(List) -> [normalise(E) || E <- List];
            _ -> []
        end,

    #{
        enabled => [E || E <- Enabled, E =/= undefined],
        offered => #{},
        attached => [],
        alarms => maps:get(alarms, Config, undefined),
        raised => nh_ext_alarms:new()
    }.

normalise(health) -> ?HEALTH;
normalise(geo) -> ?GEO;
normalise(logging) -> ?LOGGING;
normalise(logs) -> ?LOGGING;
normalise(alarms) -> ?ALARMS;
normalise(?ALARMS) -> ?ALARMS;
normalise(?HEALTH) -> ?HEALTH;
normalise(?GEO) -> ?GEO;
normalise(?LOGGING) -> ?LOGGING;
normalise(_Other) -> undefined.

%% What this library speaks of each, newest first. Claiming a version is
%% claiming a wire format, so these track `nerves_hub_link' rather than this
%% library. Logging 0.1.0 is the batched format: `#{<<"lines">> => [...]}'.
%% `alarms' arrived after the others, at its own version.
local_versions(?ALARMS) -> [<<"0.1.0">>];
local_versions(?LOGGING) -> [<<"0.1.0">>, <<"0.0.1">>];
local_versions(_Name) -> [<<"0.0.1">>].

%%-----------------------------------------------------------------------------
%% @doc The join payload for a server that never advertised: the oldest version
%% of each extension.
%% @end
%%-----------------------------------------------------------------------------
-spec available(state()) -> map().
available(#{enabled := Enabled}) ->
    maps:from_list([{Name, lists:last(local_versions(Name))} || Name <- Enabled]).

%%-----------------------------------------------------------------------------
%% @doc Choose what to join with, given what NervesHub advertised.
%%
%% `Advert' is the `extensions:get' payload, or `undefined' when none came. Of
%% each extension both ends know, the newest version both speak. One the server
%% did not advertise is left out: it would not attach it, and offering it would
%% only earn a reply saying so.
%% @end
%%-----------------------------------------------------------------------------
-spec offer(map() | undefined, state()) -> {state(), map()}.
offer(#{<<"extensions">> := Advertised}, #{enabled := Enabled} = State) when is_map(Advertised) ->
    Offered = maps:from_list([
        {Name, Version}
     || Name <- Enabled,
        (Version = common(local_versions(Name), maps:get(Name, Advertised, []))) =/= none
    ]),
    {State#{offered => Offered, attached => []}, Offered};
offer(_NoAdvert, State) ->
    Offered = available(State),
    {State#{offered => Offered, attached => []}, Offered}.

common([], _Theirs) ->
    none;
common([Version | Rest], Theirs) when is_list(Theirs) ->
    case lists:member(Version, Theirs) of
        true -> Version;
        false -> common(Rest, Theirs)
    end;
common(_Ours, _Theirs) ->
    none.

-spec enabled(state()) -> [binary()].
enabled(#{enabled := Enabled}) -> Enabled.

%%-----------------------------------------------------------------------------
%% @doc The version an extension was offered at, or `undefined'.
%% @end
%%-----------------------------------------------------------------------------
-spec version(binary(), state()) -> binary() | undefined.
version(Name, #{offered := Offered}) -> maps:get(Name, Offered, undefined).

%%-----------------------------------------------------------------------------
%% @doc Record the attach list from the join reply, and confirm it.
%%
%% Anything the platform did not name stays detached, and anything named that
%% this device did not offer is ignored rather than trusted.
%%
%% The confirmations are the point. NervesHub does not start an extension when
%% it puts it in the attach list — it waits for the device to answer
%% `&lt;key&gt;:attached', and only then runs the extension's own attach, which
%% is what asks for the first health report and the first location. A device
%% that attaches silently is a device the platform never speaks to again, and
%% nothing about that looks like an error from either end.
%% @end
%%-----------------------------------------------------------------------------
-spec attach(term(), state()) -> {state(), [term()]}.
attach(Response, #{offered := Offered} = State) when is_list(Response) ->
    Attached = [Name || Name <- Response, maps:is_key(Name, Offered)],
    {State#{attached => Attached}, [confirm(Name, <<":attached">>) || Name <- Attached]};
attach(_Response, State) ->
    {State#{attached => []}, []}.

-spec attached(state()) -> [binary()].
attached(#{attached := Attached}) -> Attached.

-spec is_attached(binary(), state()) -> boolean().
is_attached(Name, #{attached := Attached}) -> lists:member(Name, Attached).

%%-----------------------------------------------------------------------------
%% @doc Stop answering for an extension, without telling NervesHub.
%%
%% For when NervesHub has already said it does not know the extension — it
%% answers a push for one with `detach' — and so has nothing to be told.
%% @end
%%-----------------------------------------------------------------------------
-spec detach(binary(), state()) -> state().
detach(Name, #{attached := Attached} = State) ->
    State#{attached => lists:delete(Name, Attached)}.

%%-----------------------------------------------------------------------------
%% @doc The connection went away, and every extension with it.
%%
%% What was enabled is kept; what was offered and attached is decided again on
%% the next join.
%% @end
%%-----------------------------------------------------------------------------
-spec disconnected(state()) -> state().
disconnected(State) ->
    State#{offered => #{}, attached => []}.

%%-----------------------------------------------------------------------------
%% @doc Split a scoped event into its extension and the event within it.
%% @end
%%-----------------------------------------------------------------------------
-spec scope(binary()) -> {binary(), binary()} | error.
scope(Scoped) ->
    case binary:split(Scoped, <<":">>) of
        [Name, Event] when Name =/= <<>>, Event =/= <<>> -> {Name, Event};
        _ -> error
    end.

%%-----------------------------------------------------------------------------
%% @doc Route an event to its extension.
%%
%% Returns actions rather than performing them: `{push, ScopedEvent, Payload}'
%% to answer immediately, `{resolve_location}' for the one that needs the
%% network. An event for an extension that is not attached is dropped — the
%% platform asking for something it never turned on is not something to answer.
%%
%% `attach' and `detach' are the two unscoped events, and switch extensions on
%% and off while connected.
%% @end
%%-----------------------------------------------------------------------------
-spec handle_event(binary(), map(), state()) -> {state(), [term()]}.
handle_event(<<"attach">>, Payload, State) ->
    lists:foldl(fun attach_one/2, {State, []}, named(Payload, State));
handle_event(<<"detach">>, Payload, State) ->
    lists:foldl(fun detach_one/2, {State, []}, named(Payload, State));
handle_event(Scoped, Payload, State) ->
    case scope(Scoped) of
        error ->
            {State, [{unknown_extension_event, Scoped}]};
        {Name, Event} ->
            case is_attached(Name, State) of
                false -> {State, [{not_attached, Name, Event}]};
                true -> dispatch(Name, Event, Payload, State)
            end
    end.

%% `#{<<"extensions">> => [..] | <<"all">> | Name}'. `all' means everything
%% this device offered, since that is all it could be asked to run.
named(#{<<"extensions">> := <<"all">>}, #{offered := Offered}) -> maps:keys(Offered);
named(#{<<"extensions">> := Name}, _State) when is_binary(Name) -> [Name];
named(#{<<"extensions">> := Names}, _State) when is_list(Names) -> Names;
named(_Payload, _State) -> [].

attach_one(Name, {#{attached := Attached, offered := Offered} = State, Actions}) ->
    case {maps:is_key(Name, Offered), lists:member(Name, Attached)} of
        {true, false} ->
            {State#{attached => Attached ++ [Name]}, Actions ++ [confirm(Name, <<":attached">>)]};
        {true, true} ->
            %% Already running. Confirming again costs nothing and settles a
            %% server that lost track.
            {State, Actions ++ [confirm(Name, <<":attached">>)]};
        {false, _} ->
            {State, Actions ++ [failed(Name, <<"unknown_extension">>)]}
    end.

detach_one(Name, {#{attached := Attached} = State, Actions}) ->
    case lists:member(Name, Attached) of
        true ->
            {
                State#{attached => lists:delete(Name, Attached)},
                Actions ++ [confirm(Name, <<":detached">>)]
            };
        false ->
            {State, Actions}
    end.

confirm(Name, Suffix) -> {push, <<Name/binary, Suffix/binary>>, #{}}.
failed(Name, Reason) -> {push, <<Name/binary, ":error">>, #{<<"reason">> => Reason}}.

dispatch(?HEALTH, <<"check">>, _Payload, State) ->
    {State1, Events} = poll_alarms(State),
    %% With `alarms' attached the report says nothing about alarms: an absent
    %% key leaves alone what the events stored, and `#{}' would clear it.
    Alarms =
        case is_attached(?ALARMS, State1) of
            true -> undefined;
            false -> nh_ext_alarms:current(maps:get(raised, State1))
        end,
    Report = nh_ext_health:report(Alarms),
    {State1, Events ++ [{push, <<"health:report">>, #{<<"value">> => Report}}]};
dispatch(?ALARMS, <<"sync">>, _Payload, State) ->
    %% The snapshot says everything the events would, so they are not sent too:
    %% each one costs a token of NervesHub's rate limit.
    {State1, _Events} = poll_alarms(State),
    {State1, [{push, <<"alarms:snapshot">>, nh_ext_alarms:snapshot(maps:get(raised, State1))}]};
dispatch(?GEO, <<"location:request">>, _Payload, State) ->
    %% Resolving means an HTTP request, which does not belong on the process
    %% that has heartbeats to send.
    {State, [{resolve_location}]};
dispatch(Name, Event, _Payload, State) ->
    {State, [{unhandled_extension_event, Name, Event}]}.

%%-----------------------------------------------------------------------------
%% @doc Whether the agent should ask the application for its alarms on a timer.
%% @end
%%-----------------------------------------------------------------------------
-spec polls_alarms(state()) -> boolean().
polls_alarms(#{enabled := Enabled, alarms := Fun}) ->
    lists:member(?ALARMS, Enabled) andalso
        (is_function(Fun, 0) orelse is_function(Fun, 1)).

%%-----------------------------------------------------------------------------
%% @doc Ask the application for its alarms, and push what changed.
%%
%% The set is followed even while `alarms' is not attached, so that an alarm
%% raised while the device was offline keeps the time it was raised; only the
%% pushes wait for the extension.
%% @end
%%-----------------------------------------------------------------------------
-spec poll_alarms(state()) -> {state(), [term()]}.
poll_alarms(#{raised := Raised} = State) ->
    case alarms(State) of
        error ->
            {State, []};
        Current ->
            {Raised1, Events} = nh_ext_alarms:update(Current, Raised, nh_ext_health:timestamp()),
            Pushes =
                case is_attached(?ALARMS, State) of
                    true -> [{push, Event, Payload} || {Event, Payload} <- Events];
                    false -> []
                end,
            {State#{raised => Raised1}, Pushes}
    end.

%% A report is what you ask for when something is wrong, so an application
%% callback that fails costs nothing: what was raised stays raised.
alarms(#{alarms := Fun}) when is_function(Fun, 0) ->
    checked(fun() -> Fun() end);
alarms(#{alarms := Fun, raised := Raised}) when is_function(Fun, 1) ->
    checked(fun() -> Fun(nh_ext_alarms:current(Raised)) end);
alarms(_State) ->
    #{}.

checked(Call) ->
    try Call() of
        Alarms when is_map(Alarms) -> Alarms;
        _Other -> error
    catch
        _:_ -> error
    end.
