%
% SPDX-License-Identifier: Apache-2.0 OR LGPL-2.1-or-later
%
-module(nh_agent_tests).

-include_lib("eunit/include/eunit.hrl").

%% A transport the test drives by hand: it records what the agent sends and lets
%% the test deliver socket events. Registered under its own name so the module
%% callbacks can reach it without the agent knowing it exists.
-export([open/1, send_text/2, close/1]).

open(Config) ->
    ?MODULE ! {opened, self(), Config},
    {ok, fake_handle}.

send_text(fake_handle, Frame) ->
    ?MODULE ! {sent, Frame},
    ok.

close(fake_handle) ->
    ?MODULE ! closed,
    ok.

setup() ->
    %% eunit runs every test in the same process, and a process may hold only one
    %% registered name — so drop whichever name the previous test module left on
    %% it before claiming this one. Its leftover messages go too, or this test
    %% reads them as its own.
    case erlang:process_info(self(), registered_name) of
        {registered_name, Name} -> unregister(Name);
        _ -> ok
    end,
    register(?MODULE, self()),
    flush(),
    ok.

flush() ->
    receive
        _ -> flush()
    after 0 -> ok
    end.

config(Extra) ->
    maps:merge(
        #{
            url => "wss://example.com/socket/websocket",
            identifier => <<"dev-1">>,
            transport => ?MODULE,
            handler => self(),
            metadata => nh_metadata:describe(
                #{name => <<"my_app">>, vsn => <<"1.2.3">>, description => <<"a test app">>},
                binary:copy(<<"ab">>, 32)
            )
        },
        Extra
    ).

