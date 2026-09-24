%
% SPDX-License-Identifier: Apache-2.0 OR LGPL-2.1-or-later
%

%% @doc A flash and NVS that live in a process instead of on a chip.
%%
%% `nh_ota' reaches the device through a module name rather than a direct call,
%% so this stands in for `esp' and records what it was asked to do. Writes land
%% in a binary that a test can read back, which is what makes it possible to
%% assert that the bytes that went in are the bytes that came out.
%%
%% `fail/1' arms the next call of a kind to fail, which is the half of the
%% install path that matters and the half a real device will not do on demand.
-module(nh_ota_fake_esp).

-export([start/0, stop/0, written/0, erased/0, nvs/0, fail/1]).
-export([partition_write/3, partition_erase_range/3]).
-export([nvs_set_binary/3, nvs_get_binary/2, nvs_erase_key/2]).

-define(NAME, ?MODULE).

start() ->
    stop(),
    Pid = spawn(fun() -> loop(#{writes => [], erases => [], nvs => #{}, fail => none}) end),
    register(?NAME, Pid),
    ok.

stop() ->
    case whereis(?NAME) of
        undefined ->
            ok;
        Pid ->
            Pid ! stop,
            timer:sleep(1),
            ok
    end.

%% The slot as the writes left it: each one laid down at its offset, later ones
%% over earlier ones, as flash would hold them after a download that started
%% again from the beginning.
written() -> call(written).

erased() -> call(erased).

nvs() -> call(nvs).

%% `fail(write)' makes the next partition_write return `error'.
fail(What) -> call({fail, What}).

%% ------------------------------------------------------- the `esp' interface

partition_write(Slot, Offset, Data) -> call({write, Slot, Offset, Data}).

partition_erase_range(Slot, Offset, Size) -> call({erase, Slot, Offset, Size}).

nvs_set_binary(Namespace, Key, Value) -> call({nvs_set, Namespace, Key, Value}).

nvs_get_binary(Namespace, Key) -> call({nvs_get, Namespace, Key}).

nvs_erase_key(Namespace, Key) -> call({nvs_erase, Namespace, Key}).

%% ------------------------------------------------------------------ internals

call(Message) ->
    ?NAME ! {self(), Message},
    receive
        {?NAME, Reply} -> Reply
    after 1000 -> error(fake_esp_timeout)
    end.

loop(State) ->
    receive
        stop ->
            ok;
        {From, Message} ->
            {Reply, Next} = handle(Message, State),
            From ! {?NAME, Reply},
            loop(Next)
    end.

handle({fail, What}, State) ->
    {ok, State#{fail => What}};
handle({write, _Slot, _Offset, _Data}, #{fail := write} = State) ->
    {error, State#{fail => none}};
handle({write, Slot, Offset, Data}, #{writes := Writes} = State) ->
    {ok, State#{writes => Writes ++ [{Slot, Offset, Data}]}};
handle({erase, _Slot, _Offset, _Size}, #{fail := erase} = State) ->
    {error, State#{fail => none}};
handle({erase, Slot, Offset, Size}, #{erases := Erases} = State) ->
    {ok, State#{erases => Erases ++ [{Slot, Offset, Size}]}};
handle({nvs_set, _Ns, _Key, _Value}, #{fail := nvs_set} = State) ->
    {error, State#{fail => none}};
handle({nvs_set, Ns, Key, Value}, #{nvs := Nvs} = State) ->
    {ok, State#{nvs => Nvs#{{Ns, Key} => Value}}};
handle({nvs_get, Ns, Key}, #{nvs := Nvs} = State) ->
    {maps:get({Ns, Key}, Nvs, undefined), State};
handle({nvs_erase, _Ns, _Key}, #{fail := nvs_erase} = State) ->
    {error, State#{fail => none}};
handle({nvs_erase, Ns, Key}, #{nvs := Nvs} = State) ->
    {ok, State#{nvs => maps:remove({Ns, Key}, Nvs)}};
handle(written, #{writes := Writes} = State) ->
    {image(Writes), State};
handle(erased, #{erases := Erases} = State) ->
    {Erases, State};
handle(nvs, #{nvs := Nvs} = State) ->
    {Nvs, State}.

image(Writes) ->
    lists:foldl(
        fun({_Slot, Offset, Data}, Image) ->
            Padded =
                case Offset - byte_size(Image) of
                    Gap when Gap > 0 -> <<Image/binary, 0:(Gap * 8)>>;
                    _ -> Image
                end,
            Before = binary:part(Padded, 0, Offset),
            AfterStart = Offset + byte_size(Data),
            After =
                case byte_size(Padded) > AfterStart of
                    true -> binary:part(Padded, AfterStart, byte_size(Padded) - AfterStart);
                    false -> <<>>
                end,
            <<Before/binary, Data/binary, After/binary>>
        end,
        <<>>,
        Writes
    ).
