%
% SPDX-License-Identifier: Apache-2.0 OR LGPL-2.1-or-later
%

%%-----------------------------------------------------------------------------
%% @doc The remote console NervesHub attaches to.
%%
%% `nerves_hub_link' on Nerves answers the console channel with a real IEx
%% session over ExTTY, so an operator gets the language. AtomVM has no shell and
%% no ExTTY, so this is a debug terminal instead: a fixed set of commands that
%% answer the questions a console is usually opened to answer.
%%
%% That difference is worth being plain about. This will not evaluate Erlang,
%% and it is not a way in to a running system — it reports, and it reboots.
%%
%% == The protocol ==
%%
%% NervesHub drives it over the `console' topic:
%%
%% ```
%% dn           %{"data" => Keystrokes}    server -> device
%% window_size  %{"height" =>, "width" =>} server -> device
%% restart                                 server -> device
%% up           %{"data" => Output}        device -> server
%% '''
%%
%% Keystrokes arrive as they are typed, so this echoes them back: nothing else
%% is going to, and a terminal that shows nothing while you type reads as
%% broken. `restart' clears the session the way it restarts IEx on Nerves —
%% it does not restart the device, which is what `reboot' is for.
%%
%% An application can add commands of its own (`console_commands' in
%% `nerves_hub_link''s config): `{Name, Description, Fun}', where `Fun' takes
%% the line's arguments and returns the output. They run in the agent, so they
%% must be quick, and one that raises prints the error instead of taking the
%% console down.
%%
%% One with a built-in's name replaces it (`net', say, for a richer status).
%%
%% `help' lists the commands by section: the built-in ones are in `device' and
%% `network'. `{Section, Name, Description, Fun}' puts an application's command
%% in a section, one of those or its own; without one it goes in
%% `application'. Sections come in the order they first appear.
%%
%% The up and down arrows walk back and forth through the last lines entered,
%% as a shell does, and `clear' clears the screen.
%%
%% File transfer is declined. `file-data/*' exists to push a file onto a device
%% with a filesystem to put it in, and this one has partitions.
%% @end
%%-----------------------------------------------------------------------------
-module(nh_console).

-export([new/0, new/1, banner/0, prompt/0, handle_input/2, restart/1, parse/1, commands/0]).
-export([run_command/1]).

%% Terminals want CRLF, and NervesHub replays exactly what it is sent.
-define(EOL, <<"\r\n">>).
-define(PROMPT, <<"esp32> ">>).

-define(CTRL_C, 3).
-define(BACKSPACE, 8).
-define(TAB, 9).
-define(DELETE, 127).
-define(ESC, 27).

%% Lines kept for the arrows: enough to repeat a session's few commands,
%% little enough to cost nothing on a device without PSRAM.
-define(HISTORY, 20).
%% Back to the start of the line and erase it, so a recalled line replaces
%% what was there; and the whole screen, for `clear'.
-define(ERASE_LINE, <<"\r\e[K">>).
-define(CLEAR_SCREEN, <<"\e[2J\e[H">>).

-type command() ::
    {binary(), binary(), fun(([binary()]) -> iodata())}
    | {binary(), binary(), binary(), fun(([binary()]) -> iodata())}.
-type state() :: #{
    line := binary(),
    mode := input | escape | escape_bracket,
    commands := [command()],
    %% Newest first; `back' is how far up the arrows are, 0 for the line being
    %% typed, which `typed' keeps while they are.
    history := [binary()],
    back := non_neg_integer(),
    typed := binary()
}.

-export_type([state/0, command/0]).

%%-----------------------------------------------------------------------------
%% @doc A console session with nothing typed.
%% @end
%%-----------------------------------------------------------------------------
-spec new() -> state().
new() -> new([]).

%%-----------------------------------------------------------------------------
%% @doc A console session with the application's own commands as well.
%% @end
%%-----------------------------------------------------------------------------
-spec new([command()]) -> state().
new(Commands) ->
    #{
        line => <<>>,
        mode => input,
        commands => [sectioned(Command) || Command <- Commands],
        history => [],
        back => 0,
        typed => <<>>
    }.

sectioned({Name, Description, Fun}) -> {<<"application">>, Name, Description, Fun};
sectioned({_Section, _Name, _Description, _Fun} = Command) -> Command.

