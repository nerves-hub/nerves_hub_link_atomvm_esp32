%
% SPDX-License-Identifier: Apache-2.0 OR LGPL-2.1-or-later
%

%%-----------------------------------------------------------------------------
%% @doc How long to wait before trying again.
%%
%% Doubling from a floor to a ceiling, with up to half as much again added at
%% random. The randomness is the point as much as the doubling: a fleet that
%% lost NervesHub at the same moment would otherwise come back at the same
%% moment, every time, and keep knocking it over.
%%
%% ```
%% attempt 0   Min .. 1.5 * Min
%% attempt 1   2 * Min .. 3 * Min
%% ...
%% attempt N   Max .. 1.5 * Max     once 2^N * Min passes Max
%% '''
%% @end
%%-----------------------------------------------------------------------------
-module(nh_backoff).

-export([delay/3, delay/4]).

%%-----------------------------------------------------------------------------
%% @doc The delay before attempt `Attempt', counting from 0.
%% @end
%%-----------------------------------------------------------------------------
-spec delay(non_neg_integer(), pos_integer(), pos_integer()) -> pos_integer().
delay(Attempt, Min, Max) ->
    delay(Attempt, Min, Max, fraction()).

%%-----------------------------------------------------------------------------
%% @doc As `delay/3', with the random fraction supplied, so it can be tested.
%% @end
%%-----------------------------------------------------------------------------
-spec delay(non_neg_integer(), pos_integer(), pos_integer(), float()) -> pos_integer().
delay(Attempt, Min, Max, Fraction) ->
    Base = min(Max, Min bsl min(Attempt, 16)),
    Base + trunc(Base * Fraction / 2).

%% Not `rand': AtomVM does not have it. `crypto' it does, and a few bytes of it
%% are plenty for spreading reconnects out.
fraction() ->
    <<N:16>> = crypto:strong_rand_bytes(2),
    N / 65536.
