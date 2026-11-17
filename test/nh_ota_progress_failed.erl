%
% SPDX-License-Identifier: Apache-2.0 OR LGPL-2.1-or-later
%

%% An updater that gets part of the way, says so, and then fails the way a
%% host without flash does.
-module(nh_ota_progress_failed).

-export([start_update/3]).

start_update(_Payload, Owner, _Opts) ->
    spawn(fun() ->
        Owner ! {nh_ota, self(), {progress, 42}},
        timer:sleep(50),
        Owner ! {nh_ota, self(), {error, no_flash_access}}
    end).