%%-----------------------------------------------------------------------------
%% @doc What to send when someone first attaches.
%%
%% A console that says nothing until you type looks like one that is not
%% working, and the commands here are not guessable.
%% @end
%%-----------------------------------------------------------------------------
-spec banner() -> binary().
banner() ->
    <<
        (?EOL)/binary,
        "NervesHub console on AtomVM. No shell here -- `help` lists what this can do.",
        (?EOL)/binary,
        (?PROMPT)/binary
    >>.

-spec prompt() -> binary().
prompt() -> ?PROMPT.

%%-----------------------------------------------------------------------------
%% @doc Reset the session, as `restart' does to IEx on Nerves.
%% @end
%%-----------------------------------------------------------------------------
-spec restart(state()) -> {state(), binary()}.
restart(State) ->
    {
        State#{line => <<>>, mode => input, back => 0},
        <<(?EOL)/binary, "*** Console restarted ***", (?EOL)/binary, (?PROMPT)/binary>>
    }.

%%-----------------------------------------------------------------------------
%% @doc Feed keystrokes in, get terminal output back.
%%
%% Returns everything to send in one `up', so a line that runs a command echoes
%% the newline, the output and the next prompt together.
%% @end
%%-----------------------------------------------------------------------------
-spec handle_input(binary(), state()) -> {state(), binary()}.
handle_input(Data, State) ->
    {Next, Output} = fold_input(Data, State, []),
    {Next, iolist_to_binary(lists:reverse(Output))}.

fold_input(<<>>, State, Acc) ->
    {State, Acc};
