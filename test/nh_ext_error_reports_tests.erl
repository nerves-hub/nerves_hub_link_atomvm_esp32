%
% SPDX-License-Identifier: Apache-2.0 OR LGPL-2.1-or-later
%
-module(nh_ext_error_reports_tests).

-include_lib("eunit/include/eunit.hrl").

%% What AtomVM's `proc_lib:crash_report/4' logs, format and arguments as is.
-define(FORMAT,
    "=CRASH REPORT====\n"
    "  crasher:\n"
    "   initial call: ~s:~s/~B\n"
    "   pid: ~p\n"
    "   exception error: ~p\n"
    "   ancestors: ~w\n"
    "   message_queue_len: ~B\n"
    "   links: ~w\n"
    "   total_heap_size: ~B\n"
    "   stack_size: ~B\n"
    "   stack_trace: ~p\n"
).

now_us() -> erlang:system_time(microsecond).

crash(Class, Reason, Stacktrace) ->
    #{
        level => error,
        timestamp => now_us(),
        msg =>
            {?FORMAT, [
                my_worker, init, 1, self(), {Class, Reason}, [], 0, [], 104, 16, Stacktrace
            ]}
    }.

a_crash_report_becomes_a_report_test() ->
    Stacktrace = [
        {my_worker, handle_info, 2, [{file, "src/my_worker.erl"}, {line, 42}]},
        {gen_server, try_dispatch, 4, []}
    ],
    {ok, Report} = nh_ext_error_reports:from_log(
        crash(exit, {connect_error, nxdomain}, Stacktrace)
    ),

    ?assertEqual(<<"exit">>, maps:get(<<"kind">>, Report)),
    ?assertEqual(<<"{connect_error,nxdomain}">>, maps:get(<<"reason">>, Report)),
    ?assertEqual(<<"logger">>, maps:get(<<"source">>, Report)),
    ?assertMatch(<<"=CRASH REPORT====", _/binary>>, maps:get(<<"message">>, Report)),
    ?assertEqual(
        [
            #{
                <<"module">> => <<"my_worker">>,
                <<"function">> => <<"handle_info/2">>,
                <<"file">> => <<"src/my_worker.erl">>,
                <<"line">> => 42
            },
            #{<<"module">> => <<"gen_server">>, <<"function">> => <<"try_dispatch/4">>}
        ],
        maps:get(<<"frames">>, Report)
    ),
    Context = maps:get(<<"context">>, Report),
    ?assertEqual(<<"my_worker:init/1">>, maps:get(<<"initial_call">>, Context)),
    ?assert(is_binary(maps:get(<<"time">>, maps:get(<<"meta">>, Report)))).

%% The platform groups by the reason, one line of it.
a_long_reason_is_one_line_test() ->
    Reason = lists:duplicate(40, {some_long_atom, "and a string"}),
    {ok, Report} = nh_ext_error_reports:from_log(crash(error, Reason, [])),
    ?assertEqual(nomatch, binary:match(maps:get(<<"reason">>, Report), <<"\n">>)).

frames_are_capped_at_thirty_test() ->
    Stacktrace = [{m, f, 0, []} || _ <- lists:seq(1, 40)],
    {ok, Report} = nh_ext_error_reports:from_log(crash(error, badarg, Stacktrace)),
    ?assertEqual(30, length(maps:get(<<"frames">>, Report))).

a_frame_with_arguments_counts_them_test() ->
    {ok, Report} = nh_ext_error_reports:from_log(crash(error, badarg, [{m, f, [a, b], []}])),
    ?assertMatch([#{<<"function">> := <<"f/2">>}], maps:get(<<"frames">>, Report)).

other_log_events_are_not_reports_test() ->
    ?assertEqual(
        ignore,
        nh_ext_error_reports:from_log(#{
            level => error, timestamp => now_us(), msg => {"boom ~p", [1]}
        })
    ),
    ?assertEqual(
        ignore,
        nh_ext_error_reports:from_log(#{level => error, msg => {string, "=CRASH REPORT===="}})
    ),
    ?assertEqual(ignore, nh_ext_error_reports:from_log(#{})).

%% A format with arguments of another shape is left alone rather than misread.
a_crash_report_of_another_shape_is_ignored_test() ->
    ?assertEqual(
        ignore,
        nh_ext_error_reports:from_log(#{
            level => error, timestamp => now_us(), msg => {?FORMAT, [too, few]}
        })
    ).

%% Before the clock is set there is no honest time to give.
no_clock_no_report_test() ->
    Event = (crash(error, badarg, []))#{timestamp => 1000},
    ?assertEqual(ignore, nh_ext_error_reports:from_log(Event)).

a_manual_report_test() ->
    {ok, Report} = nh_ext_error_reports:manual(error, {timeout, 5000}, #{
        context => #{queue => uploads, attempt => 3},
        fingerprint => <<"payment-gateway">>
    }),
    ?assertEqual(<<"error">>, maps:get(<<"kind">>, Report)),
    ?assertEqual(<<"{timeout,5000}">>, maps:get(<<"reason">>, Report)),
    ?assertEqual(<<"manual">>, maps:get(<<"source">>, Report)),
    ?assertEqual(<<"payment-gateway">>, maps:get(<<"fingerprint">>, Report)),
    Context = maps:get(<<"context">>, Report),
    ?assertEqual(<<"uploads">>, maps:get(<<"queue">>, Context)),
    ?assertEqual(<<"3">>, maps:get(<<"attempt">>, Context)),
    ?assertEqual([], maps:get(<<"frames">>, Report)).

a_dropped_report_groups_on_its_own_test() ->
    {ok, Report} = nh_ext_error_reports:dropped(7),
    ?assertEqual(<<"dropped 7 reports">>, maps:get(<<"reason">>, Report)),
    ?assertEqual(<<"nerves_hub_link:dropped_reports">>, maps:get(<<"fingerprint">>, Report)).

a_long_message_is_cut_under_the_cap_test() ->
    Big = binary_to_list(binary:copy(<<"x">>, 20000)),
    {ok, Report} = nh_ext_error_reports:from_log(crash(error, Big, [])),
    ?assert(byte_size(maps:get(<<"message">>, Report)) =< 8192),
    ?assert(byte_size(maps:get(<<"reason">>, Report)) =< 2048).

batch_test() ->
    ?assertEqual(#{<<"reports">> => [a]}, nh_ext_error_reports:batch([a])),
    ?assertEqual(<<"error_reports:report">>, nh_ext_error_reports:event()),
    ?assertEqual(25, nh_ext_error_reports:max_batch()).
