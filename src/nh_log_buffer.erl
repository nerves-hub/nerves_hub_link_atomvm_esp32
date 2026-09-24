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
%% @end
%%-----------------------------------------------------------------------------
-module(nh_log_buffer).

-export([new/1, add/2, take/2, size/1, dropped/1]).

-opaque buffer() :: #{
    lines := queue:queue(map()),
    count := non_neg_integer(),
    max := pos_integer(),
    dropped := non_neg_integer()
}.

-export_type([buffer/0]).

-spec new(pos_integer()) -> buffer().
new(Max) when is_integer(Max), Max > 0 ->
    #{lines => queue:new(), count => 0, max => Max, dropped => 0}.

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
take(N, #{dropped := Dropped} = Buffer) when Dropped > 0 ->
    case nh_ext_logs:dropped_line(Dropped) of
        {ok, Notice} ->
            {Lines, Rest} = take(N - 1, Buffer#{dropped => 0}),
            {[Notice | Lines], Rest};
        {error, no_clock} ->
            take(N, Buffer#{dropped => 0})
    end;
take(N, #{lines := Lines, count := Count} = Buffer) ->
    Taken = min(N, Count),
    {Front, Back} = queue:split(Taken, Lines),
    {queue:to_list(Front), Buffer#{lines => Back, count => Count - Taken}}.

%%-----------------------------------------------------------------------------
%% @doc Lines waiting, not counting a pending drop notice.
%% @end
%%-----------------------------------------------------------------------------
-spec size(buffer()) -> non_neg_integer().
size(#{count := Count}) -> Count.

-spec dropped(buffer()) -> non_neg_integer().
dropped(#{dropped := Dropped}) -> Dropped.
