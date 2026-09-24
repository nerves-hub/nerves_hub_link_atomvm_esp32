%
% SPDX-License-Identifier: Apache-2.0 OR LGPL-2.1-or-later
%
-module(nh_log_buffer_tests).

-include_lib("eunit/include/eunit.hrl").

line(N) -> #{<<"message">> => integer_to_binary(N)}.

filled(Max, Count) ->
    lists:foldl(
        fun(N, B) -> nh_log_buffer:add(line(N), B) end, nh_log_buffer:new(Max), lists:seq(1, Count)
    ).

messages(Lines) -> [maps:get(<<"message">>, L) || L <- Lines].

takes_oldest_first_test() ->
    {Lines, Rest} = nh_log_buffer:take(2, filled(10, 3)),
    ?assertEqual([<<"1">>, <<"2">>], messages(Lines)),
    ?assertEqual(1, nh_log_buffer:size(Rest)).

taking_more_than_there_is_takes_it_all_test() ->
    {Lines, Rest} = nh_log_buffer:take(100, filled(10, 3)),
    ?assertEqual(3, length(Lines)),
    ?assertEqual(0, nh_log_buffer:size(Rest)).

%% The lines leading up to now are the ones worth keeping.
full_drops_the_oldest_test() ->
    Buffer = filled(3, 5),
    ?assertEqual(3, nh_log_buffer:size(Buffer)),
    ?assertEqual(2, nh_log_buffer:dropped(Buffer)),

    {[Notice | Lines], Rest} = nh_log_buffer:take(10, Buffer),
    ?assertEqual([<<"3">>, <<"4">>, <<"5">>], messages(Lines)),
    ?assertMatch({_, _}, binary:match(maps:get(<<"message">>, Notice), <<"dropped 2">>)),
    ?assertEqual(<<"warning">>, maps:get(<<"level">>, Notice)),
    ?assertEqual(0, nh_log_buffer:dropped(Rest)).

%% The notice counts towards the batch, so a batch never grows past its limit.
the_notice_counts_towards_the_batch_test() ->
    {Lines, Rest} = nh_log_buffer:take(2, filled(3, 5)),
    ?assertEqual(2, length(Lines)),
    ?assertEqual(2, nh_log_buffer:size(Rest)).