%% The agent must not join until the socket says it is up.
joins_only_once_connected_test() ->
    setup(),
    {ok, Agent} = nh_agent:start(config(#{})),

    receive
        {opened, AgentPid, _} -> ?assertEqual(Agent, AgentPid)
    after 1000 -> ?assert(false)
    end,

    ?assertEqual(nothing_sent, next_sent(200)),

    Agent ! {websocket, fake_handle, connected},
    Frame = next_sent(1000),
    [_JoinRef, _Ref, Topic, Event, Payload] = json:decode(Frame),
    ?assertEqual(<<"device">>, Topic),
    ?assertEqual(<<"phx_join">>, Event),
    ?assertEqual(<<"my_app">>, maps:get(<<"atomvm_app_name">>, Payload)),

    nh_agent:stop(Agent).

%% The whole reason the agent watches for `connected' rather than joining once:
%% a Phoenix channel does not survive a socket reconnect.
rejoins_on_every_connection_test() ->
    setup(),
    {ok, Agent} = nh_agent:start(config(#{reconnect_backoff => {10, 20}})),
    _ = next_opened(),

    Agent ! {websocket, fake_handle, connected},
    First = json:decode(next_sent(1000)),

    Agent ! {websocket, fake_handle, {closed, disconnected}},
    ?assertEqual(closed, next_closed()),
    _ = next_opened(),
    Agent ! {websocket, fake_handle, connected},
    Second = json:decode(next_sent(1000)),

    ?assertEqual(<<"phx_join">>, lists:nth(4, First)),
    ?assertEqual(<<"phx_join">>, lists:nth(4, Second)),
    %% A new join reference, so a late reply to the old join cannot be mistaken
    %% for this one.
    ?assertNotEqual(lists:nth(1, First), lists:nth(1, Second)),

    nh_agent:stop(Agent).

sends_heartbeats_test() ->
    setup(),
    {ok, Agent} = nh_agent:start(config(#{heartbeat_ms => 100})),
    _ = next_opened(),

    Agent ! {websocket, fake_handle, connected},
    _Join = next_sent(1000),

    Heartbeat = json:decode(next_sent(1000)),
    ?assertEqual(null, lists:nth(1, Heartbeat)),
    ?assertEqual(<<"phoenix">>, lists:nth(3, Heartbeat)),
    ?assertEqual(<<"heartbeat">>, lists:nth(4, Heartbeat)),

    nh_agent:stop(Agent).

%% Incoming traffic must not starve the heartbeat. With a `receive ... after'
%% timeout it would: every message would reset the clock and the server would
%% eventually close a socket that looks busy.
traffic_does_not_starve_the_heartbeat_test() ->
    setup(),
    {ok, Agent} = nh_agent:start(config(#{heartbeat_ms => 300})),
    _ = next_opened(),

    Agent ! {websocket, fake_handle, connected},
    _Join = next_sent(1000),

    %% Chatter at a shorter interval than the heartbeat, for longer than one.
    Noise = json:encode([null, null, <<"device">>, <<"noise">>, #{}]),
    [
        begin
            Agent ! {websocket, fake_handle, {text, iolist_to_binary(Noise)}},
            timer:sleep(50)
        end
     || _ <- lists:seq(1, 10)
    ],

    Frame = json:decode(next_sent(1000)),
    ?assertEqual(<<"heartbeat">>, lists:nth(4, Frame)),

    nh_agent:stop(Agent).

surfaces_join_and_messages_test() ->
    setup(),
    {ok, Agent} = nh_agent:start(config(#{})),
    _ = next_opened(),

    Agent ! {websocket, fake_handle, connected},
    Frame = json:decode(next_sent(1000)),
    [JoinRef, Ref | _] = Frame,

    Reply = json:encode([
        JoinRef,
        Ref,
        <<"device">>,
        <<"phx_reply">>,
        #{
            <<"status">> => <<"ok">>, <<"response">> => #{}
        }
    ]),
    Agent ! {websocket, fake_handle, {text, iolist_to_binary(Reply)}},
    ?assertMatch({joined, _}, next_event(1000)),

    Update = json:encode([
        JoinRef,
        null,
        <<"device">>,
        <<"update">>,
        #{
            <<"firmware_url">> => <<"https://example.com/fw.bin">>
        }
    ]),
    Agent ! {websocket, fake_handle, {text, iolist_to_binary(Update)}},
    ?assertMatch({message, <<"update">>, #{<<"firmware_url">> := _}}, next_event(1000)),

    nh_agent:stop(Agent).

%% ------------------------------------------------------------------- helpers

next_opened() ->
    receive
        {opened, _, Config} -> Config
    after 1000 -> erlang:error(never_opened)
    end.

next_closed() ->
    receive
        closed -> closed
    after 1000 -> never_closed
    end.

next_sent(Timeout) ->
    receive
        {sent, Frame} -> Frame
    after Timeout -> nothing_sent
    end.

next_event(Timeout) ->
    receive
        {nerves_hub, Event} -> Event
    after Timeout -> no_event
    end.

%% Joins and returns {Agent, JoinRef}.
join(Config) ->
    setup(),
    {ok, Agent} = nh_agent:start(config(Config)),
    _ = next_opened(),
    Agent ! {websocket, fake_handle, connected},
    [JoinRef, Ref | _] = json:decode(next_sent(1000)),
    Reply = json:encode([
        JoinRef,
        Ref,
        <<"device">>,
        <<"phx_reply">>,
        #{<<"status">> => <<"ok">>, <<"response">> => #{}}
    ]),
    Agent ! {websocket, fake_handle, {text, iolist_to_binary(Reply)}},
    ?assertMatch({joined, _}, next_event(1000)),
    _Interface = wait_for_event(<<"report_network_interface">>, 1000),
    {Agent, JoinRef}.

send_update(Agent, JoinRef, Payload) ->
    Frame = json:encode([JoinRef, null, <<"device">>, <<"update">>, Payload]),
    Agent ! {websocket, fake_handle, {text, iolist_to_binary(Frame)}}.

%% The download runs in its own process, and reports back. Off a device it
%% cannot write flash, so it fails immediately — which is the whole path from
%% the server's message to the failure reported back to the server.
an_available_update_is_downloaded_and_failures_reported_test() ->
    {Agent, JoinRef} = join(#{}),

    send_update(Agent, JoinRef, #{
        <<"update_available">> => true,
        <<"firmware_url">> => <<"http://example.com/fw.avm">>,
        <<"size">> => 1024,
        <<"checksum">> => <<"abc">>
    }),

    ?assertMatch({message, <<"update">>, _}, next_event(1000)),
    ?assertMatch({update_started, _Pid}, next_event(1000)),
    ?assertMatch({update_failed, no_flash_access}, next_event(2000)),

    %% Accepted first, and the failure then goes back to NervesHub rather than
    %% only to the log.
    Received = wait_for_event(<<"status_update">>, 2000),
    ?assertEqual(<<"received">>, maps:get(<<"status">>, Received)),
    Reported = wait_for_event(<<"status_update">>, 2000),
    ?assertEqual(<<"failed">>, maps:get(<<"status">>, Reported)),
    ?assertEqual(<<"no_flash_access">>, maps:get(<<"reason">>, Reported)),

    nh_agent:stop(Agent).

%% `update_available => false' is NervesHub saying there is nothing to do.
an_unavailable_update_starts_nothing_test() ->
    {Agent, JoinRef} = join(#{}),

    send_update(Agent, JoinRef, #{<<"update_available">> => false}),
    ?assertMatch({message, <<"update">>, _}, next_event(1000)),
    ?assertEqual(no_event, next_event(300)),

    nh_agent:stop(Agent).

%% An application that would rather decide for itself gets the message and
%% nothing else.
manual_updates_are_only_reported_test() ->
    {Agent, JoinRef} = join(#{updates => manual}),

    send_update(Agent, JoinRef, #{
        <<"update_available">> => true,
        <<"firmware_url">> => <<"http://example.com/fw.avm">>
    }),

    ?assertMatch({message, <<"update">>, _}, next_event(1000)),
    ?assertEqual(no_event, next_event(300)),

    nh_agent:stop(Agent).

%% Reads sent frames until one carries the named event.
wait_for_event(Event, Timeout) ->
    case next_sent(Timeout) of
        nothing_sent ->
            ?assert(false);
        Frame ->
            case json:decode(Frame) of
                [_, _, _, Event, Payload] -> Payload;
                _Other -> wait_for_event(Event, Timeout)
            end
    end.

%% ------------------------------------------------------------------ console

%% Joins both topics and answers both joins, returning the console's join ref.
join_with_console() ->
    setup(),
    {ok, Agent} = nh_agent:start(config(#{console => true})),
    _ = next_opened(),
    Agent ! {websocket, fake_handle, connected},

    [DeviceJoinRef, DeviceRef, _, _, _] = json:decode(next_sent(1000)),
    [ConsoleJoinRef, ConsoleRef, ConsoleTopic, _, _] = json:decode(next_sent(1000)),
    ?assertEqual(<<"console">>, ConsoleTopic),

    ok = reply(Agent, DeviceJoinRef, DeviceRef, <<"device">>),
    ?assertMatch({joined, _}, next_event(1000)),
    ok = reply(Agent, ConsoleJoinRef, ConsoleRef, <<"console">>),

    {Agent, ConsoleJoinRef}.

reply(Agent, JoinRef, Ref, Topic) ->
    Frame = json:encode([
        JoinRef,
        Ref,
        Topic,
        <<"phx_reply">>,
        #{<<"status">> => <<"ok">>, <<"response">> => #{}}
    ]),
    Agent ! {websocket, fake_handle, {text, iolist_to_binary(Frame)}},
    ok.

send_console(Agent, JoinRef, Event, Payload) ->
    Frame = json:encode([JoinRef, null, <<"console">>, Event, Payload]),
    Agent ! {websocket, fake_handle, {text, iolist_to_binary(Frame)}}.

%% A remote console is a capability, so it is asked for rather than assumed.
no_console_topic_unless_asked_for_test() ->
    setup(),
    {ok, Agent} = nh_agent:start(config(#{})),
    _ = next_opened(),
    Agent ! {websocket, fake_handle, connected},

    [_, _, Topic, <<"phx_join">>, _] = json:decode(next_sent(1000)),
    ?assertEqual(<<"device">>, Topic),
    ?assertEqual(nothing_sent, next_sent(300)),

    nh_agent:stop(Agent).

%% A console that says nothing until you type looks like one that is broken,
%% and the commands are not guessable.
joining_the_console_sends_a_banner_test() ->
    {Agent, _JoinRef} = join_with_console(),

    #{<<"data">> := Data} = wait_for_event(<<"up">>, 1000),
    ?assertMatch({_, _}, binary:match(Data, <<"help">>)),
    ?assertMatch({_, _}, binary:match(Data, nh_console:prompt())),

    nh_agent:stop(Agent).

keystrokes_are_echoed_back_test() ->
    {Agent, JoinRef} = join_with_console(),
    _Banner = wait_for_event(<<"up">>, 1000),

    send_console(Agent, JoinRef, <<"dn">>, #{<<"data">> => <<"info">>}),
    #{<<"data">> := Data} = wait_for_event(<<"up">>, 1000),
    ?assertEqual(<<"info">>, Data),

    nh_agent:stop(Agent).

a_command_answers_on_the_console_topic_test() ->
    {Agent, JoinRef} = join_with_console(),
    _Banner = wait_for_event(<<"up">>, 1000),

    send_console(Agent, JoinRef, <<"dn">>, #{<<"data">> => <<"help\r">>}),
    #{<<"data">> := Data} = wait_for_event(<<"up">>, 1000),

    ?assertMatch({_, _}, binary:match(Data, <<"reboot">>)),
    ?assertMatch({_, _}, binary:match(Data, nh_console:prompt())),

    nh_agent:stop(Agent).

restart_resets_the_session_rather_than_the_device_test() ->
    {Agent, JoinRef} = join_with_console(),
    _Banner = wait_for_event(<<"up">>, 1000),

    send_console(Agent, JoinRef, <<"restart">>, #{}),
    #{<<"data">> := Data} = wait_for_event(<<"up">>, 1000),
    ?assertMatch({_, _}, binary:match(Data, <<"Console restarted">>)),

    nh_agent:stop(Agent).

%% Quietly accepting bytes nothing will ever write would be worse than saying so.
file_transfer_is_declined_test() ->
    {Agent, JoinRef} = join_with_console(),
    _Banner = wait_for_event(<<"up">>, 1000),

    send_console(Agent, JoinRef, <<"file-data/start">>, #{<<"filename">> => <<"x">>}),
    #{<<"data">> := Data} = wait_for_event(<<"up">>, 1000),
    ?assertMatch({_, _}, binary:match(Data, <<"not supported">>)),

    nh_agent:stop(Agent).

%% Resizing a terminal is routine and must not read as an unhandled message.
window_size_is_accepted_quietly_test() ->
    {Agent, JoinRef} = join_with_console(),
    _Banner = wait_for_event(<<"up">>, 1000),

    send_console(Agent, JoinRef, <<"window_size">>, #{<<"height">> => 24, <<"width">> => 80}),
    ?assertEqual(nothing_sent, next_sent(300)),

    nh_agent:stop(Agent).

%% --------------------------------------------------------------- extensions

%% Joins device + extensions, answering both. Returns the extensions join ref.
%% What NervesHub advertises after the device joins: every extension it knows,
%% with the versions it speaks, newest first.
advert() ->
    #{
        <<"extensions">> => #{
            <<"health">> => [<<"0.0.1">>],
            <<"geo">> => [<<"0.0.1">>],
            <<"logging">> => [<<"0.1.0">>, <<"0.0.1">>]
        }
    }.

join_with_extensions(Enabled, AttachList) ->
    join_with_extensions(#{extensions => Enabled}, AttachList, advert()).

join_with_extensions(Enabled, AttachList, Advert) when not is_map(Enabled) ->
    join_with_extensions(#{extensions => Enabled}, AttachList, Advert);
join_with_extensions(Extra, AttachList, Advert) when is_map(Extra) ->
    setup(),
    {ok, Agent} = nh_agent:start(config(Extra)),
    _ = next_opened(),
    Agent ! {websocket, fake_handle, connected},

    %% Only the device topic joins on connect. The extensions topic waits to
    %% hear what NervesHub speaks.
    [DeviceJoinRef, DeviceRef, <<"device">>, _, _] = json:decode(next_sent(1000)),
    ?assertEqual(nothing_sent, next_sent(100)),

    ok = reply(Agent, DeviceJoinRef, DeviceRef, <<"device">>),
    ?assertMatch({joined, _}, next_event(1000)),
    _Interface = wait_for_event(<<"report_network_interface">>, 1000),

    send_device(Agent, DeviceJoinRef, <<"extensions:get">>, Advert),
    [ExtJoinRef, ExtRef, ExtTopic, <<"phx_join">>, Offered] = json:decode(next_sent(1000)),
    ?assertEqual(<<"extensions">>, ExtTopic),

    Frame = json:encode([
        ExtJoinRef,
        ExtRef,
        <<"extensions">>,
        <<"phx_reply">>,
        #{<<"status">> => <<"ok">>, <<"response">> => AttachList}
    ]),
    Agent ! {websocket, fake_handle, {text, iolist_to_binary(Frame)}},
    ?assertMatch({extensions_attached, _}, next_event(1000)),

    %% NervesHub waits for `<key>:attached' before it starts an extension, so
    %% each attached one is confirmed before anything else goes out.
    lists:foreach(
        fun(Name) ->
            [_, _, <<"extensions">>, Event, _] = json:decode(next_sent(1000)),
            ?assertEqual(<<Name/binary, ":attached">>, Event)
        end,
        AttachList
    ),

    {Agent, ExtJoinRef, Offered}.

send_extension(Agent, JoinRef, Event, Payload) ->
    Frame = json:encode([JoinRef, null, <<"extensions">>, Event, Payload]),
    Agent ! {websocket, fake_handle, {text, iolist_to_binary(Frame)}}.

no_extensions_topic_unless_any_are_enabled_test() ->
    setup(),
    {ok, Agent} = nh_agent:start(config(#{})),
    _ = next_opened(),
    Agent ! {websocket, fake_handle, connected},

    [_, _, <<"device">>, <<"phx_join">>, _] = json:decode(next_sent(1000)),
    ?assertEqual(nothing_sent, next_sent(300)),

    nh_agent:stop(Agent).

the_join_declares_what_the_device_offers_test() ->
    {Agent, _Ref, Offered} = join_with_extensions([health, geo], [<<"health">>]),

    ?assertEqual([<<"geo">>, <<"health">>], lists:sort(maps:keys(Offered))),
    ?assertEqual(<<"0.0.1">>, maps:get(<<"health">>, Offered)),

    nh_agent:stop(Agent).

a_health_check_is_answered_with_a_report_test() ->
    {Agent, Ref, _} = join_with_extensions([health], [<<"health">>]),

    send_extension(Agent, Ref, <<"health:check">>, #{}),
    Payload = wait_for_event(<<"health:report">>, 2000),

    ?assert(maps:is_key(<<"value">>, Payload)),
    ?assert(maps:is_key(<<"metrics">>, maps:get(<<"value">>, Payload))),

    nh_agent:stop(Agent).

%% The platform asking for something it never turned on is not answered.
a_check_for_a_detached_extension_is_ignored_test() ->
    {Agent, Ref, _} = join_with_extensions([health, geo], [<<"geo">>]),

    send_extension(Agent, Ref, <<"health:check">>, #{}),
    ?assertEqual(nothing_sent, next_sent(500)),

    nh_agent:stop(Agent).

%% Sent on the extensions topic, and only when logging is attached.
%% Logging 0.0.1, for a NervesHub that speaks no newer: one line per message,
%% sent as it comes.
a_log_line_goes_out_on_the_extensions_topic_test() ->
    Advert = #{<<"extensions">> => #{<<"logging">> => [<<"0.0.1">>]}},
    {Agent, _Ref, Offered} = join_with_extensions([logging], [<<"logging">>], Advert),
    ?assertEqual(#{<<"logging">> => <<"0.0.1">>}, Offered),

    ok = nerves_hub_link:send_log(Agent, <<"info">>, <<"hello from the bench">>),
    Payload = wait_for_event(<<"logging:send">>, 2000),

    ?assertEqual(<<"info">>, maps:get(<<"level">>, Payload)),
    ?assertEqual(<<"hello from the bench">>, maps:get(<<"message">>, Payload)),
    ?assert(is_binary(maps:get(<<"time">>, maps:get(<<"meta">>, Payload)))),

    nh_agent:stop(Agent).

%% 0.1.0 when NervesHub speaks it: lines are held and go together.
log_lines_are_batched_when_nervesHub_speaks_0_1_0_test() ->
    {Agent, _Ref, Offered} = join_with_extensions(
        #{extensions => [logging], log_flush_ms => 200}, [<<"logging">>], advert()
    ),
    ?assertEqual(#{<<"logging">> => <<"0.1.0">>}, Offered),

    ok = nerves_hub_link:send_log(Agent, <<"info">>, <<"one">>),
    ok = nerves_hub_link:send_log(Agent, <<"warning">>, <<"two">>),
    #{<<"lines">> := Lines} = wait_for_event(<<"logging:send">>, 2000),

    ?assertEqual([<<"one">>, <<"two">>], [maps:get(<<"message">>, L) || L <- Lines]),
    ?assertEqual(<<"warning">>, maps:get(<<"level">>, lists:nth(2, Lines))),

    nh_agent:stop(Agent).

%% A full batch does not wait for the timer.
a_full_batch_goes_at_once_test() ->
    {Agent, _Ref, _} = join_with_extensions(
        #{extensions => [logging], log_flush_ms => 60000, log_buffer => 500},
        [<<"logging">>],
        advert()
    ),

    [
        ok = nerves_hub_link:send_log(Agent, <<"info">>, integer_to_binary(N))
     || N <- lists:seq(1, 100)
    ],
    #{<<"lines">> := Lines} = wait_for_event(<<"logging:send">>, 2000),
    ?assertEqual(100, length(Lines)),

    nh_agent:stop(Agent).

%% ------------------------------------------------------------------ actions

send_device(Agent, JoinRef, Event) ->
    send_device(Agent, JoinRef, Event, #{}).

send_device(Agent, JoinRef, Event, Payload) ->
    Frame = json:encode([JoinRef, null, <<"device">>, Event, Payload]),
    Agent ! {websocket, fake_handle, {text, iolist_to_binary(Frame)}}.

%% Only the application knows what identifying looks like on its hardware.
identify_is_reported_to_the_application_test() ->
    {Agent, JoinRef} = join_device(),

    send_device(Agent, JoinRef, <<"identify">>),
    ?assertEqual(identify, next_event(1000)),

    %% and nothing is sent back: NervesHub asks, it does not wait for an answer
    ?assertEqual(nothing_sent, next_sent(300)),

    nh_agent:stop(Agent).

%% NervesHub never learns why a device vanished unless this arrives first.
reboot_announces_itself_before_going_test() ->
    {Agent, JoinRef} = join_device(#{reboot => manual}),

    send_device(Agent, JoinRef, <<"reboot">>),
    ?assertEqual(reboot_requested, next_event(1000)),

    [_, _, <<"device">>, Event, _] = json:decode(next_sent(1000)),
    ?assertEqual(<<"rebooting">>, Event),

    nh_agent:stop(Agent).

%% An application that would rather choose its moment gets the message and the
%% device stays up.
manual_reboot_leaves_the_device_running_test() ->
    {Agent, JoinRef} = join_device(#{reboot => manual}),

    send_device(Agent, JoinRef, <<"reboot">>),
    ?assertEqual(reboot_requested, next_event(1000)),
    _ = next_sent(1000),

    %% still answering afterwards
    ok = nerves_hub_link:update_progress(Agent, 42),
    [_, _, _, <<"update_progress">>, Payload] = json:decode(next_sent(1000)),
    ?assertEqual(42, maps:get(<<"value">>, Payload)),

    nh_agent:stop(Agent).

join_device() -> join_device(#{}).

join_device(Extra) ->
    setup(),
    {ok, Agent} = nh_agent:start(config(Extra)),
    _ = next_opened(),
    Agent ! {websocket, fake_handle, connected},
    [JoinRef, Ref | _] = json:decode(next_sent(1000)),
    ok = reply(Agent, JoinRef, Ref, <<"device">>),
    ?assertMatch({joined, _}, next_event(1000)),
    _Interface = wait_for_event(<<"report_network_interface">>, 1000),
    {Agent, JoinRef}.

%% ---------------------------------------------------------------- reconnecting

%% The transport must not reconnect on its own: it would replay headers signed
%% for the first connection, which NervesHub refuses after 90 seconds.
the_transport_is_told_not_to_reconnect_test() ->
    setup(),
    {ok, Agent} = nh_agent:start(config(#{})),
    Opened = next_opened(),
    ?assertEqual(true, maps:get(disable_auto_reconnect, Opened)),
    nh_agent:stop(Agent).

%% Each connection is signed when it is made. The wait is over a second so the
%% signing time, which is in seconds, has moved on.
a_reconnect_is_signed_afresh_test() ->
    setup(),
    {ok, Agent} = nh_agent:start(
        config(#{
            shared_secret => {<<"nhp_key">>, <<"secret">>},
            reconnect_backoff => {1100, 1100}
        })
    ),
    First = next_opened(),
    Agent ! {websocket, fake_handle, connected},
    _Join = next_sent(1000),

    Agent ! {websocket, fake_handle, {closed, disconnected}},
    ?assertEqual({disconnected, disconnected}, next_event(1000)),
    ?assertEqual(closed, next_closed()),
    Second =
        receive
            {opened, _, Config} -> Config
        after 3000 -> erlang:error(never_reopened)
        end,

    ?assertNotEqual(header(<<"x-nh-time">>, First), header(<<"x-nh-time">>, Second)),
    ?assertNotEqual(header(<<"x-nh-signature">>, First), header(<<"x-nh-signature">>, Second)),

    nh_agent:stop(Agent).

header(Name, #{headers := Headers}) ->
    {Name, Value} = lists:keyfind(Name, 1, Headers),
    Value.

%% A connection that never comes up is given up on and tried again, rather
%% than waited on forever.
a_connection_that_never_comes_up_is_retried_test() ->
    setup(),
    {ok, Agent} = nh_agent:start(
        config(#{connect_timeout_ms => 50, reconnect_backoff => {10, 20}})
    ),
    _ = next_opened(),

    ?assertEqual({transport_error, connect_timeout}, next_event(1000)),
    ?assertEqual(closed, next_closed()),
    _ = next_opened(),

    nh_agent:stop(Agent).

%% Before `connected', an error is the attempt failing, and is retried.
an_error_before_connecting_is_retried_test() ->
    setup(),
    {ok, Agent} = nh_agent:start(config(#{reconnect_backoff => {10, 20}})),
    _ = next_opened(),

    Agent ! {websocket, fake_handle, {error, {esp_tls, 1, 2, 3}}},
    ?assertMatch({transport_error, {esp_tls, _, _, _}}, next_event(1000)),
    _ = next_opened(),

    nh_agent:stop(Agent).

%% ------------------------------------------------------------ what it reports

the_join_says_which_protocol_it_speaks_test() ->
    setup(),
    {ok, Agent} = nh_agent:start(config(#{})),
    _ = next_opened(),
    Agent ! {websocket, fake_handle, connected},
    [_, _, <<"device">>, <<"phx_join">>, Payload] = json:decode(next_sent(1000)),

    ?assertEqual(<<"2.4.0">>, maps:get(<<"device_api_version">>, Payload)),
    ?assertEqual(
        #{<<"firmware_validated">> => true, <<"firmware_auto_revert_detected">> => false},
        maps:get(<<"meta">>, Payload)
    ),

    nh_agent:stop(Agent).

the_console_join_declines_file_transfer_test() ->
    setup(),
    {ok, Agent} = nh_agent:start(config(#{console => true})),
    _ = next_opened(),
    Agent ! {websocket, fake_handle, connected},
    _Device = next_sent(1000),
    [_, _, <<"console">>, <<"phx_join">>, Payload] = json:decode(next_sent(1000)),

    ?assertEqual(<<"1.0.0">>, maps:get(<<"console_version">>, Payload)),

    nh_agent:stop(Agent).

the_network_interface_is_reported_on_join_test() ->
    setup(),
    {ok, Agent} = nh_agent:start(config(#{network_interface => <<"eth0">>})),
    _ = next_opened(),
    Agent ! {websocket, fake_handle, connected},
    [JoinRef, Ref | _] = json:decode(next_sent(1000)),
    ok = reply(Agent, JoinRef, Ref, <<"device">>),

    ?assertEqual(
        #{<<"interface">> => <<"eth0">>}, wait_for_event(<<"report_network_interface">>, 1000)
    ),

    nh_agent:stop(Agent).

%% --------------------------------------------------------------------- scripts

run_script(Agent, JoinRef, Text) ->
    send_device(Agent, JoinRef, <<"scripts/run">>, #{<<"ref">> => <<"r1">>, <<"text">> => Text}),
    wait_for_event(<<"scripts/run">>, 2000).

a_script_runs_console_commands_test() ->
    {Agent, JoinRef} = join_device(),

    Result = run_script(Agent, JoinRef, <<"# how is it doing\nuptime\n\nhelp\n">>),

    ?assertEqual(<<"r1">>, maps:get(<<"ref">>, Result)),
    ?assertEqual(<<"completed">>, maps:get(<<"result">>, Result)),
    ?assertEqual(<<"ok">>, maps:get(<<"return">>, Result)),
    Output = maps:get(<<"output">>, Result),
    ?assertMatch({_, _}, binary:match(Output, <<"> uptime">>)),
    ?assertMatch({_, _}, binary:match(Output, <<"> help">>)),
    ?assertEqual(nomatch, binary:match(Output, <<"\r">>)),

    nh_agent:stop(Agent).

%% A script written for Nerves cannot run here, and says so.
a_script_that_is_not_commands_fails_test() ->
    {Agent, JoinRef} = join_device(),

    Result = run_script(Agent, JoinRef, <<"IO.puts(\"hi\")">>),

    ?assertEqual(<<"error">>, maps:get(<<"result">>, Result)),
    ?assertEqual(<<"unknown command">>, maps:get(<<"reason">>, Result)),

    nh_agent:stop(Agent).

%% Connecting code runs on every join; a reboot in it would never stop.
a_script_may_not_reboot_test() ->
    {Agent, JoinRef} = join_device(),

    Result = run_script(Agent, JoinRef, <<"uptime\nreboot">>),

    ?assertEqual(<<"error">>, maps:get(<<"result">>, Result)),
    ?assertMatch({_, _}, binary:match(maps:get(<<"reason">>, Result), <<"reboot">>)),

    nh_agent:stop(Agent).

%% ------------------------------------------------------ device-managed updates

%% The calls block, and this process is also the transport, so they are made
%% from another one.
async(Fun) ->
    Self = self(),
    spawn(fun() -> Self ! {async, Fun()} end).

async_result() ->
    receive
        {async, Result} -> Result
    after 2000 -> erlang:error(no_async_result)
    end.

check_for_update_asks_and_reports_the_answer_test() ->
    {Agent, JoinRef} = join_device(),

    async(fun() -> nerves_hub_link:check_for_update(Agent) end),
    ?assertEqual(#{}, wait_for_event(<<"check_update">>, 1000)),

    Meta = #{<<"version">> => <<"1.3.0">>},
    send_device(Agent, JoinRef, <<"update_available">>, #{
        <<"available">> => true, <<"firmware_meta">> => Meta
    }),
    ?assertEqual({ok, #{available => true, firmware_meta => Meta}}, async_result()),

    nh_agent:stop(Agent).

one_request_of_a_kind_at_a_time_test() ->
    {Agent, _JoinRef} = join_device(),

    async(fun() -> nerves_hub_link:check_for_update(Agent) end),
    _ = wait_for_event(<<"check_update">>, 1000),
    ?assertEqual({error, already_in_progress}, nerves_hub_link:check_for_update(Agent)),

    nh_agent:stop(Agent).

a_request_while_disconnected_is_refused_test() ->
    setup(),
    {ok, Agent} = nh_agent:start(config(#{})),
    _ = next_opened(),
    ?assertEqual({error, disconnected}, nerves_hub_link:request_update(Agent)),
    nh_agent:stop(Agent).

%% A pending request is answered when the connection goes, not left to time out.
a_disconnect_fails_what_was_pending_test() ->
    {Agent, _JoinRef} = join_device(#{reconnect_backoff => {60000, 60000}}),

    async(fun() -> nerves_hub_link:check_for_update(Agent) end),
    _ = wait_for_event(<<"check_update">>, 1000),
    Agent ! {websocket, fake_handle, {closed, disconnected}},

    ?assertEqual({error, disconnected}, async_result()),
    nh_agent:stop(Agent).

%% Asking is the decision, so the update is installed even with manual updates.
request_update_installs_what_comes_back_test() ->
    {Agent, JoinRef} = join_device(#{updates => manual}),

    async(fun() -> nerves_hub_link:request_update(Agent) end),
    ?assertEqual(#{}, wait_for_event(<<"request_update">>, 1000)),

    send_update(Agent, JoinRef, #{
        <<"update_available">> => true,
        <<"firmware_url">> => <<"http://example.com/fw.avm">>,
        <<"size">> => 1024,
        <<"checksum">> => <<"abc">>
    }),
    ?assertEqual(ok, async_result()),
    ?assertMatch({message, <<"update">>, _}, next_event(1000)),
    ?assertMatch({update_started, _}, next_event(1000)),

    nh_agent:stop(Agent).

a_rejected_request_says_why_test() ->
    {Agent, JoinRef} = join_device(),

    async(fun() -> nerves_hub_link:request_update(Agent) end),
    _ = wait_for_event(<<"request_update">>, 1000),
    send_device(Agent, JoinRef, <<"update_rejected">>, #{<<"reason">> => <<"no_update">>}),

    ?assertEqual({error, no_update}, async_result()),
    nh_agent:stop(Agent).

set_update_mode_is_answered_with_the_mode_test() ->
    {Agent, JoinRef} = join_device(),

    async(fun() -> nerves_hub_link:set_update_mode(Agent, device_managed) end),
    ?assertEqual(
        #{<<"mode">> => <<"device_managed">>}, wait_for_event(<<"set_update_mode">>, 1000)
    ),
    send_device(Agent, JoinRef, <<"update_mode">>, #{
        <<"mode">> => <<"device_managed">>, <<"managed_updates_allowed">> => true
    }),

    Expected = #{mode => device_managed, managed_updates_allowed => true},
    ?assertEqual({ok, Expected}, async_result()),
    ?assertEqual({ok, Expected}, nerves_hub_link:update_mode(Agent)),

    nh_agent:stop(Agent).

a_refused_mode_change_is_an_error_test() ->
    {Agent, JoinRef} = join_device(),

    async(fun() -> nerves_hub_link:set_update_mode(Agent, device_managed) end),
    _ = wait_for_event(<<"set_update_mode">>, 1000),
    send_device(Agent, JoinRef, <<"update_mode">>, #{
        <<"mode">> => <<"automatic">>,
        <<"managed_updates_allowed">> => false,
        <<"error">> => <<"not_permitted">>
    }),

    ?assertEqual({error, not_permitted}, async_result()),
    nh_agent:stop(Agent).

%% NervesHub reports the mode after every join, unasked.
the_mode_is_reported_to_the_application_test() ->
    {Agent, JoinRef} = join_device(),
    ?assertEqual({error, unknown}, nerves_hub_link:update_mode(Agent)),

    send_device(Agent, JoinRef, <<"update_mode">>, #{
        <<"mode">> => <<"automatic">>, <<"managed_updates_allowed">> => false
    }),
    ?assertEqual({update_mode, automatic, false}, next_event(1000)),

    nh_agent:stop(Agent).

%% -------------------------------------------------------------- manual updates

declining_an_update_tells_nervesHub_test() ->
    {Agent, _JoinRef} = join_device(#{updates => manual}),

    ok = nerves_hub_link:ignore_update(Agent, <<"on battery">>),
    ?assertEqual(
        #{<<"status">> => <<"ignored">>, <<"reason">> => <<"on battery">>},
        wait_for_event(<<"status_update">>, 1000)
    ),

    ok = nerves_hub_link:reschedule_update(Agent, 60000, <<"busy">>),
    ?assertEqual(
        #{<<"status">> => <<"rescheduled">>, <<"delay_for">> => 60000, <<"reason">> => <<"busy">>},
        wait_for_event(<<"status_update">>, 1000)
    ),

    nh_agent:stop(Agent).

%% ------------------------------------------------------- extension lifecycle

an_operator_can_detach_and_reattach_an_extension_test() ->
    {Agent, Ref, _} = join_with_extensions([health], [<<"health">>]),

    send_extension(Agent, Ref, <<"detach">>, #{<<"extensions">> => [<<"health">>]}),
    [_, _, <<"extensions">>, Detached, _] = json:decode(next_sent(1000)),
    ?assertEqual(<<"health:detached">>, Detached),

    %% and it stops answering
    send_extension(Agent, Ref, <<"health:check">>, #{}),
    ?assertEqual(nothing_sent, next_sent(300)),

    send_extension(Agent, Ref, <<"attach">>, #{<<"extensions">> => [<<"health">>]}),
    [_, _, <<"extensions">>, Attached, _] = json:decode(next_sent(1000)),
    ?assertEqual(<<"health:attached">>, Attached),

    send_extension(Agent, Ref, <<"health:check">>, #{}),
    _ = wait_for_event(<<"health:report">>, 2000),

    nh_agent:stop(Agent).

attaching_what_the_device_cannot_run_is_an_error_test() ->
    {Agent, Ref, _} = join_with_extensions([health], [<<"health">>]),

    send_extension(Agent, Ref, <<"attach">>, #{<<"extensions">> => [<<"local_shell">>]}),
    [_, _, <<"extensions">>, Event, Payload] = json:decode(next_sent(1000)),
    ?assertEqual(<<"local_shell:error">>, Event),
    ?assertEqual(#{<<"reason">> => <<"unknown_extension">>}, Payload),

    nh_agent:stop(Agent).

%% NervesHub answers a push for an extension it does not know with `detach'.
a_detach_reply_stops_the_extension_test() ->
    {Agent, Ref, _} = join_with_extensions([health], [<<"health">>]),

    send_extension(Agent, Ref, <<"health:check">>, #{}),
    [JoinRef, PushRef, <<"extensions">>, <<"health:report">>, _] = json:decode(next_sent(2000)),

    Reply = json:encode([
        JoinRef,
        PushRef,
        <<"extensions">>,
        <<"phx_reply">>,
        #{<<"status">> => <<"error">>, <<"response">> => <<"detach">>}
    ]),
    Agent ! {websocket, fake_handle, {text, iolist_to_binary(Reply)}},
    ?assertEqual({extension_detached, <<"health">>}, next_event(1000)),

    send_extension(Agent, Ref, <<"health:check">>, #{}),
    ?assertEqual(nothing_sent, next_sent(300)),

    nh_agent:stop(Agent).

%% An older NervesHub never advertises. The device joins anyway, with the
%% oldest version of each.
without_an_advert_the_extensions_join_anyway_test() ->
    setup(),
    {ok, Agent} = nh_agent:start(
        config(#{extensions => [logging, health], extensions_fallback_ms => 50})
    ),
    _ = next_opened(),
    Agent ! {websocket, fake_handle, connected},
    [JoinRef, Ref, <<"device">>, _, _] = json:decode(next_sent(1000)),
    ok = reply(Agent, JoinRef, Ref, <<"device">>),
    _Interface = wait_for_event(<<"report_network_interface">>, 1000),

    [_, _, <<"extensions">>, <<"phx_join">>, Offered] = json:decode(next_sent(1000)),
    ?assertEqual(#{<<"logging">> => <<"0.0.1">>, <<"health">> => <<"0.0.1">>}, Offered),

    nh_agent:stop(Agent).

%% Lines logged while disconnected are held, and go once logging is attached.
logs_held_while_disconnected_go_on_attach_test() ->
    setup(),
    {ok, Agent} = nh_agent:start(config(#{extensions => [logging], log_flush_ms => 60000})),
    _ = next_opened(),
    ok = nerves_hub_link:send_log(Agent, <<"info">>, <<"before connecting">>),

    Agent ! {websocket, fake_handle, connected},
    [DeviceJoinRef, DeviceRef, _, _, _] = json:decode(next_sent(1000)),
    ok = reply(Agent, DeviceJoinRef, DeviceRef, <<"device">>),
    _Interface = wait_for_event(<<"report_network_interface">>, 1000),
    send_device(Agent, DeviceJoinRef, <<"extensions:get">>, advert()),
    [ExtJoinRef, ExtRef, _, _, _] = json:decode(next_sent(1000)),
    Frame = json:encode([
        ExtJoinRef,
        ExtRef,
        <<"extensions">>,
        <<"phx_reply">>,
        #{<<"status">> => <<"ok">>, <<"response">> => [<<"logging">>]}
    ]),
    Agent ! {websocket, fake_handle, {text, iolist_to_binary(Frame)}},

    #{<<"lines">> := [Line]} = wait_for_event(<<"logging:send">>, 1000),
    ?assertEqual(<<"before connecting">>, maps:get(<<"message">>, Line)),

    nh_agent:stop(Agent).

%% ------------------------------------------------------------------ the trial

on_trial(Extra) ->
    ok = nh_ota_fake_esp:start(),
    ok = nh_ota_fake_esp:nvs_set_binary(nerves_hub, pending_slot, <<"alt.avm">>),
    ok = nh_ota_fake_esp:nvs_set_binary(nerves_hub, previous_slot, <<"main.avm">>),
    setup(),
    {ok, Agent} = nh_agent:start(config(maps:merge(#{esp => nh_ota_fake_esp}, Extra))),
    ?assertEqual({firmware_trial, <<"alt.avm">>, 1}, next_event(1000)),
    _ = next_opened(),
    Agent.

firmware_on_trial_joins_as_not_yet_validated_test() ->
    Agent = on_trial(#{}),
    Agent ! {websocket, fake_handle, connected},
    [_, _, <<"device">>, <<"phx_join">>, Payload] = json:decode(next_sent(1000)),

    ?assertEqual(false, maps:get(<<"firmware_validated">>, maps:get(<<"meta">>, Payload))),

    nh_agent:stop(Agent),
    nh_ota_fake_esp:stop().

%% Joining is what proves it. Rejoining afterwards says so.
joining_validates_firmware_on_trial_test() ->
    Agent = on_trial(#{reconnect_backoff => {10, 20}}),
    Agent ! {websocket, fake_handle, connected},
    [JoinRef, Ref | _] = json:decode(next_sent(1000)),
    ok = reply(Agent, JoinRef, Ref, <<"device">>),

    ?assertMatch({joined, _}, next_event(1000)),
    ?assertEqual({firmware_committed, <<"alt.avm">>}, next_event(1000)),
    ?assertEqual(#{}, wait_for_event(<<"firmware_validated">>, 1000)),

    Agent ! {websocket, fake_handle, {closed, disconnected}},
    _ = next_opened(),
    Agent ! {websocket, fake_handle, connected},
    Payload = wait_for_event(<<"phx_join">>, 1000),
    ?assertEqual(true, maps:get(<<"firmware_validated">>, maps:get(<<"meta">>, Payload))),

    nh_agent:stop(Agent),
    nh_ota_fake_esp:stop().

%% Firmware that cannot reach NervesHub in time goes back to what worked.
firmware_that_never_joins_is_reverted_test() ->
    Agent = on_trial(#{firmware_trial => #{join_timeout_ms => 50}, reboot => manual}),

    ?assertEqual({firmware_reverted, <<"main.avm">>}, next_event(1000)),
    Nvs = nh_ota_fake_esp:nvs(),
    ?assertEqual(<<"/dev/partition/by-name/main.avm">>, maps:get({atomvm, boot_path}, Nvs)),

    nh_agent:stop(Agent),
    nh_ota_fake_esp:stop().

%% And the firmware it went back to says why it is running.
a_reverted_device_reports_it_on_join_test() ->
    ok = nh_ota_fake_esp:start(),
    ok = nh_ota_fake_esp:nvs_set_binary(nerves_hub, reverted, <<"1">>),
    setup(),
    {ok, Agent} = nh_agent:start(config(#{esp => nh_ota_fake_esp})),
    _ = next_opened(),
    Agent ! {websocket, fake_handle, connected},
    [_, _, <<"device">>, <<"phx_join">>, Payload] = json:decode(next_sent(1000)),

    ?assertEqual(
        true, maps:get(<<"firmware_auto_revert_detected">>, maps:get(<<"meta">>, Payload))
    ),

    nh_agent:stop(Agent),
    nh_ota_fake_esp:stop().

%% Out of boots, reverted before it ever tries to connect.
the_last_boot_on_trial_reverts_at_start_test() ->
    ok = nh_ota_fake_esp:start(),
    ok = nh_ota_fake_esp:nvs_set_binary(nerves_hub, pending_slot, <<"alt.avm">>),
    ok = nh_ota_fake_esp:nvs_set_binary(nerves_hub, previous_slot, <<"main.avm">>),
    ok = nh_ota_fake_esp:nvs_set_binary(nerves_hub, boot_attempts, <<"3">>),
    setup(),
    {ok, Agent} = nh_agent:start(config(#{esp => nh_ota_fake_esp, reboot => manual})),

    ?assertEqual({firmware_reverted, <<"main.avm">>}, next_event(1000)),

    nh_agent:stop(Agent),
    nh_ota_fake_esp:stop().
