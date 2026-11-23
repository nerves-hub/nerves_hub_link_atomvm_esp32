%
% SPDX-License-Identifier: Apache-2.0 OR LGPL-2.1-or-later
%

%% An updater that says nothing for 400 ms, as nh_ota does while it waits to
%% reconnect after a connection that brought nothing, and then finishes.
-module(nh_ota_quiet).

-export([start_update/3]).

start_update(_Payload, Owner, _Opts) ->
    spawn(fun() ->
        timer:sleep(400),
        Owner ! {nh_ota, self(), {ok, <<"alt.avm">>}}
    end).
