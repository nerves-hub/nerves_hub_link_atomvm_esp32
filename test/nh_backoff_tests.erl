%
% SPDX-License-Identifier: Apache-2.0 OR LGPL-2.1-or-later
%
-module(nh_backoff_tests).

-include_lib("eunit/include/eunit.hrl").

doubles_from_the_floor_test() ->
    ?assertEqual(1000, nh_backoff:delay(0, 1000, 60000, 0.0)),
    ?assertEqual(2000, nh_backoff:delay(1, 1000, 60000, 0.0)),
    ?assertEqual(4000, nh_backoff:delay(2, 1000, 60000, 0.0)).

stops_at_the_ceiling_test() ->
    ?assertEqual(60000, nh_backoff:delay(10, 1000, 60000, 0.0)),
    %% and a count that would overflow a shift does not.
    ?assertEqual(60000, nh_backoff:delay(1000, 1000, 60000, 0.0)).

adds_up_to_half_again_test() ->
    ?assertEqual(1500, nh_backoff:delay(0, 1000, 60000, 1.0)),
    ?assertEqual(90000, nh_backoff:delay(10, 1000, 60000, 1.0)).

the_random_part_stays_in_range_test() ->
    [
        ?assert(D >= 4000 andalso D =< 6000)
     || D <- [nh_backoff:delay(2, 1000, 60000) || _ <- lists:seq(1, 50)]
    ].
