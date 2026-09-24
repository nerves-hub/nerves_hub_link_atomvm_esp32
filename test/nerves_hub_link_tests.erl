%
% SPDX-License-Identifier: Apache-2.0 OR LGPL-2.1-or-later
%
-module(nerves_hub_link_tests).

-include_lib("eunit/include/eunit.hrl").

%% Same scripted transport as the agent tests: records sends, lets the test
%% deliver socket events.
-export([open/1, send_text/2, close/1]).

open(Config) ->
    ?MODULE ! {opened, Config},
    {ok, fake_handle}.

send_text(fake_handle, Frame) ->
    ?MODULE ! {sent, Frame},
    ok.

close(fake_handle) ->
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

metadata() ->
    nh_metadata:describe(
        #{name => <<"my_app">>, vsn => <<"1.2.3">>, description => <<"a test application">>},
        binary:copy(<<"ab">>, 32)
    ).

config(Extra) ->
    maps:merge(
        #{
            url => "wss://example.com/socket/websocket",
            identifier => <<"dev-1">>,
            firmware => {metadata, metadata()},
            shared_secret => {<<"nhp_key">>, <<"secret">>},
            transport => ?MODULE,
            handler => self()
        },
        Extra
    ).

%% There is only one URL a device sensibly wants, so leaving it out asks for
%% the hosted one rather than failing. See `nh_url'.
a_config_without_a_url_starts_test() ->
    ?assertMatch({ok, _Pid}, nerves_hub_link:start(maps:remove(url, config(#{})))).

%% Caught at startup, so a config that can never build a URL fails before the
%% transport is asked to open one.
a_config_that_cannot_build_a_url_is_refused_test() ->
    ?assertEqual(
        {error, {conflicting_config, [url, host]}},
        nerves_hub_link:start(config(#{host => <<"nh.example.com">>}))
    ).

%% What an Elixir caller writes. The library is meant to be usable from Elixir
%% without a wrapper in between, and a map with atom keys is not what anyone
%% reaches for there first.
a_keyword_list_works_as_well_as_a_map_test() ->
    ?assertMatch({ok, _Pid}, nerves_hub_link:start(maps:to_list(config(#{})))).

%% The list is turned into the same config, not a second code path: an option
%% given as a keyword has to behave exactly as it does in a map.
a_keyword_list_is_validated_the_same_way_test() ->
    Config = maps:to_list(maps:remove(identifier, config(#{}))),

    ?assertEqual({error, {missing_config, [identifier]}}, nerves_hub_link:start(Config)).

%% An identifier has no default that could be right, so it stays required.
requires_an_identifier_test() ->
    ?assertMatch(
        {error, {missing_config, [identifier]}},
        nerves_hub_link:start(maps:remove(identifier, config(#{})))
    ).

%% `firmware' defaults to `boot', which is not a guess: AtomVM records the boot
%% path in NVS, so it stays right after an update that switched slots. Off a
%% device there is no flash to read it from, which is what this sees.
firmware_defaults_to_the_booted_packbeam_test() ->
    ?assertMatch(
        {error, {firmware_unreadable, no_flash_access}},
        nerves_hub_link:start(maps:remove(firmware, config(#{})))
    ).

requires_credentials_test() ->
    ?assertMatch(
        {error, {missing_config, [shared_secret_or_client_cert]}},
        nerves_hub_link:start(maps:remove(shared_secret, config(#{})))
    ).

client_cert_counts_as_credentials_test() ->
    setup(),
    Config = maps:remove(shared_secret, config(#{client_cert => {<<"cert">>, <<"key">>}})),
    {ok, Pid} = nerves_hub_link:start(Config),
    ?assertMatch({opened, _}, next(1000)),
    nerves_hub_link:stop(Pid).

%% A device that cannot describe its firmware must not connect looking like a
%% device that simply never needs updating.
refuses_to_start_when_flash_is_unreadable_test() ->
    ?assertMatch(
        {error, {firmware_unreadable, no_flash_access}},
        nerves_hub_link:start(config(#{firmware => {partition, <<"main.avm">>}}))
    ).

%% Only shared secrets carry a signing time, so a client certificate does not
%% need the clock set and must not be refused for it.
clock_is_only_checked_for_shared_secrets_test() ->
    Config = maps:remove(shared_secret, config(#{firmware => none})),
    WithCert = Config#{client_cert => {<<"cert">>, <<"key">>}},

    %% Gets past validation to the transport, rather than failing on the clock.
    setup(),
    {ok, Pid} = nerves_hub_link:start(WithCert),
    {opened, _} = next(1000),
    nerves_hub_link:stop(Pid).

%% Checked at startup. A mistyped key would otherwise sit unnoticed until the
%% first update, and then look like the firmware had been tampered with.
a_bad_firmware_key_is_refused_at_startup_test() ->
    ?assertMatch(
        {error, {invalid_firmware_key, _}},
        nerves_hub_link:start(config(#{firmware => none, firmware_keys => [<<"nope">>]}))
    ).

good_firmware_keys_are_accepted_test() ->
    {Public, _Priv} = crypto:generate_key(eddsa, ed25519),

    setup(),
    {ok, Pid} = nerves_hub_link:start(
        config(#{firmware => none, firmware_keys => [base64:encode(Public)]})
    ),
    {opened, _} = next(1000),
    nerves_hub_link:stop(Pid).

%% A name is what lets `nh_logger', configured before the agent exists, find it
%% later.
register_gives_the_agent_a_name_test() ->
    setup(),
    Name = list_to_atom("nh_reg_" ++ integer_to_list(erlang:unique_integer([positive]))),
    {ok, Pid} = nerves_hub_link:start(config(#{firmware => none, register => Name})),
    {opened, _} = next(1000),

    ?assertEqual(Pid, whereis(Name)),
    nerves_hub_link:stop(Pid).

%% The holder may be a working agent, and stealing its name would leave logs
%% going to a process nothing else can reach.
a_taken_name_is_refused_test() ->
    setup(),
    Name = list_to_atom("nh_taken_" ++ integer_to_list(erlang:unique_integer([positive]))),
    Squatter = spawn(fun() -> timer:sleep(5000) end),
    true = register(Name, Squatter),

    ?assertEqual(
        {error, {name_taken, Name}},
        nerves_hub_link:start(config(#{firmware => none, register => Name}))
    ),

    true = unregister(Name),
    exit(Squatter, kill).

explicit_none_is_allowed_test() ->
    setup(),
    {ok, Pid} = nerves_hub_link:start(config(#{firmware => none})),
    {opened, _} = next(1000),

    Pid ! {websocket, fake_handle, connected},
    [_, _, _, <<"phx_join">>, Payload] = json:decode(next_sent()),
    %% No firmware described. What is left is what the agent says about itself.
    ?assertEqual(
        [<<"device_api_version">>, <<"meta">>], lists:sort(maps:keys(Payload))
    ),

    nerves_hub_link:stop(Pid).

rejects_a_nonsense_firmware_source_test() ->
    ?assertMatch(
        {error, {invalid_firmware_source, whatever}},
        nerves_hub_link:start(config(#{firmware => whatever}))
    ).

%% The headers the transport is opened with are the authentication: if they are
%% missing or misnamed nothing connects, and the failure is a bare 403.
passes_auth_headers_to_the_transport_test() ->
    setup(),
    {ok, Pid} = nerves_hub_link:start(config(#{})),
    {opened, TransportConfig} = next(1000),

    Headers = maps:get(headers, TransportConfig),
    Names = [Name || {Name, _} <- Headers],
    ?assertEqual(
        lists:sort([<<"x-nh-alg">>, <<"x-nh-key">>, <<"x-nh-time">>, <<"x-nh-signature">>]),
        lists:sort(Names)
    ),
    ?assertEqual(<<"nhp_key">>, proplists:get_value(<<"x-nh-key">>, Headers)),

    nerves_hub_link:stop(Pid).

joins_with_the_firmware_description_test() ->
    setup(),
    {ok, Pid} = nerves_hub_link:start(config(#{})),
    {opened, _} = next(1000),

    Pid ! {websocket, fake_handle, connected},
    [_, _, <<"device">>, <<"phx_join">>, Payload] = json:decode(next_sent()),

    ?assertEqual(<<"atomvm">>, maps:get(<<"update_tool">>, Payload)),
    ?assertEqual(<<"my_app">>, maps:get(<<"atomvm_app_name">>, Payload)),
    ?assertEqual(<<"1.2.3">>, maps:get(<<"atomvm_app_version">>, Payload)),

    nerves_hub_link:stop(Pid).

reports_progress_and_validation_test() ->
    setup(),
    {ok, Pid} = nerves_hub_link:start(config(#{})),
    {opened, _} = next(1000),

    Pid ! {websocket, fake_handle, connected},
    [JoinRef, Ref | _] = json:decode(next_sent()),
    Reply = json:encode([
        JoinRef,
        Ref,
        <<"device">>,
        <<"phx_reply">>,
        #{
            <<"status">> => <<"ok">>, <<"response">> => #{}
        }
    ]),
    Pid ! {websocket, fake_handle, {text, iolist_to_binary(Reply)}},
    {nerves_hub, {joined, _}} = next(1000),
    [_, _, <<"device">>, <<"report_network_interface">>, _] = json:decode(next_sent()),

    ok = nerves_hub_link:update_progress(Pid, 42, <<"downloading">>),
    [_, _, <<"device">>, <<"update_progress">>, Progress] = json:decode(next_sent()),
    ?assertEqual(42, maps:get(<<"value">>, Progress)),
    ?assertEqual(<<"downloading">>, maps:get(<<"stage">>, Progress)),

    ok = nerves_hub_link:firmware_validated(Pid),
    [_, _, _, <<"firmware_validated">>, _] = json:decode(next_sent()),

    ok = nerves_hub_link:update_failed(Pid, <<"flash write failed">>),
    [_, _, _, <<"status_update">>, Status] = json:decode(next_sent()),
    ?assertEqual(<<"failed">>, maps:get(<<"status">>, Status)),
    ?assertEqual(<<"flash write failed">>, maps:get(<<"reason">>, Status)),

    nerves_hub_link:stop(Pid).

%% ------------------------------------------------------------------- helpers

next(Timeout) ->
    receive
        Message -> Message
    after Timeout -> timeout
    end.

next_sent() ->
    receive
        {sent, Frame} -> Frame
    after 1000 -> erlang:error(nothing_sent)
    end.
