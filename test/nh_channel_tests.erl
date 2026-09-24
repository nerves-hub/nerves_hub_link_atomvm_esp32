%
% SPDX-License-Identifier: Apache-2.0 OR LGPL-2.1-or-later
%
-module(nh_channel_tests).

-include_lib("eunit/include/eunit.hrl").

params() ->
    #{
        <<"update_tool">> => <<"esp-idf">>,
        <<"esp_idf_project_name">> => <<"my_app">>,
        <<"esp_idf_version">> => <<"1.2.3">>
    }.

decode_frame(Binary) ->
    json:decode(Binary).

join_frame_test() ->
    {State, Actions} = nh_channel:connected(nh_channel:new(params())),

    ?assertMatch([{send, _}], Actions),
    [{send, Frame}] = Actions,

    [JoinRef, Ref, Topic, Event, Payload] = decode_frame(Frame),

    %% Unqualified: NervesHub's serializer rewrites this to device:<id>.
    ?assertEqual(<<"device">>, Topic),
    ?assertEqual(<<"phx_join">>, Event),
    ?assertEqual(params(), Payload),
    %% A join uses the same value for both references.
    ?assertEqual(JoinRef, Ref),
    ?assertNotEqual(null, JoinRef),

    ?assertNot(nh_channel:joined(State)).

