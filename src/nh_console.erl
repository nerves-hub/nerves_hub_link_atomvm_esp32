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
%% File transfer is declined. `file-data/*' exists to push a file onto a device
%% with a filesystem to put it in, and this one has partitions.
%% @end
%%-----------------------------------------------------------------------------
-module(nh_console).

-export([new/0, banner/0, prompt/0, handle_input/2, restart/1, parse/1, commands/0]).
-export([run_command/1]).

%% Terminals want CRLF, and NervesHub replays exactly what it is sent.
-define(EOL, <<"\r\n">>).
-define(PROMPT, <<"esp32> ">>).

-define(CTRL_C, 3).
-define(BACKSPACE, 8).
-define(TAB, 9).
-define(DELETE, 127).
-define(ESC, 27).

-type state() :: #{line := binary(), mode := input | escape | escape_bracket}.

-export_type([state/0]).

%%-----------------------------------------------------------------------------
%% @doc A console session with nothing typed.
%% @end
%%-----------------------------------------------------------------------------
-spec new() -> state().
new() -> #{line => <<>>, mode => input}.

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
restart(_State) ->
    {new(), <<(?EOL)/binary, "*** Console restarted ***", (?EOL)/binary, (?PROMPT)/binary>>}.

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
%% An arrow key is three bytes. Swallow them rather than printing the escape,
%% which would corrupt the line the operator can see.
fold_input(<<?ESC, Rest/binary>>, #{mode := input} = State, Acc) ->
    fold_input(Rest, State#{mode => escape}, Acc);
fold_input(<<$[, Rest/binary>>, #{mode := escape} = State, Acc) ->
    fold_input(Rest, State#{mode => escape_bracket}, Acc);
fold_input(<<_Byte, Rest/binary>>, #{mode := escape} = State, Acc) ->
    fold_input(Rest, State#{mode => input}, Acc);
fold_input(<<_Byte, Rest/binary>>, #{mode := escape_bracket} = State, Acc) ->
    fold_input(Rest, State#{mode => input}, Acc);
fold_input(<<?CTRL_C, Rest/binary>>, State, Acc) ->
    fold_input(Rest, State#{line => <<>>}, [<<"^C", (?EOL)/binary, (?PROMPT)/binary>> | Acc]);
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

submit(Rest, #{line := Line} = State, Acc) ->
    Output = <<(?EOL)/binary, (run(Line))/binary, (?PROMPT)/binary>>,
    fold_input(Rest, State#{line => <<>>}, [Output | Acc]).

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
    [
        {<<"help">>, <<"this list">>},
        {<<"info">>, <<"AtomVM and application versions">>},
        {<<"firmware">>, <<"the running packbeam, its digest and slot">>},
        {<<"memory">>, <<"heap and process counts">>},
        {<<"partitions">>, <<"the flash partition table">>},
        {<<"net">>, <<"network address and signal">>},
        {<<"geo">>, <<"resolve this device's location over GeoIP">>},
        {<<"signature">>, <<"check the running firmware's signature">>},
        {<<"uptime">>, <<"how long since boot">>},
        {<<"reboot">>, <<"restart the device">>}
    ].

run(Line) ->
    case parse(Line) of
        empty -> <<>>;
        {Command, Args} -> execute(Command, Args)
    end.

%%-----------------------------------------------------------------------------
%% @doc Run one command line, saying whether it was a command at all.
%%
%% The console only prints, so it does not care. A script does: a line that is
%% not a command is a script that did not do what it says, and NervesHub should
%% hear that it failed rather than that it completed.
%% @end
%%-----------------------------------------------------------------------------
-spec run_command(binary()) -> {ok, binary()} | {error, binary()}.
run_command(Line) ->
    case parse(Line) of
        empty ->
            {ok, <<>>};
        {Command, Args} ->
            case lists:keymember(Command, 1, commands()) of
                true -> {ok, execute(Command, Args)};
                false -> {error, execute(Command, Args)}
            end
    end.

execute(<<"help">>, _Args) ->
    Rows = [
        <<"  ", (pad(Name, 12))/binary, Description/binary, (?EOL)/binary>>
     || {Name, Description} <- commands()
    ],
    iolist_to_binary([Rows]);
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