%% An arrow key is three bytes. Up and down walk the history; the rest are
%% swallowed rather than printing the escape, which would corrupt the line the
%% operator can see.
fold_input(<<?ESC, Rest/binary>>, #{mode := input} = State, Acc) ->
    fold_input(Rest, State#{mode => escape}, Acc);
fold_input(<<$[, Rest/binary>>, #{mode := escape} = State, Acc) ->
    fold_input(Rest, State#{mode => escape_bracket}, Acc);
fold_input(<<_Byte, Rest/binary>>, #{mode := escape} = State, Acc) ->
    fold_input(Rest, State#{mode => input}, Acc);
fold_input(<<$A, Rest/binary>>, #{mode := escape_bracket, back := Back} = State, Acc) ->
    recall(Rest, Back + 1, State#{mode => input}, Acc);
fold_input(<<$B, Rest/binary>>, #{mode := escape_bracket, back := Back} = State, Acc) ->
    recall(Rest, Back - 1, State#{mode => input}, Acc);
fold_input(<<_Byte, Rest/binary>>, #{mode := escape_bracket} = State, Acc) ->
    fold_input(Rest, State#{mode => input}, Acc);
fold_input(<<?CTRL_C, Rest/binary>>, State, Acc) ->
    fold_input(Rest, State#{line => <<>>, back => 0}, [
        <<"^C", (?EOL)/binary, (?PROMPT)/binary>> | Acc
    ]);
fold_input(<<Byte, Rest/binary>>, #{line := Line} = State, Acc) when
    Byte =:= ?BACKSPACE; Byte =:= ?DELETE
->
    case Line of
        <<>> ->
            fold_input(Rest, State, Acc);
        _ ->
            Shorter = binary:part(Line, 0, byte_size(Line) - 1),
            %% Back up, overwrite with a space, back up again: the only way to
            %% remove a character from a dumb terminal.
            fold_input(Rest, State#{line => Shorter}, [<<"\b \b">> | Acc])
    end;
%% CRLF is one Enter, not two. Terminals differ on which they send, and
%% treating the pair as two would print a second prompt for a line nobody typed.
fold_input(<<$\r, $\n, Rest/binary>>, State, Acc) ->
    submit(Rest, State, Acc);
fold_input(<<$\r, Rest/binary>>, State, Acc) ->
    submit(Rest, State, Acc);
fold_input(<<$\n, Rest/binary>>, State, Acc) ->
    submit(Rest, State, Acc);
fold_input(<<?TAB, Rest/binary>>, State, Acc) ->
    fold_input(Rest, State, Acc);
%% Anything else printable joins the line and is echoed.
fold_input(<<Byte, Rest/binary>>, #{line := Line} = State, Acc) when Byte >= 32, Byte < 127 ->
    fold_input(Rest, State#{line => <<Line/binary, Byte>>}, [<<Byte>> | Acc]);
fold_input(<<_Byte, Rest/binary>>, State, Acc) ->
    fold_input(Rest, State, Acc).

submit(Rest, #{line := Line, commands := Commands, history := History} = State, Acc) ->
    Output = <<(?EOL)/binary, (run(Line, Commands))/binary, (?PROMPT)/binary>>,
    State1 = State#{line => <<>>, back => 0, history => remember(trim(Line), History)},
    fold_input(Rest, State1, [Output | Acc]).

%% A blank line, or the one just entered again, adds nothing to walk through.
remember(<<>>, History) -> History;
remember(Line, [Line | _] = History) -> History;
remember(Line, History) -> lists:sublist([Line | History], ?HISTORY).

%% Line `Back' of the history in place of the one on screen; 0 is what was
%% being typed before the arrows. Past either end, nothing moves.
recall(Rest, Back, #{history := History} = State, Acc) when Back < 0; Back > length(History) ->
    fold_input(Rest, State, Acc);
recall(Rest, Back, #{back := 0, line := Line} = State, Acc) ->
    show(Rest, Back, State#{typed => Line}, Acc);
recall(Rest, Back, State, Acc) ->
    show(Rest, Back, State, Acc).

show(Rest, 0, #{typed := Typed} = State, Acc) ->
    redraw(Rest, Typed, State#{back => 0}, Acc);
show(Rest, Back, #{history := History} = State, Acc) ->
    redraw(Rest, lists:nth(Back, History), State#{back => Back}, Acc).

redraw(Rest, Line, State, Acc) ->
    fold_input(Rest, State#{line => Line}, [
        <<(?ERASE_LINE)/binary, (?PROMPT)/binary, Line/binary>> | Acc
    ]).

%%-----------------------------------------------------------------------------
%% @doc Split a line into a command and its arguments.
%% @end
%%-----------------------------------------------------------------------------
-spec parse(binary()) -> {binary(), [binary()]} | empty.
parse(Line) ->
    case [Word || Word <- binary:split(trim(Line), <<" ">>, [global]), Word =/= <<>>] of
        [] -> empty;
        [Command | Args] -> {Command, Args}
    end.

trim(Line) ->
    trim_trailing(trim_leading(Line)).

trim_leading(<<C, Rest/binary>>) when C =:= $\s; C =:= $\t; C =:= $\r; C =:= $\n ->
    trim_leading(Rest);
trim_leading(Line) ->
    Line.

trim_trailing(<<>>) ->
    <<>>;
trim_trailing(Line) ->
    case binary:last(Line) of
        C when C =:= $\s; C =:= $\t; C =:= $\r; C =:= $\n ->
            trim_trailing(binary:part(Line, 0, byte_size(Line) - 1));
        _ ->
            Line
    end.

%%-----------------------------------------------------------------------------
%% @doc The commands and what each is for.
%% @end
%%-----------------------------------------------------------------------------
-spec commands() -> [{binary(), binary()}].
commands() ->
    [{<<"help">>, <<"this list">>}] ++
        [{Name, Description} || {_Section, Name, Description} <- built_in()].

%% The built-in commands, by section.
built_in() ->
    [
        {<<"device">>, <<"info">>, <<"AtomVM and application versions">>},
        {<<"device">>, <<"firmware">>, <<"the running packbeam, its digest and slot">>},
        {<<"device">>, <<"signature">>, <<"check the running firmware's signature">>},
        {<<"device">>, <<"memory">>, <<"heap and process counts">>},
        {<<"device">>, <<"partitions">>, <<"the flash partition table">>},
        {<<"device">>, <<"uptime">>, <<"how long since boot">>},
        {<<"device">>, <<"reboot">>, <<"restart the device">>},
        {<<"device">>, <<"clear">>, <<"clear the screen (up/down arrows: the last commands)">>},
        {<<"network">>, <<"net">>, <<"network address and signal">>},
        {<<"network">>, <<"geo">>, <<"resolve this device's location over GeoIP">>}
    ].

run(Line, Commands) ->
    case parse(Line) of
        empty -> <<>>;
        {<<"help">>, _Args} -> help(Commands);
        {Command, Args} -> execute(lists:keyfind(Command, 2, Commands), Command, Args)
    end.

%%-----------------------------------------------------------------------------
%% @doc Run one command line, saying whether it was a command at all.
%%
%% The console only prints, so it does not care. A script does: a line that is
%% not a command is a script that did not do what it says, and NervesHub should
%% hear that it failed rather than that it completed. A script runs the
%% built-in commands, not the application's.
%% @end
%%-----------------------------------------------------------------------------
-spec run_command(binary()) -> {ok, binary()} | {error, binary()}.
run_command(Line) ->
    case parse(Line) of
        empty ->
            {ok, <<>>};
        {Command, _Args} ->
            case lists:keymember(Command, 1, commands()) of
                true -> {ok, run(Line, [])};
                false -> {error, run(Line, [])}
            end
    end.

%% An application's command of a built-in's name replaces it, in `help' as
%% when it runs.
help(Commands) ->
    Own = [Name || {_Section, Name, _Description, _Fun} <- Commands],
    All =
        [
            Command
         || {_Section, Name, _Description} = Command <- built_in(), not lists:member(Name, Own)
        ] ++
            [{Section, Name, Description} || {Section, Name, Description, _Fun} <- Commands],
    Sections = lists:foldl(
        fun({Section, _, _}, Seen) ->
            case lists:member(Section, Seen) of
                true -> Seen;
                false -> Seen ++ [Section]
            end
        end,
        [],
        All
    ),
    iolist_to_binary(
        [
            [
                [Section, ?EOL],
                [
                    <<"  ", (pad(Name, 12))/binary, Description/binary, (?EOL)/binary>>
                 || {In, Name, Description} <- All, In =:= Section
                ],
                ?EOL
            ]
         || Section <- Sections
        ]
    ).

%% The application's, or else a built-in one.
execute({_Section, _Name, _Description, Fun}, _Command, Args) ->
    try
        iolist_to_binary(Fun(Args))
    catch
        Class:Reason ->
            iolist_to_binary(io_lib:format("~p: ~p~ts", [Class, Reason, ?EOL]))
    end;
execute(false, Command, Args) ->
    execute(Command, Args).

execute(<<"clear">>, _Args) ->
    ?CLEAR_SCREEN;
execute(<<"info">>, _Args) ->
    lines([
        {<<"atomvm">>, nh_metadata:atomvm_version()},
        {<<"system">>, info(system_architecture)},
        {<<"word size">>, integer(info(wordsize))}
    ]);
execute(<<"firmware">>, _Args) ->
    Slot = safe(fun() -> nh_flash:boot_partition() end),
    Pending =
        case safe(fun() -> nh_ota:pending() end) of
            {ok, PendingSlot} -> PendingSlot;
            _ -> <<"none">>
        end,

    Base = [{<<"slot">>, Slot}, {<<"pending">>, Pending}],

    case safe(fun() -> nh_flash:read_metadata() end) of
        {ok, Metadata} ->
            lines(
                Base ++
                    [
                        {<<"app">>, maps:get(app_name, Metadata, undefined)},
                        {<<"version">>, maps:get(app_version, Metadata, undefined)},
                        {<<"sha256">>, maps:get(avm_sha256, Metadata, undefined)}
                    ]
            );
        Other ->
            lines(Base ++ [{<<"metadata">>, describe(Other)}])
    end;
execute(<<"memory">>, _Args) ->
    lines([
        {<<"processes">>, integer(info(process_count))},
        {<<"atoms">>, integer(info(atom_count))},
        {<<"free heap">>, integer(info(esp32_free_heap_size))},
        {<<"largest block">>, integer(info(esp32_largest_free_block))},
        {<<"min free heap">>, integer(info(esp32_minimum_free_size))}
    ]);
execute(<<"partitions">>, _Args) ->
    case safe(fun() -> apply(esp, partition_list, []) end) of
        Partitions when is_list(Partitions) ->
            iolist_to_binary([
                [
                    <<"  ", (pad(name_of(P), 12))/binary, (describe(size_of(P)))/binary,
                        (?EOL)/binary>>
                ]
             || P <- Partitions
            ]);
        Other ->
            lines([{<<"partitions">>, describe(Other)}])
    end;
execute(<<"net">>, _Args) ->
    lines([
        {<<"rssi">>, integer(safe(fun() -> apply(network, sta_rssi, []) end))},
        {<<"status">>, describe(safe(fun() -> apply(network, sta_status, []) end))}
    ]);
execute(<<"signature">>, _Args) ->
    Slot = safe(fun() -> nh_flash:boot_partition() end),
    lines([
        {<<"slot">>, Slot},
        {<<"found at">>, integer(safe(fun() -> element(2, nh_flash:signature_offset(Slot)) end))},
        {<<"verify">>, describe(safe(fun() -> nh_flash:verify_signature(Slot, keys()) end))},
        {<<"keys">>, integer(length(keys()))}
    ]);
execute(<<"geo">>, _Args) ->
    Location = safe(fun() -> nh_ext_geo:resolve() end),
    lines([
        {<<"source">>, map_value(Location, <<"source">>)},
        {<<"latitude">>, map_value(Location, <<"latitude">>)},
        {<<"longitude">>, map_value(Location, <<"longitude">>)},
        {<<"error">>, map_value(Location, <<"error_code">>)},
        {<<"detail">>, map_value(Location, <<"error_description">>)}
    ]);
execute(<<"uptime">>, _Args) ->
    Ms = safe(fun() -> erlang:system_time(millisecond) end),
    lines([{<<"clock">>, integer(Ms div 1000)}]);
execute(<<"reboot">>, _Args) ->
    _ = safe(fun() -> apply(esp, restart, []) end),
    <<"rebooting", (?EOL)/binary>>;
execute(Command, _Args) ->
    <<"unknown command: ", Command/binary, ". Try `help`.", (?EOL)/binary>>.

%% ------------------------------------------------------------------- helpers

lines(Pairs) ->
    iolist_to_binary([
        [<<"  ", (pad(Key, 14))/binary, (describe(Value))/binary, (?EOL)/binary>>]
     || {Key, Value} <- Pairs
    ]).

%% Set by the agent when it starts, so the console can answer for the same keys
%% the updater would use.
keys() ->
    case erlang:get(nh_firmware_keys) of
        Keys when is_list(Keys) -> Keys;
        _ -> []
    end.

map_value(Map, Key) when is_map(Map) -> maps:get(Key, Map, undefined);
map_value(_Other, _Key) -> undefined.

pad(Bin, Width) when byte_size(Bin) >= Width -> <<Bin/binary, " ">>;
pad(Bin, Width) -> <<Bin/binary, (binary:copy(<<" ">>, Width - byte_size(Bin)))/binary>>.

describe(undefined) -> <<"unknown">>;
describe(Bin) when is_binary(Bin) -> Bin;
describe(N) when is_integer(N) -> integer_to_binary(N);
describe(F) when is_float(F) -> float_to_binary(F, [{decimals, 5}]);
describe(A) when is_atom(A) -> atom_to_binary(A, utf8);
describe(L) when is_list(L) -> unicode_or_placeholder(L);
describe(T) when is_tuple(T) -> <<"{...}">>;
describe(_) -> <<"unknown">>.

unicode_or_placeholder(L) ->
    case lists:all(fun(C) -> is_integer(C) andalso C >= 32 andalso C < 127 end, L) of
        true -> list_to_binary(L);
        false -> <<"[...]">>
    end.

integer(N) when is_integer(N) -> N;
integer(_) -> undefined.

info(Key) ->
    safe(fun() -> erlang:system_info(Key) end).

%% Every command has to survive a platform that does not have the thing it asks
%% about, because the console is the tool you reach for when something is
%% already wrong.
safe(Fun) ->
    try Fun() of
        Result -> Result
    catch
        _:_ -> undefined
    end.

name_of(P) when is_tuple(P), tuple_size(P) >= 1 -> describe(element(1, P));
name_of(_) -> <<"?">>.

size_of(P) when is_tuple(P), tuple_size(P) >= 5 -> element(5, P);
size_of(_) -> undefined.
