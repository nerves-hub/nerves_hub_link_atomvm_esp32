%
% SPDX-License-Identifier: Apache-2.0 OR LGPL-2.1-or-later
%
-module(nh_console_tests).

-include_lib("eunit/include/eunit.hrl").

feed(Data) -> feed(Data, nh_console:new()).

feed(Data, State) -> nh_console:handle_input(Data, State).

%% Nothing else echoes what an operator types, and a terminal that shows
%% nothing while you type reads as broken.
typing_is_echoed_test() ->
    {State, Output} = feed(<<"help">>),

    ?assertEqual(<<"help">>, Output),
    ?assertEqual(<<"help">>, maps:get(line, State)).

%% Back up, overwrite, back up: the only way to erase on a dumb terminal.
backspace_erases_a_character_test() ->
    {State0, _} = feed(<<"helo">>),
    {State1, Output} = feed(<<8>>, State0),

    ?assertEqual(<<"\b \b">>, Output),
    ?assertEqual(<<"hel">>, maps:get(line, State1)).

backspace_on_an_empty_line_does_nothing_test() ->
    {State, Output} = feed(<<127>>),

    ?assertEqual(<<>>, Output),
    ?assertEqual(<<>>, maps:get(line, State)).

ctrl_c_abandons_the_line_test() ->
    {State0, _} = feed(<<"reboo">>),
    {State1, Output} = feed(<<3>>, State0),

    ?assertEqual(<<>>, maps:get(line, State1)),
    ?assertMatch({_, _}, binary:match(Output, <<"^C">>)),
    ?assertMatch({_, _}, binary:match(Output, nh_console:prompt())).

