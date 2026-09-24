%
% SPDX-License-Identifier: Apache-2.0 OR LGPL-2.1-or-later
%

%%-----------------------------------------------------------------------------
%% @doc The extensions channel: health, geo and logs.
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
-export([handle_event/3, scope/1]).

-define(GEO, <<"geo">>).
-define(HEALTH, <<"health">>).
-define(LOGGING, <<"logging">>).

-type state() :: #{
    enabled := [binary()],
    offered := #{binary() => binary()},
    attached := [binary()]
}.

-export_type([state/0]).

%%-----------------------------------------------------------------------------
%% @doc Build the registry from configuration.
%%
%% `extensions => [health, geo, logging]', or `all'. Nothing is enabled by
%% default: each one costs traffic a device may not want to spend.
%% @end
%%-----------------------------------------------------------------------------
-spec new(map()) -> state().
new(Config) ->
    Enabled =
        case maps:get(extensions, Config, []) of
            all -> [?HEALTH, ?GEO, ?LOGGING];
            List when is_list(List) -> [normalise(E) || E <- List];
            _ -> []
        end,

    #{enabled => [E || E <- Enabled, E =/= undefined], offered => #{}, attached => []}.

normalise(health) -> ?HEALTH;
normalise(geo) -> ?GEO;
normalise(logging) -> ?LOGGING;
normalise(logs) -> ?LOGGING;
normalise(?HEALTH) -> ?HEALTH;
normalise(?GEO) -> ?GEO;
normalise(?LOGGING) -> ?LOGGING;
normalise(_Other) -> undefined.

%% What this library speaks of each, newest first. Claiming a version is
%% claiming a wire format, so these track `nerves_hub_link' rather than this
%% library. Logging 0.1.0 is the batched format: `#{<<"lines">> => [...]}'.
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
    {State, [{push, <<"health:report">>, #{<<"value">> => nh_ext_health:report()}}]};
dispatch(?GEO, <<"location:request">>, _Payload, State) ->
    %% Resolving means an HTTP request, which does not belong on the process
    %% that has heartbeats to send.
    {State, [{resolve_location}]};
dispatch(Name, Event, _Payload, State) ->
    {State, [{unhandled_extension_event, Name, Event}]}.