heartbeat_frame_test() ->
    {_State, [{send, Frame}]} = nh_channel:heartbeat(nh_channel:new(params())),

    [JoinRef, _Ref, Topic, Event, Payload] = decode_frame(Frame),

    %% Heartbeats belong to "phoenix" with no join reference, not to the device
    %% topic. Sending them on the device topic is accepted by nothing.
    ?assertEqual(null, JoinRef),
    ?assertEqual(<<"phoenix">>, Topic),
    ?assertEqual(<<"heartbeat">>, Event),
    ?assertEqual(#{}, Payload).

join_reply_marks_joined_test() ->
    {State0, [{send, Frame}]} = nh_channel:connected(nh_channel:new(params())),
    [JoinRef, Ref, _, _, _] = decode_frame(Frame),

    Reply = reply_frame(JoinRef, Ref, <<"ok">>, #{}),
    {State1, Actions} = nh_channel:handle_text(Reply, State0),

    ?assert(nh_channel:joined(State1)),
    ?assertMatch([{event, {joined, <<"device">>, #{}}}], Actions).

join_error_is_not_joined_test() ->
    {State0, [{send, Frame}]} = nh_channel:connected(nh_channel:new(params())),
    [JoinRef, Ref, _, _, _] = decode_frame(Frame),

    Reply = reply_frame(JoinRef, Ref, <<"error">>, #{<<"reason">> => <<"nope">>}),
    {State1, Actions} = nh_channel:handle_text(Reply, State0),

    ?assertNot(nh_channel:joined(State1)),
    ?assertMatch([{event, {join_error, <<"device">>, #{<<"reason">> := <<"nope">>}}}], Actions).

%% A reply carrying a stale join reference must not be mistaken for the current
%% join. Reconnecting produces a new join reference, and a late reply from the
%% previous connection would otherwise mark a channel joined that is not.
stale_join_reply_is_ignored_test() ->
    {State0, _} = nh_channel:connected(nh_channel:new(params())),
    {State1, [{send, Frame}]} = nh_channel:connected(State0),
    [CurrentJoinRef, Ref, _, _, _] = decode_frame(Frame),

    Stale = reply_frame(<<"999">>, Ref, <<"ok">>, #{}),
    {State2, Actions} = nh_channel:handle_text(Stale, State1),

    ?assertNotEqual(<<"999">>, CurrentJoinRef),
    ?assertNot(nh_channel:joined(State2)),
    ?assertMatch([{event, {reply, <<"ok">>, #{}}}], Actions).

server_message_is_surfaced_test() ->
    {State, _} = joined_channel(),

    Update = json_frame(<<"1">>, null, <<"device">>, <<"update">>, #{
        <<"firmware_url">> => <<"https://example.com/fw.bin">>
    }),
    {_State1, Actions} = nh_channel:handle_text(Update, State),

    ?assertMatch(
        [{event, {message, <<"device">>, <<"update">>, #{<<"firmware_url">> := _}}}],
        Actions
    ).

push_requires_a_join_test() ->
    State = nh_channel:new(params()),
    {_, Actions} = nh_channel:push(<<"status_update">>, #{}, State),
    ?assertMatch([{event, {not_joined, <<"status_update">>}}], Actions).

push_after_join_test() ->
    {State, _} = joined_channel(),
    {_State1, [{send, Frame}]} = nh_channel:push(
        <<"update_progress">>, #{<<"value">> => 42}, State
    ),

    [_JoinRef, _Ref, Topic, Event, Payload] = decode_frame(Frame),
    ?assertEqual(<<"device">>, Topic),
    ?assertEqual(<<"update_progress">>, Event),
    ?assertEqual(#{<<"value">> => 42}, Payload).

refs_are_unique_test() ->
    State0 = nh_channel:new(params()),
    {State1, [{send, F1}]} = nh_channel:connected(State0),
    {State2, [{send, F2}]} = nh_channel:heartbeat(State1),
    {_State3, [{send, F3}]} = nh_channel:heartbeat(State2),

    Refs = [ref_of(F) || F <- [F1, F2, F3]],
    ?assertEqual(length(Refs), length(lists:usort(Refs))).

phx_error_clears_joined_test() ->
    {State, _} = joined_channel(),
    Frame = json_frame(<<"1">>, null, <<"device">>, <<"phx_error">>, #{}),
    {State1, Actions} = nh_channel:handle_text(Frame, State),

    ?assertNot(nh_channel:joined(State1)),
    ?assertMatch([{event, {channel_error, #{}}}], Actions).

garbage_does_not_crash_test() ->
    State = nh_channel:new(params()),
    {State1, Actions} = nh_channel:handle_text(<<"not json at all">>, State),
    ?assertEqual(State, State1),
    ?assertMatch([{event, {protocol_error, _}}], Actions).

%% ------------------------------------------------------------------- helpers

joined_channel() ->
    {State0, [{send, Frame}]} = nh_channel:connected(nh_channel:new(params())),
    [JoinRef, Ref, _, _, _] = decode_frame(Frame),
    {State1, _} = nh_channel:handle_text(reply_frame(JoinRef, Ref, <<"ok">>, #{}), State0),
    {State1, JoinRef}.

reply_frame(JoinRef, Ref, Status, Response) ->
    json_frame(JoinRef, Ref, <<"device">>, <<"phx_reply">>, #{
        <<"status">> => Status,
        <<"response">> => Response
    }).

json_frame(JoinRef, Ref, Topic, Event, Payload) ->
    iolist_to_binary(json:encode([JoinRef, Ref, Topic, Event, Payload])).

ref_of(Frame) ->
    [_JoinRef, Ref, _, _, _] = decode_frame(Frame),
    Ref.

%% ------------------------------------------------------------------ topics

with_console() ->
    nh_channel:add_topic(<<"console">>, #{}, nh_channel:new(params())).

reply(JoinRef, Topic, Status) ->
    iolist_to_binary(
        json:encode([
            JoinRef,
            JoinRef,
            Topic,
            <<"phx_reply">>,
            #{<<"status">> => Status, <<"response">> => #{}}
        ])
    ).

topics_keep_their_order_test() ->
    ?assertEqual([<<"device">>, <<"console">>], nh_channel:topics(with_console())).

adding_a_topic_twice_registers_it_once_test() ->
    State = nh_channel:add_topic(<<"console">>, #{}, with_console()),
    ?assertEqual([<<"device">>, <<"console">>], nh_channel:topics(State)).

connecting_joins_every_topic_test() ->
    {_State, Actions} = nh_channel:connected(with_console()),

    Topics = [lists:nth(3, decode_frame(F)) || {send, F} <- Actions],
    ?assertEqual([<<"device">>, <<"console">>], Topics),

    Events = [lists:nth(4, decode_frame(F)) || {send, F} <- Actions],
    ?assertEqual([<<"phx_join">>, <<"phx_join">>], Events).

%% Phoenix correlates a reply by reference. Two channels each numbering from 1
%% would put the same reference on two different frames.
join_references_are_unique_across_topics_test() ->
    {_State, Actions} = nh_channel:connected(with_console()),
    Refs = [lists:nth(1, decode_frame(F)) || {send, F} <- Actions],

    ?assertEqual(2, length(Refs)),
    ?assertEqual(2, length(lists:usort(Refs))).

%% A reply belongs to one channel. Marking them all joined would let a push go
%% out on a topic the server never accepted.
a_reply_joins_only_its_own_topic_test() ->
    {State0, Actions} = nh_channel:connected(with_console()),
    [DeviceFrame, _ConsoleFrame] = [F || {send, F} <- Actions],
    [DeviceJoinRef | _] = decode_frame(DeviceFrame),

    {State1, Events} = nh_channel:handle_text(reply(DeviceJoinRef, <<"device">>, <<"ok">>), State0),

    ?assertMatch([{event, {joined, <<"device">>, _}}], Events),
    ?assert(nh_channel:joined(<<"device">>, State1)),
    ?assertNot(nh_channel:joined(<<"console">>, State1)).

pushing_to_an_unjoined_topic_is_refused_test() ->
    {State0, Actions} = nh_channel:connected(with_console()),
    [DeviceFrame | _] = [F || {send, F} <- Actions],
    [DeviceJoinRef | _] = decode_frame(DeviceFrame),
    {State1, _} = nh_channel:handle_text(reply(DeviceJoinRef, <<"device">>, <<"ok">>), State0),

    {_State2, Refused} = nh_channel:push(<<"console">>, <<"up">>, #{}, State1),
    ?assertMatch([{event, {not_joined, <<"up">>}}], Refused).

pushing_to_a_topic_that_was_never_added_test() ->
    {_State, Events} = nh_channel:push(<<"nope">>, <<"up">>, #{}, with_console()),
    ?assertMatch([{event, {unknown_topic, <<"nope">>, <<"up">>}}], Events).

console_push_carries_the_console_join_ref_test() ->
    {State0, Actions} = nh_channel:connected(with_console()),
    [_DeviceFrame, ConsoleFrame] = [F || {send, F} <- Actions],
    [ConsoleJoinRef | _] = decode_frame(ConsoleFrame),

    {State1, _} = nh_channel:handle_text(reply(ConsoleJoinRef, <<"console">>, <<"ok">>), State0),
    {_State2, [{send, Frame}]} = nh_channel:push(
        <<"console">>, <<"up">>, #{<<"data">> => <<"hi">>}, State1
    ),

    [JoinRef, Ref, Topic, Event, Payload] = decode_frame(Frame),
    ?assertEqual(ConsoleJoinRef, JoinRef),
    ?assertNotEqual(JoinRef, Ref),
    ?assertEqual(<<"console">>, Topic),
    ?assertEqual(<<"up">>, Event),
    ?assertEqual(#{<<"data">> => <<"hi">>}, Payload).

%% The socket going away takes every channel with it.
disconnecting_leaves_every_topic_test() ->
    {State0, Actions} = nh_channel:connected(with_console()),
    Frames = [F || {send, F} <- Actions],
    State1 =
        lists:foldl(
            fun(F, Acc) ->
                [JoinRef, _, Topic | _] = decode_frame(F),
                {Next, _} = nh_channel:handle_text(reply(JoinRef, Topic, <<"ok">>), Acc),
                Next
            end,
            State0,
            Frames
        ),

    ?assert(nh_channel:joined(<<"device">>, State1)),
    ?assert(nh_channel:joined(<<"console">>, State1)),

    State2 = nh_channel:disconnected(State1),
    ?assertNot(nh_channel:joined(<<"device">>, State2)),
    ?assertNot(nh_channel:joined(<<"console">>, State2)).

%% A heartbeat is answered on `phoenix', which is nobody's channel.
a_heartbeat_reply_is_not_a_join_test() ->
    {State0, _} = nh_channel:connected(with_console()),
    Frame = iolist_to_binary(
        json:encode([
            null,
            <<"7">>,
            <<"phoenix">>,
            <<"phx_reply">>,
            #{<<"status">> => <<"ok">>, <<"response">> => #{}}
        ])
    ),

    {State1, Events} = nh_channel:handle_text(Frame, State0),
    ?assertMatch([{event, {reply, <<"ok">>, _}}], Events),
    ?assertNot(nh_channel:joined(<<"device">>, State1)).

%% ------------------------------------------------------ joining on request

a_manual_topic_waits_to_be_joined_test() ->
    State0 = nh_channel:add_topic(
        <<"extensions">>, #{}, #{auto_join => false}, nh_channel:new(params())
    ),
    {State1, Actions} = nh_channel:connected(State0),
    ?assertEqual([<<"device">>], [T || {send, F} <- Actions, [_, _, T, _, _] <- [decode_frame(F)]]),

    {_State2, [{send, Frame}]} = nh_channel:join(
        <<"extensions">>, #{<<"health">> => <<"0.0.1">>}, State1
    ),
    ?assertMatch(
        [_, _, <<"extensions">>, <<"phx_join">>, #{<<"health">> := <<"0.0.1">>}],
        decode_frame(Frame)
    ).

%% A reply to a push names the push, so a caller can tell which one failed.
a_reply_to_a_push_carries_its_ref_test() ->
    {State0, _} = joined_channel(),
    Ref = nh_channel:peek_ref(State0),
    {State1, [{send, Push}]} = nh_channel:push(<<"health:report">>, #{}, State0),
    [JoinRef, Ref, _, _, _] = decode_frame(Push),

    {_State2, Actions} = nh_channel:handle_text(
        reply_frame(JoinRef, Ref, <<"error">>, <<"detach">>), State1
    ),
    ?assertEqual([{event, {reply, <<"device">>, Ref, <<"error">>, <<"detach">>}}], Actions).

set_params_changes_the_next_join_test() ->
    State0 = nh_channel:set_params(<<"device">>, #{<<"a">> => 1}, nh_channel:new(params())),
    ?assertEqual(#{<<"a">> => 1}, nh_channel:params(<<"device">>, State0)),
    {_State1, [{send, Frame}]} = nh_channel:connected(State0),
    ?assertMatch([_, _, _, _, #{<<"a">> := 1}], decode_frame(Frame)).
