%
% SPDX-License-Identifier: Apache-2.0 OR LGPL-2.1-or-later
%

%% An updater that goes quiet for longer than the stall limit as a whole, but
%% resumes in between, and then finishes.
-module(nh_ota_resumed).

-export([start_update/3]).

start_update(_Payload, Owner, _Opts) ->
    spawn(fun() ->
        Owner ! {nh_ota, self(), {progress, 10}},
        timer:sleep(120),
        Owner ! {nh_ota, self(), {resumed, 4096}},
        timer:sleep(120),
        Owner ! {nh_ota, self(), {ok, <<"alt.avm">>}}
    end).
