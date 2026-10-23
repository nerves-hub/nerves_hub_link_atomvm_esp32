%
% SPDX-License-Identifier: Apache-2.0 OR LGPL-2.1-or-later
%

%%-----------------------------------------------------------------------------
%% @doc Log lines waiting to be sent, oldest first, with a ceiling.
%%
%% Batched logging holds lines between sends, and holds them across a
%% disconnect, which is exactly when a device has the most to say and nowhere
%% to say it. So the buffer has a ceiling and drops the oldest line to make
%% room: the lines leading up to now are the ones worth keeping.
%%
%% A drop is not silent. The next batch taken starts with a line saying how many
%% went, so a gap in the log reads as a gap rather than as a quiet device.
%%
%% Error reports are held the same way (`new/2'), with a report of their own
%% saying how many went.
%% @end
%%-----------------------------------------------------------------------------
-module(nh_log_buffer).

-export([new/1, new/2, add/2, take/2, take/3, size/1, dropped/1]).

-type notice() :: fun((pos_integer()) -> {ok, map()} | {error, no_clock}).

-opaque buffer() :: #{
    lines := queue:queue(map()),
    count := non_neg_integer(),
    max := pos_integer(),
    dropped := non_neg_integer(),
    notice := notice()
}.

-export_type([buffer/0]).

%%-----------------------------------------------------------------------------
%% @equiv new(Max, fun nh_ext_logs:dropped_line/1)
%% @end
%%-----------------------------------------------------------------------------
-spec new(pos_integer()) -> buffer().
new(Max) -> new(Max, fun nh_ext_logs:dropped_line/1).

%%-----------------------------------------------------------------------------
%% @doc A buffer of at most `Max' entries. `Notice' builds the entry saying how
%% many were dropped, or `{error, no_clock}' when there is no time to stamp it.
%% @end
%%-----------------------------------------------------------------------------
-spec new(pos_integer(), notice()) -> buffer().
new(Max, Notice) when is_integer(Max), Max > 0, is_function(Notice, 1) ->
    #{lines => queue:new(), count => 0, max => Max, dropped => 0, notice => Notice}.

%%-----------------------------------------------------------------------------
%% @doc Add a line, dropping the oldest when full.
%% @end
%%-----------------------------------------------------------------------------
-spec add(map(), buffer()) -> buffer().
add(Line, #{lines := Lines, count := Count, max := Max} = Buffer) when Count < Max ->
    Buffer#{lines => queue:in(Line, Lines), count => Count + 1};
add(Line, #{lines := Lines, dropped := Dropped} = Buffer) ->
    {_Oldest, Rest} = queue:out(Lines),
    Buffer#{lines => queue:in(Line, Rest), dropped => Dropped + 1}.

%%-----------------------------------------------------------------------------
%% @doc Take up to `N' lines, oldest first.
%%
%% When lines were dropped, the first one taken says so, and counts towards
%% `N'. It is stamped now: it describes the moment the gap is reported, and
%% the lines it replaced carried times of their own that are gone with them.
%% @end
%%-----------------------------------------------------------------------------
-spec take(pos_integer(), buffer()) -> {[map()], buffer()}.
take(N, Buffer) -> take(N, infinity, Buffer).

%%-----------------------------------------------------------------------------
%% @doc Take up to `N' lines, oldest first, stopping before their messages
%% add up to more than `MaxBytes'.
%%
%% The first line is always taken, however long, so a single big line cannot
%% hold up the buffer forever. The drop notice counts towards `N' as in
%% `take/2', and not towards `MaxBytes': it is short, and it goes first.
%% @end
%%-----------------------------------------------------------------------------
-spec take(pos_integer(), pos_integer() | infinity, buffer()) -> {[map()], buffer()}.
take(N, MaxBytes, #{dropped := Dropped, notice := MakeNotice} = Buffer) when Dropped > 0 ->
    case MakeNotice(Dropped) of
        {ok, Notice} ->
            {Lines, Rest} = take(N - 1, MaxBytes, Buffer#{dropped => 0}),
            {[Notice | Lines], Rest};
        {error, no_clock} ->
            take(N, MaxBytes, Buffer#{dropped => 0})
    end;
take(N, MaxBytes, #{lines := Lines, count := Count} = Buffer) ->
    {Taken, Back} = take_lines(min(N, Count), MaxBytes, Lines, []),
    {Taken, Buffer#{lines => Back, count => Count - length(Taken)}}.

%% Up to `N' lines from the front of `Lines', in order, and the queue left.
-spec take_lines(non_neg_integer(), pos_integer() | infinity, queue:queue(map()), [map()]) ->
    {[map()], queue:queue(map())}.
take_lines(0, _MaxBytes, Lines, Acc) ->
    {lists:reverse(Acc), Lines};
take_lines(N, MaxBytes, Lines, Acc) ->
    {value, Line} = queue:peek(Lines),
    Bytes = message_bytes(Line),
    case Acc =:= [] orelse Bytes =< MaxBytes of
        true -> take_lines(N - 1, budget(MaxBytes, Bytes), queue:drop(Lines), [Line | Acc]);
        false -> {lists:reverse(Acc), Lines}
    end.

budget(infinity, _Bytes) -> infinity;
budget(MaxBytes, Bytes) -> max(MaxBytes - Bytes, 0).

message_bytes(Line) -> byte_size(maps:get(<<"message">>, Line, <<>>)).

%%-----------------------------------------------------------------------------
%% @doc Lines waiting, not counting a pending drop notice.
%% @end
%%-----------------------------------------------------------------------------
-spec size(buffer()) -> non_neg_integer().
size(#{count := Count}) -> Count.

-spec dropped(buffer()) -> non_neg_integer().
dropped(#{dropped := Dropped}) -> Dropped.
