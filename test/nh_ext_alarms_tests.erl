%
% SPDX-License-Identifier: Apache-2.0 OR LGPL-2.1-or-later
%
-module(nh_ext_alarms_tests).

-include_lib("eunit/include/eunit.hrl").

-define(T1, <<"2026-10-16T12:00:00Z">>).
-define(T2, <<"2026-10-16T12:00:30Z">>).

raise(Current) ->
    nh_ext_alarms:update(Current, nh_ext_alarms:new(), ?T1).

a_new_alarm_is_raised_with_the_time_test() ->
    {_Raised, Events} = raise(#{<<"LowMemory">> => <<"low">>}),
    ?assertEqual(
        [
            {<<"alarms:raised">>, #{
                <<"alarm">> => <<"LowMemory">>,
                <<"description">> => <<"low">>,
                <<"raised_at">> => ?T1
            }}
        ],
        Events
    ).

nothing_changed_sends_nothing_test() ->
    {Raised, _} = raise(#{<<"LowMemory">> => <<"low">>}),
    ?assertEqual({Raised, []}, nh_ext_alarms:update(#{<<"LowMemory">> => <<"low">>}, Raised, ?T2)).

a_missing_alarm_is_cleared_test() ->
    {Raised, _} = raise(#{<<"LowMemory">> => <<"low">>}),
    {Raised1, Events} = nh_ext_alarms:update(#{}, Raised, ?T2),
    ?assertEqual(#{}, Raised1),
    ?assertEqual(
        [{<<"alarms:cleared">>, #{<<"alarm">> => <<"LowMemory">>, <<"cleared_at">> => ?T2}}],
        Events
    ).

%% NervesHub keeps the first time; so does the device, for every snapshot.
a_new_description_is_raised_again_with_the_first_time_test() ->
    {Raised, _} = raise(#{<<"LowMemory">> => <<"low">>}),
    {Raised1, Events} = nh_ext_alarms:update(#{<<"LowMemory">> => <<"lower">>}, Raised, ?T2),
    ?assertMatch(
        [{<<"alarms:raised">>, #{<<"description">> := <<"lower">>, <<"raised_at">> := ?T1}}],
        Events
    ),
    ?assertEqual(#{<<"LowMemory">> => {<<"lower">>, ?T1}}, Raised1).

%% Without a clock there is no time to give, and 1970 would look like data.
no_clock_leaves_the_times_out_test() ->
    {Raised, [{_, Raised1}]} = nh_ext_alarms:update(
        #{a => <<"x">>}, nh_ext_alarms:new(), undefined
    ),
    ?assertNot(maps:is_key(<<"raised_at">>, Raised1)),
    {_, [{_, Cleared}]} = nh_ext_alarms:update(#{}, Raised, undefined),
    ?assertNot(maps:is_key(<<"cleared_at">>, Cleared)),
    #{<<"alarms">> := [Entry]} = nh_ext_alarms:snapshot(Raised),
    ?assertNot(maps:is_key(<<"raised_at">>, Entry)).

names_and_descriptions_become_strings_test() ->
    {Raised, _} = raise(#{'Elixir.MyApp.Hot' => "too hot", 42 => 7}),
    ?assertEqual(
        #{<<"Elixir.MyApp.Hot">> => <<"too hot">>, <<"42">> => <<"7">>},
        nh_ext_alarms:current(Raised)
    ).

clears_come_before_raises_test() ->
    {Raised, _} = raise(#{<<"A">> => <<"a">>}),
    {_, Events} = nh_ext_alarms:update(#{<<"B">> => <<"b">>}, Raised, ?T2),
    ?assertMatch([{<<"alarms:cleared">>, _}, {<<"alarms:raised">>, _}], Events).

the_snapshot_has_every_alarm_raised_test() ->
    {Raised, _} = raise(#{<<"A">> => <<"a">>, <<"B">> => <<"b">>}),
    ?assertEqual(
        #{
            <<"alarms">> => [
                #{<<"alarm">> => <<"A">>, <<"description">> => <<"a">>, <<"raised_at">> => ?T1},
                #{<<"alarm">> => <<"B">>, <<"description">> => <<"b">>, <<"raised_at">> => ?T1}
            ]
        },
        nh_ext_alarms:snapshot(Raised)
    ),
    ?assertEqual(#{<<"alarms">> => []}, nh_ext_alarms:snapshot(nh_ext_alarms:new())).
