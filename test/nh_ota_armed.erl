%
% SPDX-License-Identifier: Apache-2.0 OR LGPL-2.1-or-later
%

%% An updater that arms the other slot as nh_ota does, in the fake esp's NVS,
%% and finishes: the device now boots it next, but still runs what it had.
-module(nh_ota_armed).

-export([start_update/3]).

start_update(_Payload, Owner, _Opts) ->
    spawn(fun() ->
        ok = nh_ota_fake_esp:nvs_set_binary(nerves_hub, previous_slot, <<"main.avm">>),
        ok = nh_ota_fake_esp:nvs_set_binary(nerves_hub, pending_slot, <<"alt.avm">>),
        Owner ! {nh_ota, self(), {ok, <<"alt.avm">>}}
    end).
