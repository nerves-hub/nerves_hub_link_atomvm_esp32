%
% SPDX-License-Identifier: Apache-2.0 OR LGPL-2.1-or-later
%

%% An updater that has started and never gets anywhere: a download in
%% progress, for as long as a test needs one.
-module(nh_ota_waiting).

-export([start_update/3]).

start_update(_Payload, _Owner, _Opts) ->
    spawn(fun() ->
        receive
        after 5000 -> ok
        end
    end).
