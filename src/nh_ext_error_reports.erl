%
% SPDX-License-Identifier: Apache-2.0 OR LGPL-2.1-or-later
%

%%-----------------------------------------------------------------------------
%% @doc The error_reports extension: crashes as structured reports.
%%
%% A crash already reaches NervesHub as a log line, but a log line is text,
%% kept for three days, and two of the same bug differ by a pid. A report has a
%% kind, a reason and frames, so the platform groups occurrences of one bug into
%% one issue and keeps them for a month.
%%
%% ```
%% device -> server   error_reports:report  {"reports": [{..}, ..]}
%% '''
%%
%% Nothing goes the other way: the platform never asks and never acknowledges.
%% NervesHub takes at most 25 reports a message and one message a second, with a
%% burst of five, so reports are batched (see `nh_agent').
%%
%% == Where reports come from ==
%%
%% `from_log/1' recognises the crash report `proc_lib' logs when a process
%% exits abnormally. On AtomVM it is a format string and its arguments rather
%% than a `{report, _}', and the arguments are what this reads: the class,
%% reason and stacktrace as terms, not as text to be parsed back. Anything else
%% logged is not a report. `manual/3' builds one for an application that caught
%% an error and wants it seen anyway.
%%
%% == Context ==
%%
%% Free heap, largest free block and the lowest free heap since boot, read when
%% the report is built: what a device without PSRAM has to say about itself at
%% the moment something broke.
%%
%% This module has no side effects beyond reading the clock and those counters;
%% `nh_logger' and `nerves_hub_link' build reports, `nh_agent' sends them.
%% @end
%%-----------------------------------------------------------------------------
-module(nh_ext_error_reports).

-export([event/0, batch/1, max_batch/0, from_log/1, manual/3, dropped/1]).

%% NervesHub drops anything past this in one message.
-define(MAX_BATCH, 25).

%% NervesHub's caps, applied here as well so a report is never built bigger than
%% the platform would keep: on a device the heap is the scarcer of the two.
-define(MAX_REASON_BYTES, 2048).
-define(MAX_MESSAGE_BYTES, 8192).
-define(MAX_FRAMES, 30).

-define(CRASH_REPORT, "=CRASH REPORT====").

%%-----------------------------------------------------------------------------
%% @doc The scoped event reports are sent as.
%% @end
%%-----------------------------------------------------------------------------
-spec event() -> binary().
event() -> <<"error_reports:report">>.

%%-----------------------------------------------------------------------------
%% @doc The payload for a batch of reports.
%% @end
%%-----------------------------------------------------------------------------
-spec batch([map()]) -> map().
batch(Reports) -> #{<<"reports">> => Reports}.

%%-----------------------------------------------------------------------------
%% @doc The most reports one message may carry.
%% @end
%%-----------------------------------------------------------------------------
-spec max_batch() -> pos_integer().
max_batch() -> ?MAX_BATCH.

%%-----------------------------------------------------------------------------
%% @doc A report for a `logger' event, or `ignore' when it is not a crash.
%%
%% `Event' is what `logger' hands a handler. Only `proc_lib''s crash report is
%% one; its timestamp is the event's, so a report held through an outage still
%% says when the crash happened.
%% @end
%%-----------------------------------------------------------------------------
-spec from_log(map()) -> {ok, map()} | ignore.
%% A string-prefix pattern rather than `lists:prefix/2', which AtomVM's
%% `lists' does not have: an `undef' here would be raised in whichever process
%% was logging, just as it was reporting a crash.
from_log(#{msg := {?CRASH_REPORT ++ _ = Format, Args}} = Event) when is_list(Args) ->
    crash_report(Format, Args, maps:get(timestamp, Event, undefined));
from_log(_Event) ->
    ignore.

%% The arguments `proc_lib:crash_report/4' passes, in its order.
crash_report(Format, Args, Micros) ->
    case Args of
        [M, F, A, Pid, {Class, Reason}, _Ancestors, _Queue, _Links, _Heap, _Stack, Stacktrace] ->
            Message = nh_logger:message({Format, Args}),
            Context = #{
                <<"initial_call">> => text(io_lib:format("~p:~p/~p", [M, F, A])),
                <<"pid">> => text(io_lib:format("~p", [Pid]))
            },
            report(Micros, #{
                <<"kind">> => text(io_lib:format("~p", [Class])),
                <<"reason">> => one_line(Reason),
                <<"message">> => cap(Message, ?MAX_MESSAGE_BYTES),
                <<"source">> => <<"logger">>,
                <<"frames">> => frames(Stacktrace),
                <<"context">> => Context
            });
        _ ->
            ignore
    end.

%%-----------------------------------------------------------------------------
%% @doc A report an application makes on purpose.
%%
%% `Kind' and `Reason' are any terms, rendered as text. `Opts' may give
%% `stacktrace', `context' (a map of anything, rendered as text) and
%% `fingerprint', to group by something the stacktrace does not show.
%% @end
%%-----------------------------------------------------------------------------
-spec manual(term(), term(), map()) -> {ok, map()} | {error, no_clock}.
manual(Kind, Reason, Opts) ->
    Context = maps:from_list([
        {text(Key), text(Value)}
     || {Key, Value} <- maps:to_list(maps:get(context, Opts, #{}))
    ]),
    Base = #{
        <<"kind">> => text(Kind),
        <<"reason">> => one_line(Reason),
        <<"source">> => <<"manual">>,
        <<"frames">> => frames(maps:get(stacktrace, Opts, [])),
        <<"context">> => Context
    },
    Report =
        case maps:get(fingerprint, Opts, undefined) of
            undefined -> Base;
            Fingerprint -> Base#{<<"fingerprint">> => text(Fingerprint)}
        end,
    case report(micros(), Report) of
        ignore -> {error, no_clock};
        Ok -> Ok
    end.

%%-----------------------------------------------------------------------------
%% @doc A report saying that `Count' reports were dropped to make room.
%%
%% Its own kind, so it groups into one issue of its own rather than into the
%% crash that caused the drops.
%% @end
%%-----------------------------------------------------------------------------
-spec dropped(pos_integer()) -> {ok, map()} | {error, no_clock}.
dropped(Count) ->
    manual(dropped, iolist_to_binary(["dropped ", integer_to_list(Count), " reports"]), #{
        fingerprint => <<"nerves_hub_link:dropped_reports">>
    }).

