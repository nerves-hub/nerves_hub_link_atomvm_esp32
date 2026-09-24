%
% SPDX-License-Identifier: Apache-2.0 OR LGPL-2.1-or-later
%
-module(nh_scripts_tests).

-include_lib("eunit/include/eunit.hrl").

runs_each_command_in_order_test() ->
    Result = nh_scripts:run(<<"help\r\nuptime">>),
    ?assertEqual(<<"completed">>, maps:get(<<"result">>, Result)),
    Output = maps:get(<<"output">>, Result),
    {Help, _} = binary:match(Output, <<"> help">>),
    {Uptime, _} = binary:match(Output, <<"> uptime">>),
    ?assert(Help < Uptime).

comments_and_blank_lines_are_skipped_test() ->
    Result = nh_scripts:run(<<"# a comment\n\n   \nuptime\n">>),
    ?assertEqual(<<"completed">>, maps:get(<<"result">>, Result)),
    ?assertEqual(nomatch, binary:match(maps:get(<<"output">>, Result), <<"comment">>)).

%% Evaluating nothing is `nil' on Nerves, and NervesHub treats connecting code
%% that returns `nil' as having failed.
an_empty_script_returns_nil_test() ->
    ?assertEqual(<<"nil">>, maps:get(<<"return">>, nh_scripts:run(<<"# nothing\n">>))).

the_first_unknown_line_stops_the_script_test() ->
    Result = nh_scripts:run(<<"uptime\nIO.puts(1)\nhelp">>),
    ?assertEqual(<<"error">>, maps:get(<<"result">>, Result)),
    ?assertEqual(nomatch, binary:match(maps:get(<<"output">>, Result), <<"> help">>)).

reboot_is_refused_test() ->
    Result = nh_scripts:run(<<"reboot">>),
    ?assertEqual(<<"error">>, maps:get(<<"result">>, Result)),
    ?assertEqual(<<"reboot is not allowed in a script">>, maps:get(<<"reason">>, Result)).

not_text_is_an_error_test() ->
    ?assertEqual(<<"error">>, maps:get(<<"result">>, nh_scripts:run(42))).
