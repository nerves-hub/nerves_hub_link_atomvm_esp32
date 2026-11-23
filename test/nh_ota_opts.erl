%
% SPDX-License-Identifier: Apache-2.0 OR LGPL-2.1-or-later
%

%% An updater that tells the process registered as `nh_ota_opts_probe' what
%% options the agent gave it, and then finishes.
-module(nh_ota_opts).

-export([start_update/3]).

start_update(_Payload, Owner, Opts) ->
    spawn(fun() ->
        nh_ota_opts_probe ! {opts, Opts},
        Owner ! {nh_ota, self(), {ok, <<"alt.avm">>}}
    end).