%% Stamped as the logging extension stamps a line, `meta.time' in microseconds,
%% which NervesHub accepts in place of an ISO 8601 `timestamp'. A device has the
%% integer already and would otherwise have to format a date.
report(Micros, Report) when is_integer(Micros) ->
    case nh_ext_logs:line_at(<<"error">>, <<>>, #{}, Micros) of
        {ok, #{<<"meta">> := Meta}} ->
            Context = maps:merge(vitals(), maps:get(<<"context">>, Report, #{})),
            {ok, Report#{<<"meta">> => Meta, <<"context">> => Context}};
        {error, no_clock} ->
            ignore
    end;
report(_Micros, _Report) ->
    ignore.

micros() ->
    try
        erlang:system_time(microsecond)
    catch
        _:_ -> undefined
    end.

%% Innermost first, as a stacktrace already is. `file' and `line' come from the
%% location list when the module was compiled with them.
frames(Stacktrace) when is_list(Stacktrace) ->
    [frame(Frame) || Frame <- lists:sublist(Stacktrace, ?MAX_FRAMES)];
frames(_Stacktrace) ->
    [].

frame({M, F, A, Location}) when is_atom(M), is_atom(F) ->
    Arity =
        case A of
            Args when is_list(Args) -> length(Args);
            N -> N
        end,
    Base = #{
        <<"module">> => atom_to_binary(M, utf8),
        <<"function">> => text(io_lib:format("~p/~p", [F, Arity]))
    },
    location(Base, Location);
frame(Other) ->
    #{<<"function">> => text(io_lib:format("~p", [Other]))}.

location(Frame, Location) when is_list(Location) ->
    lists:foldl(
        fun
            ({file, File}, Acc) -> Acc#{<<"file">> => text(File)};
            ({line, Line}, Acc) when is_integer(Line) -> Acc#{<<"line">> => Line};
            (_Other, Acc) -> Acc
        end,
        Frame,
        Location
    );
location(Frame, _Location) ->
    Frame.

vitals() ->
    maps:from_list([
        {Key, integer_to_binary(Value)}
     || {Key, Info} <- [
            {<<"free_heap_bytes">>, esp32_free_heap_size},
            {<<"largest_free_block_bytes">>, esp32_largest_free_block},
            {<<"minimum_free_heap_bytes">>, esp32_minimum_free_size}
        ],
        is_integer(Value = info(Info))
    ]).

info(Key) ->
    try
        erlang:system_info(Key)
    catch
        _:_ -> undefined
    end.

%% The reason is what the platform groups by, and it wants one line: a reason
%% printed with `~p' breaks lines of its own past 80 columns.
%% Text given as the reason is the reason as is; anything else is printed.
one_line(Reason) ->
    Text =
        case Reason of
            Binary when is_binary(Binary) -> Binary;
            _ -> text(io_lib:format("~p", [Reason]))
        end,
    cap(binary:replace(Text, <<"\n">>, <<" ">>, [global]), ?MAX_REASON_BYTES).

text(Value) when is_binary(Value) -> Value;
text(Value) when is_atom(Value) -> atom_to_binary(Value, utf8);
text(Value) when is_integer(Value) -> integer_to_binary(Value);
text(Value) when is_list(Value) -> nh_logger:message({string, Value});
text(Value) -> text(io_lib:format("~p", [Value])).

%% Short of the platform's cap by the `...' a cut adds.
cap(Binary, Max) -> nh_ext_logs:truncate(Binary, Max - 3).
