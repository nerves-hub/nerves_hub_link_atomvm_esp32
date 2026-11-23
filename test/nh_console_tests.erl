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

%% Output goes up in pieces, and a piece never ends inside a character.
chunks_test() ->
    ?assertEqual([<<"abc">>], nh_console:chunks(<<"abc">>, 4)),
    ?assertEqual([<<"abcd">>, <<"ef">>], nh_console:chunks(<<"abcdef">>, 4)),
    %% "é" is two bytes: the cut moves back rather than split it
    ?assertEqual([<<"abc">>, <<"é"/utf8, "d">>], nh_console:chunks(<<"abcéd"/utf8>>, 4)),
    Long = binary:copy(<<"ação "/utf8>>, 100),
    Chunks = nh_console:chunks(Long, 256),
    ?assertEqual(Long, iolist_to_binary(Chunks)),
    lists:foreach(
        fun(Chunk) ->
            ?assert(byte_size(Chunk) =< 256),
            ?assertMatch(<<_/binary>>, unicode:characters_to_binary(Chunk))
        end,
        Chunks
    ).
