%
% SPDX-License-Identifier: Apache-2.0 OR LGPL-2.1-or-later
%
-module(nh_ext_health_tests).

-include_lib("eunit/include/eunit.hrl").

report_has_the_shape_nerves_hub_stores_test() ->
    Report = nh_ext_health:report(),

    lists:foreach(
        fun(Key) -> ?assert(maps:is_key(Key, Report)) end,
        [<<"timestamp">>, <<"metadata">>, <<"alarms">>, <<"metrics">>, <<"checks">>]
    ),
    ?assert(is_map(maps:get(<<"metrics">>, Report))),
    ?assert(is_map(maps:get(<<"metadata">>, Report))).

report_carries_the_alarms_given_test() ->
    Alarms = #{<<"LowMemory">> => <<"largest free block 20000 bytes">>},
    ?assertEqual(Alarms, maps:get(<<"alarms">>, nh_ext_health:report(Alarms))),
    ?assertEqual(#{}, maps:get(<<"alarms">>, nh_ext_health:report())).

%% With the alarms extension the report says nothing about alarms.
report_without_alarms_leaves_the_key_out_test() ->
    ?assertNot(maps:is_key(<<"alarms">>, nh_ext_health:report(undefined))).

%% Every metric drives a graph, so they have to be numbers.
metrics_are_numbers_test() ->
    lists:foreach(
        fun({Key, Value}) -> ?assert({is_number(Value), Key} =:= {true, Key}) end,
        maps:to_list(nh_ext_health:metrics())
    ).

%% NervesHub stores metadata as a string map.
metadata_values_are_strings_test() ->
    lists:foreach(
        fun({Key, Value}) -> ?assert({is_binary(Value), Key} =:= {true, Key}) end,
        maps:to_list(nh_ext_health:metadata())
    ).

%% Off a device almost nothing can be read, and a report that crashes is worse
%% than a thin one — this is the thing you ask for when something is wrong.
a_report_survives_a_platform_with_no_answers_test() ->
    ?assert(is_map(nh_ext_health:report())).

%% A report stamped at the epoch looks like data. No stamp is honest.
timestamp_is_rfc3339_or_absent_test() ->
    case nh_ext_health:timestamp() of
        undefined ->
            ok;
        Stamp ->
            ?assertEqual(20, byte_size(Stamp)),
            ?assertEqual($T, binary:at(Stamp, 10)),
            ?assertEqual($Z, binary:last(Stamp))
    end.

%% Any percentage would be measured against a heap total AtomVM does not
%% report, so the device stays `unknown` rather than showing an invented colour.
no_invented_percentages_test() ->
    Metrics = nh_ext_health:metrics(),

    lists:foreach(
        fun(Key) -> ?assertNot(maps:is_key(Key, Metrics)) end,
        [<<"mem_used_percent">>, <<"cpu_usage_percent">>, <<"disk_used_percentage">>]
    ).
