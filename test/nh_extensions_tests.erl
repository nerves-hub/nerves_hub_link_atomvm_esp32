%
% SPDX-License-Identifier: Apache-2.0 OR LGPL-2.1-or-later
%
-module(nh_extensions_tests).

-include_lib("eunit/include/eunit.hrl").

all_enabled() -> offered(#{extensions => all}).

%% Offered with no advert, as to a server that never sent `extensions:get'.
offered(Config) ->
    {State, _Payload} = nh_extensions:offer(undefined, nh_extensions:new(Config)),
    State.

attached_all() ->
    {State, _Actions} = nh_extensions:attach(
        [<<"health">>, <<"geo">>, <<"logging">>], all_enabled()
    ),
    State.

%% Each extension costs traffic a device may not want to spend.
nothing_is_enabled_by_default_test() ->
    State = nh_extensions:new(#{}),
    ?assertEqual([], nh_extensions:enabled(State)),
    ?assertEqual(#{}, nh_extensions:available(State)).

enabled_by_name_test() ->
    State = nh_extensions:new(#{extensions => [health, logging]}),
    ?assertEqual([<<"health">>, <<"logging">>], nh_extensions:enabled(State)).

logs_is_accepted_as_an_alias_test() ->
    ?assertEqual(
        [<<"logging">>], nh_extensions:enabled(nh_extensions:new(#{extensions => [logs]}))
    ).

unknown_extensions_are_dropped_test() ->
    ?assertEqual(
        [<<"health">>], nh_extensions:enabled(nh_extensions:new(#{extensions => [health, wat]}))
    ).

available_declares_a_version_per_extension_test() ->
    Available = nh_extensions:available(all_enabled()),
    ?assertEqual(
        [<<"alarms">>, <<"geo">>, <<"health">>, <<"logging">>], lists:sort(maps:keys(Available))
    ),
    ?assertEqual(<<"0.1.0">>, maps:get(<<"alarms">>, Available)),
    lists:foreach(
        fun(V) -> ?assertEqual(<<"0.0.1">>, V) end,
        maps:values(maps:remove(<<"alarms">>, Available))
    ).

%% The platform decides what is on; a product may have an extension switched off.
attach_uses_the_join_reply_test() ->
    {State, _} = nh_extensions:attach([<<"health">>], all_enabled()),
    ?assertEqual([<<"health">>], nh_extensions:attached(State)),
    ?assert(nh_extensions:is_attached(<<"health">>, State)),
    ?assertNot(nh_extensions:is_attached(<<"geo">>, State)).

%% Being told to attach something this device never offered is not a reason to
%% start answering for it.
attach_ignores_what_was_never_offered_test() ->
    {State, _Actions} = nh_extensions:attach(
        [<<"health">>, <<"local_shell">>], offered(#{extensions => [health]})
    ),
    ?assertEqual([<<"health">>], nh_extensions:attached(State)).

attach_handles_a_reply_that_is_not_a_list_test() ->
    {State, Actions} = nh_extensions:attach(#{}, all_enabled()),
    ?assertEqual([], nh_extensions:attached(State)),
    ?assertEqual([], Actions).

%% The event name after the extension may contain colons of its own.
scope_splits_on_the_first_colon_test() ->
    ?assertEqual({<<"health">>, <<"check">>}, nh_extensions:scope(<<"health:check">>)),
    ?assertEqual(
        {<<"geo">>, <<"location:request">>}, nh_extensions:scope(<<"geo:location:request">>)
    ),
    ?assertEqual(error, nh_extensions:scope(<<"nocolon">>)),
    ?assertEqual(error, nh_extensions:scope(<<":leading">>)),
    ?assertEqual(error, nh_extensions:scope(<<"trailing:">>)).

health_check_answers_with_a_report_test() ->
    {_State, Actions} = nh_extensions:handle_event(<<"health:check">>, #{}, attached_all()),

    ?assertMatch([{push, <<"health:report">>, #{<<"value">> := _}}], Actions),
    [{push, _, #{<<"value">> := Report}}] = Actions,
    ?assert(maps:is_key(<<"metrics">>, Report)).

%% Resolving means an HTTP request, so it comes back as work for the caller.
geo_request_defers_the_network_call_test() ->
    {_State, Actions} = nh_extensions:handle_event(<<"geo:location:request">>, #{}, attached_all()),
    ?assertEqual([{resolve_location}], Actions).

%% Answering for something the platform never turned on would be answering a
%% question it did not ask.
an_event_for_a_detached_extension_is_dropped_test() ->
    {State, _} = nh_extensions:attach([<<"health">>], all_enabled()),
    {_State, Actions} = nh_extensions:handle_event(<<"geo:location:request">>, #{}, State),
    ?assertMatch([{not_attached, <<"geo">>, _}], Actions).

an_unscoped_event_is_reported_test() ->
    {_State, Actions} = nh_extensions:handle_event(<<"nonsense">>, #{}, attached_all()),
    ?assertMatch([{unknown_extension_event, <<"nonsense">>}], Actions).

an_unknown_event_within_an_extension_is_reported_test() ->
    {_State, Actions} = nh_extensions:handle_event(<<"health:wat">>, #{}, attached_all()),
    ?assertMatch([{unhandled_extension_event, <<"health">>, <<"wat">>}], Actions).

%% NervesHub waits for this before it starts an extension. Without it the
%% device is attached and never spoken to again, and nothing looks wrong.
attach_confirms_each_extension_test() ->
    {_State, Actions} = nh_extensions:attach([<<"health">>, <<"geo">>], all_enabled()),

    ?assertEqual(
        [
            {push, <<"health:attached">>, #{}},
            {push, <<"geo:attached">>, #{}}
        ],
        Actions
    ).

nothing_is_confirmed_that_was_not_attached_test() ->
    {_State, Actions} = nh_extensions:attach([<<"local_shell">>], all_enabled()),
    ?assertEqual([], Actions).

%% ------------------------------------------------------------ negotiation

advert(Map) -> #{<<"extensions">> => Map}.

the_newest_version_both_speak_is_offered_test() ->
    {_State, Offer} = nh_extensions:offer(
        advert(#{<<"logging">> => [<<"0.2.0">>, <<"0.1.0">>, <<"0.0.1">>]}),
        nh_extensions:new(#{extensions => [logging]})
    ),
    ?assertEqual(#{<<"logging">> => <<"0.1.0">>}, Offer).

an_older_server_gets_the_older_version_test() ->
    {State, Offer} = nh_extensions:offer(
        advert(#{<<"logging">> => [<<"0.0.1">>]}), nh_extensions:new(#{extensions => [logging]})
    ),
    ?assertEqual(#{<<"logging">> => <<"0.0.1">>}, Offer),
    ?assertEqual(<<"0.0.1">>, nh_extensions:version(<<"logging">>, State)).

what_the_server_does_not_advertise_is_not_offered_test() ->
    {_State, Offer} = nh_extensions:offer(
        advert(#{<<"health">> => [<<"0.0.1">>]}), nh_extensions:new(#{extensions => all})
    ),
    ?assertEqual(#{<<"health">> => <<"0.0.1">>}, Offer).

no_version_in_common_is_not_offered_test() ->
    {_State, Offer} = nh_extensions:offer(
        advert(#{<<"health">> => [<<"9.0.0">>]}), nh_extensions:new(#{extensions => [health]})
    ),
    ?assertEqual(#{}, Offer).

%% ------------------------------------------------------------- lifecycle

attach_all_means_everything_offered_test() ->
    {State0, _} = nh_extensions:attach([], all_enabled()),
    {State, Actions} = nh_extensions:handle_event(
        <<"attach">>, #{<<"extensions">> => <<"all">>}, State0
    ),
    ?assertEqual(
        [<<"alarms">>, <<"geo">>, <<"health">>, <<"logging">>],
        lists:sort(nh_extensions:attached(State))
    ),
    ?assertEqual(4, length(Actions)).

detach_confirms_and_stops_test() ->
    {State, Actions} = nh_extensions:handle_event(
        <<"detach">>, #{<<"extensions">> => [<<"geo">>]}, attached_all()
    ),
    ?assertEqual([{push, <<"geo:detached">>, #{}}], Actions),
    ?assertNot(nh_extensions:is_attached(<<"geo">>, State)).

detaching_what_is_not_attached_says_nothing_test() ->
    {State0, _} = nh_extensions:attach([<<"health">>], all_enabled()),
    ?assertMatch(
        {_, []},
        nh_extensions:handle_event(<<"detach">>, #{<<"extensions">> => [<<"geo">>]}, State0)
    ).

disconnecting_detaches_everything_test() ->
    State = nh_extensions:disconnected(attached_all()),
    ?assertEqual([], nh_extensions:attached(State)),
    ?assertEqual(undefined, nh_extensions:version(<<"health">>, State)),
    ?assertEqual(
        [<<"health">>, <<"geo">>, <<"logging">>, <<"alarms">>], nh_extensions:enabled(State)
    ).

%% ------------------------------------------------------------------- alarms

with_alarms(Extensions, Fun) ->
    nh_extensions:new(#{extensions => Extensions, alarms => Fun}).

attached(Names, State) ->
    {Offered, _} = nh_extensions:offer(undefined, State),
    {Attached, _} = nh_extensions:attach(Names, Offered),
    Attached.

low_memory() -> #{<<"LowMemory">> => <<"low">>}.

alarms_is_polled_only_when_enabled_with_a_fun_test() ->
    ?assert(nh_extensions:polls_alarms(with_alarms([alarms], fun() -> #{} end))),
    ?assert(nh_extensions:polls_alarms(with_alarms([alarms], fun(_) -> #{} end))),
    ?assertNot(nh_extensions:polls_alarms(with_alarms([health], fun() -> #{} end))),
    ?assertNot(nh_extensions:polls_alarms(nh_extensions:new(#{extensions => [alarms]}))).

a_poll_pushes_what_changed_test() ->
    State = attached([<<"alarms">>], with_alarms([alarms], fun low_memory/0)),
    {State1, Actions} = nh_extensions:poll_alarms(State),
    ?assertMatch([{push, <<"alarms:raised">>, #{<<"alarm">> := <<"LowMemory">>}}], Actions),
    ?assertEqual({State1, []}, nh_extensions:poll_alarms(State1)).

%% Followed while detached, so a later snapshot has the time it was raised.
a_poll_while_detached_follows_without_pushing_test() ->
    {State, Actions} = nh_extensions:poll_alarms(with_alarms([alarms], fun low_memory/0)),
    ?assertEqual([], Actions),
    {_, [{push, <<"alarms:snapshot">>, #{<<"alarms">> := [Entry]}}]} =
        nh_extensions:handle_event(<<"alarms:sync">>, #{}, attached([<<"alarms">>], State)),
    ?assertMatch(#{<<"alarm">> := <<"LowMemory">>}, Entry).

%% A one-argument fun hears what it said last time: hysteresis without state.
a_fun_of_one_is_given_the_previous_set_test() ->
    Self = self(),
    Fun = fun(Previous) ->
        Self ! {previous, Previous},
        low_memory()
    end,
    {State, _} = nh_extensions:poll_alarms(with_alarms([alarms], Fun)),
    {_, _} = nh_extensions:poll_alarms(State),
    ?assertEqual([#{}, low_memory()], [
        receive
            {previous, P} -> P
        end
     || _ <- [1, 2]
    ]).

%% What was raised stays raised: a broken callback is not a cleared alarm.
a_failing_fun_changes_nothing_test() ->
    Key = {?MODULE, fail},
    persistent_term:put(Key, false),
    Fun = fun() ->
        case persistent_term:get(Key) of
            true -> error(boom);
            false -> low_memory()
        end
    end,
    State = attached([<<"alarms">>, <<"health">>], with_alarms([alarms, health], Fun)),
    {State1, _} = nh_extensions:poll_alarms(State),
    persistent_term:put(Key, true),
    ?assertEqual({State1, []}, nh_extensions:poll_alarms(State1)),
    persistent_term:erase(Key).

sync_answers_with_a_snapshot_and_no_events_test() ->
    State = attached([<<"alarms">>], with_alarms([alarms], fun low_memory/0)),
    {_, Actions} = nh_extensions:handle_event(<<"alarms:sync">>, #{}, State),
    ?assertMatch([{push, <<"alarms:snapshot">>, #{<<"alarms">> := [_]}}], Actions).

%% An absent key leaves what the alarms extension stored; `#{}' would clear it.
the_health_report_leaves_alarms_out_when_alarms_is_attached_test() ->
    State = attached([<<"alarms">>, <<"health">>], with_alarms([alarms, health], fun low_memory/0)),
    {_, Actions} = nh_extensions:handle_event(<<"health:check">>, #{}, State),
    [{push, <<"health:report">>, #{<<"value">> := Report}}] =
        [A || {push, <<"health:report">>, _} = A <- Actions],
    ?assertNot(maps:is_key(<<"alarms">>, Report)),
    ?assertMatch(
        [{push, <<"alarms:raised">>, _}],
        Actions -- [{push, <<"health:report">>, #{<<"value">> => Report}}]
    ).

the_health_report_carries_alarms_without_the_extension_test() ->
    State = attached([<<"health">>], with_alarms([health], fun low_memory/0)),
    {_, [{push, <<"health:report">>, #{<<"value">> := Report}}]} =
        nh_extensions:handle_event(<<"health:check">>, #{}, State),
    ?assertEqual(low_memory(), maps:get(<<"alarms">>, Report)).
