%
% SPDX-License-Identifier: Apache-2.0 OR LGPL-2.1-or-later
%

%% An updater whose download starts three times, as a resumed one does, and
%% then finishes.
-module(nh_ota_restarted).

-export([start_update/3]).

start_update(_Payload, Owner, _Opts) ->
    spawn(fun() ->
        [Owner ! {nh_ota, self(), started} || _ <- [1, 2, 3]],
        timer:sleep(50),
        Owner ! {nh_ota, self(), {ok, <<"alt.avm">>}}
    end).
