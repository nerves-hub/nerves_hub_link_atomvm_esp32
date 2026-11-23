%
% SPDX-License-Identifier: Apache-2.0 OR LGPL-2.1-or-later
%

%% An updater that fails at once for a firmware URL ending in `bad.avm', and
%% otherwise keeps downloading for a while.
-module(nh_ota_bad_then_slow).

-export([start_update/3]).

start_update(#{<<"firmware_url">> := Url}, Owner, _Opts) ->
    Bad = binary:longest_common_suffix([Url, <<"bad.avm">>]) =:= 7,
    spawn(fun() ->
        case Bad of
            true -> Owner ! {nh_ota, self(), {error, no_flash_access}};
            false -> timer:sleep(5000)
        end
    end).
