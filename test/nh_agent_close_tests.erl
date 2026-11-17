%
% SPDX-License-Identifier: Apache-2.0 OR LGPL-2.1-or-later
%
-module(nh_agent_close_tests).

-include_lib("eunit/include/eunit.hrl").

%% A transport whose handle, like an AtomVM port, outlives `close/1' a little:
%% it is a process that exits 300 ms after being told to close. The download
%% must not start until it has gone -- on a device, until its memory is back.
-export([open/1, send_text/2, close/1]).

open(_Config) ->
    Handle = spawn(fun handle/0),
    ?MODULE ! {opened, Handle},
    {ok, Handle}.

handle() ->
    receive
        close -> timer:sleep(300)
    end.

send_text(_Handle, _Frame) ->
    ok.

close(Handle) ->
    Handle ! close,
    ok.

the_download_waits_for_the_closed_transport_test() ->
    case erlang:process_info(self(), registered_name) of
        {registered_name, Name} -> unregister(Name);
        _ -> ok
    end,
    register(?MODULE, self()),

    {ok, Agent} = nh_agent:start(#{
        url => "wss://example.com/socket/websocket",
        identifier => <<"dev-1">>,
        transport => ?MODULE,
        keep_open_above => never,
        handler => self(),
        metadata => nh_metadata:describe(
            #{name => <<"my_app">>, vsn => <<"1.2.3">>, description => <<"a test app">>},
            binary:copy(<<"ab">>, 32)
        )
    }),
    Handle =
        receive
            {opened, H} -> H
        after 1000 -> erlang:error(never_opened)
        end,

    Agent ! {websocket, Handle, connected},
    Update = json:encode([
        null,
        null,
        <<"device">>,
        <<"update">>,
        #{
            <<"update_available">> => true,
            <<"firmware_url">> => <<"http://example.com/fw.avm">>,
            <<"size">> => 1024,
            <<"checksum">> => <<"abc">>
        }
    ]),
    Agent ! {websocket, Handle, {text, iolist_to_binary(Update)}},

    receive
        {nerves_hub, {update_started, _Pid}} ->
            ?assertNot(erlang:is_process_alive(Handle))
    after 3000 -> erlang:error(never_started)
    end,

    nh_agent:stop(Agent).