%% An arrow key is an escape sequence. Printing it would corrupt the line the
%% operator can see.
arrow_keys_are_swallowed_test() ->
    {State, Output} = feed(<<"ab", 27, $[, $A, "c">>),

    ?assertEqual(<<"abc">>, maps:get(line, State)),
    ?assertEqual(<<"abc">>, Output).

enter_runs_the_line_and_prompts_again_test() ->
    {State, Output} = feed(<<"help\r">>),

    ?assertEqual(<<>>, maps:get(line, State)),
    ?assertMatch({_, _}, binary:match(Output, <<"reboot">>)),
    ?assertMatch({_, _}, binary:match(Output, nh_console:prompt())).

%% Terminals disagree about Enter. Treating CRLF as two would print a prompt
%% for a line nobody typed.
crlf_is_one_enter_test() ->
    {_, Crlf} = feed(<<"help\r\n">>),
    {_, Cr} = feed(<<"help\r">>),

    ?assertEqual(Cr, Crlf).

an_empty_line_just_prompts_test() ->
    {_State, Output} = feed(<<"\r">>),
    ?assertEqual(<<"\r\n", (nh_console:prompt())/binary>>, Output).

an_unknown_command_says_so_test() ->
    {_State, Output} = feed(<<"wat\r">>),

    ?assertMatch({_, _}, binary:match(Output, <<"unknown command: wat">>)),
    ?assertMatch({_, _}, binary:match(Output, <<"help">>)).

%% Typed a character at a time, which is how a terminal actually sends them.
input_arrives_one_byte_at_a_time_test() ->
    State =
        lists:foldl(
            fun(Byte, Acc) ->
                {Next, _} = feed(<<Byte>>, Acc),
                Next
            end,
            nh_console:new(),
            binary_to_list(<<"info">>)
        ),

    ?assertEqual(<<"info">>, maps:get(line, State)).

help_lists_every_command_test() ->
    {_State, Output} = feed(<<"help\r">>),

    lists:foreach(
        fun({Name, _}) ->
            ?assertMatch({_, _}, {binary:match(Output, Name), Name})
        end,
        nh_console:commands()
    ).

%% Off a device none of these can answer, and the console is the tool you reach
%% for when something is already wrong — so every one has to degrade, not crash.
every_command_survives_a_platform_without_the_answers_test() ->
    lists:foreach(
        fun({Name, _}) ->
            case Name of
                %% would restart the test run
                <<"reboot">> ->
                    ok;
                _ ->
                    {_State, Output} = feed(<<Name/binary, "\r">>),
                    ?assert(byte_size(Output) > 0)
            end
        end,
        nh_console:commands()
    ).

restart_clears_the_session_test() ->
    {State0, _} = feed(<<"half typed">>),
    {State1, Output} = nh_console:restart(State0),

    ?assertEqual(<<>>, maps:get(line, State1)),
    ?assertMatch({_, _}, binary:match(Output, <<"Console restarted">>)).

banner_names_help_test() ->
    ?assertMatch({_, _}, binary:match(nh_console:banner(), <<"help">>)),
    ?assertMatch({_, _}, binary:match(nh_console:banner(), nh_console:prompt())).

parse_splits_a_command_from_its_arguments_test() ->
    ?assertEqual({<<"help">>, []}, nh_console:parse(<<"help">>)),
    ?assertEqual({<<"a">>, [<<"b">>, <<"c">>]}, nh_console:parse(<<"a b c">>)),
    ?assertEqual({<<"a">>, [<<"b">>]}, nh_console:parse(<<"   a    b   ">>)),
    ?assertEqual(empty, nh_console:parse(<<"">>)),
    ?assertEqual(empty, nh_console:parse(<<"   \r\n">>)).

%% An application's commands run with the line's arguments, show up in `help',
%% and one that raises prints the error rather than taking the console down.
application_commands_test() ->
    Commands = [
        {<<"echo">>, <<"say it back">>, fun(Args) -> [lists:join(<<"|">>, Args), <<"\r\n">>] end},
        {<<"boom">>, <<"raise">>, fun(_Args) -> error(kaboom) end}
    ],
    State = nh_console:new(Commands),
    {State1, Echo} = nh_console:handle_input(<<"echo a b\r">>, State),
    ?assertMatch({_, _}, binary:match(Echo, <<"a|b">>)),
    {State2, Help} = nh_console:handle_input(<<"help\r">>, State1),
    ?assertMatch({_, _}, binary:match(Help, <<"say it back">>)),
    ?assertMatch({_, _}, binary:match(Help, <<"uptime">>)),
    {State3, Boom} = nh_console:handle_input(<<"boom\r">>, State2),
    ?assertMatch({_, _}, binary:match(Boom, <<"kaboom">>)),
    {State4, _} = nh_console:restart(State3),
    {_, Again} = nh_console:handle_input(<<"echo c\r">>, State4),
    ?assertMatch({_, _}, binary:match(Again, <<"c">>)).

%% `help' groups by section: the built-in ones, an application's command in one
%% of those or its own, and the rest under `application', in order of first
%% appearance.
help_groups_by_section_test() ->
    Noop = fun(_Args) -> <<>> end,
    State = nh_console:new([
        {<<"plain">>, <<"no section">>, Noop},
        {<<"network">>, <<"ping">>, <<"reach a host">>, Noop},
        {<<"storage">>, <<"fs">>, <<"files">>, Noop}
    ]),
    {_, Help} = nh_console:handle_input(<<"help\r">>, State),
    Order = [
        <<"device\r\n">>,
        <<"uptime">>,
        <<"network\r\n">>,
        <<"geo">>,
        <<"ping">>,
        <<"application\r\n">>,
        <<"plain">>,
        <<"storage\r\n">>,
        <<"fs ">>
    ],
    Positions = [element(1, binary:match(Help, Part)) || Part <- Order],
    ?assertEqual(lists:sort(Positions), Positions),
    {_, Ping} = nh_console:handle_input(<<"ping\r">>, State),
    ?assertEqual(nomatch, binary:match(Ping, <<"unknown">>)).

-define(UP, <<27, $[, $A>>).
-define(DOWN, <<27, $[, $B>>).

%% Up brings back the last line, again the one before; down walks forward, to
%% what was being typed.
arrows_walk_the_history_test() ->
    {State0, _} = feed(<<"uptime\rmemory\rne">>),
    {State1, Out1} = nh_console:handle_input(?UP, State0),
    {State2, _} = nh_console:handle_input(?UP, State1),
    {State3, _} = nh_console:handle_input(?UP, State2),
    {State4, _} = nh_console:handle_input(?DOWN, State3),
    {State5, Out5} = nh_console:handle_input(?DOWN, State4),

    ?assertEqual(<<"memory">>, maps:get(line, State1)),
    ?assertEqual(<<"\r\e[Kesp32> memory">>, Out1),
    ?assertEqual(<<"uptime">>, maps:get(line, State2)),
    %% Past the oldest, nothing moves.
    ?assertEqual(<<"uptime">>, maps:get(line, State3)),
    ?assertEqual(<<"memory">>, maps:get(line, State4)),
    ?assertEqual(<<"ne">>, maps:get(line, State5)),
    ?assertEqual(<<"\r\e[Kesp32> ne">>, Out5).

%% A recalled line runs like a typed one, and goes back on top.
a_recalled_line_runs_test() ->
    {State0, _} = feed(<<"uptime\rmemory\r">>),
    {State1, _} = nh_console:handle_input(<<?UP/binary, ?UP/binary, "\r">>, State0),
    ?assertEqual([<<"uptime">>, <<"memory">>, <<"uptime">>], maps:get(history, State1)).

blank_and_repeated_lines_are_not_kept_test() ->
    {State, _} = feed(<<"uptime\r\r  \ruptime\r">>),
    ?assertEqual([<<"uptime">>], maps:get(history, State)).

the_history_is_bounded_test() ->
    Lines = iolist_to_binary([[<<"c">>, integer_to_binary(N), $\r] || N <- lists:seq(1, 30)]),
    {State, _} = feed(Lines),
    ?assertEqual(20, length(maps:get(history, State))),
    ?assertEqual(<<"c30">>, hd(maps:get(history, State))).

clear_clears_the_screen_test() ->
    {_, Output} = feed(<<"clear\r">>),
    ?assertMatch({_, _}, binary:match(Output, <<"\e[2J\e[H">>)),
    ?assertMatch({_, _}, binary:match(Output, nh_console:prompt())).

%% An application's `net' replaces the built-in one, in `help' too.
an_application_command_replaces_a_built_in_test() ->
    State = nh_console:new([
        {<<"network">>, <<"net">>, <<"the app's net">>, fun(_) -> <<"mine">> end}
    ]),
    {_, Help} = nh_console:handle_input(<<"help\r">>, State),
    {_, Net} = nh_console:handle_input(<<"net\r">>, State),
    ?assertMatch({_, _}, binary:match(Help, <<"the app's net">>)),
    ?assertEqual(nomatch, binary:match(Help, <<"network address and signal">>)),
    ?assertMatch({_, _}, binary:match(Net, <<"mine">>)).
