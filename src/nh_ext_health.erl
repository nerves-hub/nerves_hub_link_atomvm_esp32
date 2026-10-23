%
% SPDX-License-Identifier: Apache-2.0 OR LGPL-2.1-or-later
%

%%-----------------------------------------------------------------------------
%% @doc The health extension's report.
%%
%% NervesHub asks with `health:check' and the device answers with
%% `health:report', carrying the shape `nerves_hub_link' sends:
%%
%% ```
%% #{timestamp, metadata, alarms, metrics, checks, connectivity}
%% '''
%%
%% == About mem_used_percent ==
%%
%% NervesHub calculates a device's status from three metrics it knows by name:
%% `cpu_usage_percent', `mem_used_percent' and `disk_used_percentage'. None of
%% them can be answered honestly here.
%%
%% AtomVM reports free heap, the largest free block and the low-water mark since
%% boot, but not the heap's total size — so any percentage would be measured
%% against a number this library made up, and a device would show green or red
%% on the strength of it. The raw byte counts are reported instead, and a device
%% shows status `unknown' until NervesHub is given a metric it recognises.
%%
%% Those byte counts are also the numbers worth watching on an ESP32.
%% `minimum_free_heap_bytes' is the one that finds leaks: free heap recovers
%% after a garbage collection, the low-water mark does not.
%% @end
%%-----------------------------------------------------------------------------
-module(nh_ext_health).

-export([report/0, report/1, metrics/0, metadata/0, timestamp/0]).

%%-----------------------------------------------------------------------------
%% @doc The full report NervesHub stores against the device.
%% @end
%%-----------------------------------------------------------------------------
-spec report() -> map().
report() ->
    report(#{}).

%%-----------------------------------------------------------------------------
%% @doc The report, carrying the application's current alarms.
%%
%% `#{Name => Description}', both binaries: the complete set raised right now.
%% NervesHub diffs it against what it has stored, so an alarm missing from a
%% report is an alarm cleared.
%%
%% `undefined' leaves the key out, which NervesHub reads as "nothing to say":
%% the report of a device sending its alarms through the `alarms' extension.
%% @end
%%-----------------------------------------------------------------------------
-spec report(map() | undefined) -> map().
report(Alarms) ->
    Report = #{
        <<"timestamp">> => timestamp(),
        <<"metadata">> => metadata(),
        <<"metrics">> => metrics(),
        <<"checks">> => #{}
    },
    case Alarms of
        undefined -> Report;
        _ -> Report#{<<"alarms">> => Alarms}
    end.

%%-----------------------------------------------------------------------------
%% @doc Numbers that change, and are worth a graph.
%% @end
%%-----------------------------------------------------------------------------
-spec metrics() -> map().
metrics() ->
    with_known([
        {<<"free_heap_bytes">>, info(esp32_free_heap_size)},
        {<<"largest_free_block_bytes">>, info(esp32_largest_free_block)},
        {<<"minimum_free_heap_bytes">>, info(esp32_minimum_free_size)},
        {<<"process_count">>, info(process_count)},
        {<<"atom_count">>, info(atom_count)},
        {<<"port_count">>, info(port_count)}
    ]).

%%-----------------------------------------------------------------------------
%% @doc Strings that describe the device, and rarely change.
%%
%% Values are strings: NervesHub stores metadata as a string map, and a number
%% sent here comes back as one anyway.
%% @end
%%-----------------------------------------------------------------------------
-spec metadata() -> map().
metadata() ->
    Base = [
        {<<"atomvm_version">>, nh_metadata:atomvm_version()},
        {<<"system_architecture">>, text(info(system_architecture))},
        {<<"word_size">>, text(info(wordsize))},
        {<<"schedulers">>, text(info(schedulers))},
        {<<"boot_partition">>, safe(fun() -> nh_flash:boot_partition() end)}
    ],

    with_known(Base ++ chip_metadata()).

chip_metadata() ->
    case safe(fun() -> erlang:system_info(esp32_chip_info) end) of
        Info when is_map(Info) ->
            [
                {<<"chip_model">>, text(maps:get(model, Info, undefined))},
                {<<"chip_cores">>, text(maps:get(cores, Info, undefined))},
                {<<"chip_revision">>, text(maps:get(revision, Info, undefined))}
            ];
        _ ->
            []
    end.

%%-----------------------------------------------------------------------------
%% @doc When the report was taken, as RFC 3339.
%%
%% `undefined' before the clock is set, rather than 1970: a report stamped at
%% the epoch is worse than one with no stamp, because it looks like data.
%% @end
%%-----------------------------------------------------------------------------
-spec timestamp() -> binary() | undefined.
timestamp() ->
    case safe(fun() -> erlang:system_time(second) end) of
        Seconds when is_integer(Seconds), Seconds > 1700000000 ->
            case safe(fun() -> calendar:system_time_to_universal_time(Seconds, second) end) of
                {{Y, M, D}, {H, Mi, S}} ->
                    iolist_to_binary([
                        pad4(Y),
                        $-,
                        pad2(M),
                        $-,
                        pad2(D),
                        $T,
                        pad2(H),
                        $:,
                        pad2(Mi),
                        $:,
                        pad2(S),
                        $Z
                    ]);
                _ ->
                    undefined
            end;
        _ ->
            undefined
    end.

%% ------------------------------------------------------------------- helpers

with_known(Pairs) ->
    maps:from_list([{Key, Value} || {Key, Value} <- Pairs, Value =/= undefined]).

info(Key) -> safe(fun() -> erlang:system_info(Key) end).

text(undefined) -> undefined;
text(Bin) when is_binary(Bin) -> Bin;
text(N) when is_integer(N) -> integer_to_binary(N);
text(A) when is_atom(A) -> atom_to_binary(A, utf8);
text(L) when is_list(L) -> safe(fun() -> list_to_binary(L) end);
text(_) -> undefined.

pad2(N) when N < 10 -> [$0, integer_to_binary(N)];
pad2(N) -> integer_to_binary(N).

pad4(N) when N < 10 -> [<<"000">>, integer_to_binary(N)];
pad4(N) when N < 100 -> [<<"00">>, integer_to_binary(N)];
pad4(N) when N < 1000 -> [<<"0">>, integer_to_binary(N)];
pad4(N) -> integer_to_binary(N).

%% A report is what you get when something is already wrong, so no single value
%% being unavailable may stop the rest being sent.
safe(Fun) ->
    try Fun() of
        Result -> Result
    catch
        _:_ -> undefined
    end.
