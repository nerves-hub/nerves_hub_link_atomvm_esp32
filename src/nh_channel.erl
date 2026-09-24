%
% SPDX-License-Identifier: Apache-2.0 OR LGPL-2.1-or-later
%

%%-----------------------------------------------------------------------------
%% @doc The Phoenix channel protocol NervesHub speaks, as a pure state machine.
%%
%% No processes, no timers, no socket. Every function takes a state and returns
%% a new state plus a list of actions for the caller to perform:
%%
%% ```
%% {send, Binary}   %% write this to the socket
%% {event, Term}    %% tell the application this happened
%% '''
%%
%% Keeping it pure is what lets the protocol be tested against a real NervesHub
%% from a desktop, over any WebSocket client, before any of it runs on a device.
%%
%% == The wire format ==
%%
%% Phoenix's v2 serializer is a five element array rather than an object:
%%
%% ```
%% [JoinRef, Ref, Topic, Event, Payload]
%% '''
%%
%% Two details are easy to get wrong and fail quietly:
%%
%% <ul>
%%   <li>The device joins the topic `<<"device">>', unqualified. NervesHub's
%%       serializer rewrites it to `device:<id>' on the way in.</li>
%%   <li>Heartbeats go to `<<"phoenix">>' with a `null' join reference, not to
%%       the device topic.</li>
%% </ul>
%%
%% == Rejoining ==
%%
%% A channel does not survive a socket reconnect. `connected/1' must be called
%% on every connection, including reconnections, and it starts a fresh join with
%% a new join reference. A client that reconnects the socket without rejoining
%% looks healthy and silently stops receiving updates.
%% @end
%%-----------------------------------------------------------------------------
-module(nh_channel).

-export([new/1, connected/1, disconnected/1, handle_text/2, heartbeat/1, joined/1]).
-export([add_topic/3, add_topic/4, join/3, push/3, push/4, joined/2, topics/1, peek_ref/1]).
-export([params/2, set_params/3]).

-export_type([state/0, action/0]).

-define(DEVICE_TOPIC, <<"device">>).
-define(PHOENIX_TOPIC, <<"phoenix">>).

%% Per topic: the join payload this channel reports, the reference its join was
%% sent with, whether the server has acknowledged it, and whether `connected/1'
%% joins it or leaves that to the caller.
-type topic_state() :: #{
    params := map(),
    join_ref := binary() | undefined,
    joined := boolean(),
    auto_join := boolean()
}.

%% One socket carrying several channels, in the order they were added, so the
%% device topic is joined first.
%%
%% `ref' is shared across all of them rather than per topic: Phoenix correlates
%% a reply by reference, and two channels numbering from 1 apiece would produce
%% two different frames carrying the same one.
-opaque state() :: #{
    ref := pos_integer(),
    topics := [{binary(), topic_state()}]
}.

-type action() :: {send, binary()} | {event, term()}.

%%-----------------------------------------------------------------------------
%% @doc A channel that has not connected yet.
%%
%% `Params' is the join payload: what the device reports about itself.
%% @end
%%-----------------------------------------------------------------------------
-spec new(map()) -> state().
new(Params) ->
    #{ref => 1, topics => [{?DEVICE_TOPIC, topic_state(Params)}]}.

topic_state(Params) ->
    topic_state(Params, true).

topic_state(Params, AutoJoin) ->
    #{params => Params, join_ref => undefined, joined => false, auto_join => AutoJoin}.

%%-----------------------------------------------------------------------------
%% @doc Register another topic to join on this socket.
%%
%% One socket carries several channels — the device topic, and `console' when
%% the application wants one. Each is joined separately and has its own join
%% reference, but they share the socket's reference counter: Phoenix correlates
%% a reply by reference, and two channels numbering from 1 apiece would produce
%% two different frames with the same reference.
%%
%% Topics keep the order they were added, so the device topic is joined first
%% and the rest follow.
%% @end
%%-----------------------------------------------------------------------------
-spec add_topic(binary(), map(), state()) -> state().
add_topic(Topic, Params, State) ->
    add_topic(Topic, Params, #{}, State).

%%-----------------------------------------------------------------------------
%% @doc As `add_topic/3', with options.
%%
%% `auto_join => false' registers a topic that `connected/1' leaves alone, for
%% one whose join has to wait for the server. The extensions topic is the case:
%% what it joins with depends on what NervesHub advertises after the device
%% join, so it is joined with `join/3' once that arrives.
%% @end
%%-----------------------------------------------------------------------------
-spec add_topic(binary(), map(), map(), state()) -> state().
add_topic(Topic, Params, Opts, #{topics := Topics} = State) ->
    AutoJoin = maps:get(auto_join, Opts, true),
    case lists:keyfind(Topic, 1, Topics) of
        false -> State#{topics => Topics ++ [{Topic, topic_state(Params, AutoJoin)}]};
        _Existing -> State
    end.

%%-----------------------------------------------------------------------------
%% @doc Join a registered topic now, with these parameters.
%%
%% The parameters are kept, so a later `connected/1' that does join the topic
%% joins it with what it last joined with.
%% @end
%%-----------------------------------------------------------------------------
-spec join(binary(), map(), state()) -> {state(), [action()]}.
join(Topic, Params, State0) ->
    case get_topic(Topic, State0) of
        undefined ->
            {State0, [{event, {unknown_topic, Topic, <<"phx_join">>}}]};
        TS ->
            State1 = put_topic(Topic, TS#{params => Params}, State0),
            join_topic(Topic, {State1, []})
    end.

%%-----------------------------------------------------------------------------
%% @doc The parameters a topic joins with, or `undefined' for an unknown topic.
%% @end
%%-----------------------------------------------------------------------------
-spec params(binary(), state()) -> map() | undefined.
params(Topic, State) ->
    case get_topic(Topic, State) of
        undefined -> undefined;
        #{params := Params} -> Params
    end.

%%-----------------------------------------------------------------------------
%% @doc Replace what a topic joins with next time, without joining it now.
%%
%% For what changes while connected and has to be right on the next join: a
%% firmware that validated after joining, say, must not rejoin claiming it has
%% not.
%% @end
%%-----------------------------------------------------------------------------
-spec set_params(binary(), map(), state()) -> state().
set_params(Topic, Params, State) ->
    case get_topic(Topic, State) of
        undefined -> State;
        TS -> put_topic(Topic, TS#{params => Params}, State)
    end.

%%-----------------------------------------------------------------------------
%% @doc Every topic registered, in join order.
%% @end
%%-----------------------------------------------------------------------------
-spec topics(state()) -> [binary()].
topics(#{topics := Topics}) ->
    [Topic || {Topic, _} <- Topics].

%%-----------------------------------------------------------------------------
%% @doc Called on every connection, including reconnections.
%% @end
%%-----------------------------------------------------------------------------
-spec connected(state()) -> {state(), [action()]}.
connected(#{topics := Topics} = State0) ->
    AutoJoined = [Topic || {Topic, #{auto_join := true}} <- Topics],
    lists:foldl(fun join_topic/2, {State0, []}, AutoJoined).

join_topic(Topic, {State0, Actions}) ->
    {Ref, State1} = next_ref(State0),
    #{params := Params} = TS = get_topic(Topic, State1),
    State2 = put_topic(Topic, TS#{join_ref => Ref, joined => false}, State1),
    {State2, Actions ++ [{send, frame(Ref, Ref, Topic, <<"phx_join">>, Params)}]}.

%%-----------------------------------------------------------------------------
%% @doc The socket went away.
%%
%% Only the join is lost. The parameters and the reference counter are kept: a
%% fresh channel would restart references at 1, and a late reply from the old
%% connection could then be mistaken for a reply to the new join.
%% @end
%%-----------------------------------------------------------------------------
-spec disconnected(state()) -> state().
disconnected(#{topics := Topics} = State) ->
    State#{
        topics => [{Topic, TS#{joined => false, join_ref => undefined}} || {Topic, TS} <- Topics]
    }.

%%-----------------------------------------------------------------------------
%% @doc Handle a text frame from the socket.
%% @end
%%-----------------------------------------------------------------------------
-spec handle_text(binary(), state()) -> {state(), [action()]}.
handle_text(Text, State) ->
    case decode(Text) of
        {ok, [JoinRef, Ref, Topic, Event, Payload]} ->
            dispatch(JoinRef, Ref, Topic, Event, Payload, State);
        error ->
            {State, [{event, {protocol_error, Text}}]}
    end.

%%-----------------------------------------------------------------------------
%% @doc A heartbeat frame. NervesHub closes a socket that stops sending these.
%% @end
%%-----------------------------------------------------------------------------
-spec heartbeat(state()) -> {state(), [action()]}.
heartbeat(State0) ->
    {Ref, State1} = next_ref(State0),
    %% Heartbeats carry no join reference and do not belong to the device topic.
    {State1, [{send, frame(null, Ref, ?PHOENIX_TOPIC, <<"heartbeat">>, #{})}]}.

%%-----------------------------------------------------------------------------
%% @doc Push an event to the device channel.
%% @end
%%-----------------------------------------------------------------------------
-spec push(binary(), map(), state()) -> {state(), [action()]}.
push(Event, Payload, State) ->
    push(?DEVICE_TOPIC, Event, Payload, State).

%%-----------------------------------------------------------------------------
%% @doc Push an event to a named topic.
%% @end
%%-----------------------------------------------------------------------------
-spec push(binary(), binary(), map(), state()) -> {state(), [action()]}.
push(Topic, Event, Payload, State0) ->
    case get_topic(Topic, State0) of
        undefined ->
            {State0, [{event, {unknown_topic, Topic, Event}}]};
        #{joined := false} ->
            {State0, [{event, {not_joined, Event}}]};
        #{joined := true, join_ref := JoinRef} ->
            {Ref, State1} = next_ref(State0),
            {State1, [{send, frame(JoinRef, Ref, Topic, Event, Payload)}]}
    end.

%%-----------------------------------------------------------------------------
%% @doc The reference the next frame will carry.
%%
%% For a caller that needs to recognise the reply to a push: read it, push, and
%% the `{reply, Topic, Ref, Status, Response}' event that answers carries it.
%% @end
%%-----------------------------------------------------------------------------
-spec peek_ref(state()) -> binary().
peek_ref(#{ref := Ref}) ->
    integer_to_binary(Ref).

%%-----------------------------------------------------------------------------
%% @doc Whether the join has been acknowledged.
%% @end
%%-----------------------------------------------------------------------------
-spec joined(state()) -> boolean().
joined(State) ->
    joined(?DEVICE_TOPIC, State).

%%-----------------------------------------------------------------------------
%% @doc Whether a named topic's join has been acknowledged.
%% @end
%%-----------------------------------------------------------------------------
-spec joined(binary(), state()) -> boolean().
joined(Topic, State) ->
    case get_topic(Topic, State) of
        undefined -> false;
        TS -> maps:get(joined, TS)
    end.

%% ------------------------------------------------------------------- internals

dispatch(JoinRef, Ref, Topic, <<"phx_reply">>, Payload, State) ->
    Status = map_get_default(<<"status">>, Payload, <<"error">>),
    Response = map_get_default(<<"response">>, Payload, #{}),

    %% A heartbeat is answered on the `phoenix' topic, which is nobody's
    %% channel, so an unknown topic is a plain reply rather than an error.
    case get_topic(Topic, State) of
        undefined ->
            {State, [{event, {reply, Status, Response}}]};
        #{joined := Joined, join_ref := TopicJoinRef} = TS ->
            CurrentJoin = JoinRef =/= null andalso JoinRef =:= TopicJoinRef,

            case {CurrentJoin, Joined, Status} of
                {true, false, <<"ok">>} ->
                    {put_topic(Topic, TS#{joined => true}, State), [
                        {event, {joined, Topic, Response}}
                    ]};
                {true, false, _} ->
                    {State, [{event, {join_error, Topic, Response}}]};
                {true, true, _} ->
                    %% A reply to something pushed during this join, which
                    %% names the push it answers.
                    {State, [{event, {reply, Topic, Ref, Status, Response}}]};
                _ ->
                    {State, [{event, {reply, Status, Response}}]}
            end
    end;
dispatch(_JoinRef, _Ref, Topic, <<"phx_error">>, Payload, State) ->
    %% The channel crashed server-side. The socket may survive, but the channel
    %% is gone until it is joined again.
    {mark_left(Topic, State), [{event, {channel_error, Payload}}]};
dispatch(_JoinRef, _Ref, Topic, <<"phx_close">>, Payload, State) ->
    {mark_left(Topic, State), [{event, {channel_closed, Payload}}]};
dispatch(_JoinRef, _Ref, Topic, Event, Payload, State) ->
    {State, [{event, {message, Topic, Event, Payload}}]}.

get_topic(Topic, #{topics := Topics}) ->
    case lists:keyfind(Topic, 1, Topics) of
        {Topic, TS} -> TS;
        false -> undefined
    end.

put_topic(Topic, TS, #{topics := Topics} = State) ->
    State#{topics => lists:keyreplace(Topic, 1, Topics, {Topic, TS})}.

mark_left(Topic, State) ->
    case get_topic(Topic, State) of
        undefined -> State;
        TS -> put_topic(Topic, TS#{joined => false}, State)
    end.

next_ref(#{ref := Ref} = State) ->
    {integer_to_binary(Ref), State#{ref => Ref + 1}}.

frame(JoinRef, Ref, Topic, Event, Payload) ->
    iolist_to_binary(json:encode([JoinRef, Ref, Topic, Event, Payload])).

decode(Text) ->
    try json:decode(Text) of
        [_, _, _, _, _] = Message -> {ok, Message};
        _ -> error
    catch
        _:_ -> error
    end.

map_get_default(Key, Map, Default) when is_map(Map) ->
    maps:get(Key, Map, Default);
map_get_default(_Key, _NotAMap, Default) ->
    Default.
