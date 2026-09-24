%
% SPDX-License-Identifier: Apache-2.0 OR LGPL-2.1-or-later
%

%% @doc An `ahttp_client' that serves a binary from memory.
%%
%% `nh_ota' drives the download with `connect', `request' and then `recv', so
%% this hands back one batch of responses per call. The body is handed out in
%% chunks to exercise buffering across block boundaries, which is where a
%% streaming writer goes wrong.
%%
%% It can also misbehave the ways a real download does: drop the connection
%% part way (`drops'), or ignore a `Range' request and send everything again
%% (`ranges => false'). Every request's headers are kept, so a test can see
%% what was asked for.
-module(nh_ota_fake_http).

-export([serve/1, serve/2, fail_connect/0, stop/0, requests/0]).
-export([connect/4, request/5, recv/2, close/1]).

-define(NAME, ?MODULE).

%% @equiv serve(Body, 200)
serve(Body) -> serve(Body, #{}).

%% `Opts' is a status code, or a map of:
%%   status  what to answer with, 200 by default
%%   ranges  whether to honour `Range', true by default
%%   drops   bytes after which each successive response is cut off, e.g.
%%           [5000] cuts the first response after 5000 bytes of body
serve(Body, Status) when is_integer(Status) ->
    serve(Body, #{status => Status});
serve(Body, Opts) when is_map(Opts) ->
    start(#{
        connect => ok,
        body => Body,
        status => maps:get(status, Opts, 200),
        ranges => maps:get(ranges, Opts, true),
        drops => maps:get(drops, Opts, []),
        batches => [],
        requests => []
    }).

fail_connect() ->
    start(#{connect => fail, batches => [], requests => []}).

start(State) ->
    stop(),
    register(?NAME, spawn(fun() -> loop(State) end)),
    ok.

stop() ->
    case whereis(?NAME) of
        undefined ->
            ok;
        Pid ->
            Pid ! stop,
            timer:sleep(1),
            ok
    end.

%% The headers of every request made, oldest first.
requests() -> call(requests).

%% ----------------------------------------------- the `ahttp_client' interface

connect(_Protocol, _Host, _Port, _Opts) ->
    case call(connect) of
        ok -> {ok, conn};
        fail -> {error, refused}
    end.

request(Conn, _Method, _Path, Headers, _Body) ->
    ok = call({request, Headers}),
    {ok, Conn, ref}.

%% A spent body reports the peer close, which is what passive mode gives a
%% caller in place of active mode's `closed' response.
recv(_Conn, _Len) ->
    case call(next) of
        spent -> {error, {ssl, closed}};
        Responses -> {ok, conn, Responses}
    end.

close(_Conn) -> ok.

%% ------------------------------------------------------------------ internals

call(Message) ->
    ?NAME ! {self(), Message},
    receive
        {?NAME, Reply} -> Reply
    after 1000 -> error(fake_http_timeout)
    end.

loop(State) ->
    receive
        stop ->
            ok;
        {From, connect} ->
            From ! {?NAME, maps:get(connect, State)},
            loop(State);
        {From, requests} ->
            From ! {?NAME, lists:reverse(maps:get(requests, State))},
            loop(State);
        {From, {request, Headers}} ->
            From ! {?NAME, ok},
            loop(respond(Headers, State));
        {From, next} ->
            case maps:get(batches, State) of
                [] ->
                    From ! {?NAME, spent},
                    loop(State);
                [Batch | Rest] ->
                    From ! {?NAME, Batch},
                    loop(State#{batches => Rest})
            end
    end.

respond(Headers, #{body := Body, status := Status, ranges := Ranges, drops := Drops} = State) ->
    From = range_start(Headers),
    {Code, Served} =
        case {Status, Ranges, From} of
            {200, true, N} when N > 0 -> {206, binary:part(Body, N, byte_size(Body) - N)};
            _ -> {Status, Body}
        end,

    {Sent, Ending, RestDrops} =
        case Drops of
            [After | More] when After < byte_size(Served) ->
                %% Cut off: no `done', so the next `recv' finds the peer gone.
                {binary:part(Served, 0, After), [], More};
            [_ | More] ->
                {Served, [[{done, ref}]], More};
            [] ->
                {Served, [[{done, ref}]], []}
        end,

    Batches =
        [[{status, ref, Code}, {header, ref, {<<"content-type">>, <<"application/octet-stream">>}}]] ++
            [[{data, ref, Chunk}] || Chunk <- chunks(Sent, 1500)] ++ Ending,

    State#{
        batches => Batches,
        drops => RestDrops,
        requests => [Headers | maps:get(requests, State)]
    }.

range_start(Headers) ->
    case lists:keyfind(<<"Range">>, 1, Headers) of
        {_, <<"bytes=", Spec/binary>>} ->
            [From | _] = binary:split(Spec, <<"-">>),
            binary_to_integer(From);
        false ->
            0
    end.

%% One batch per `recv', 1500 bytes at a time, so a 4096 byte block boundary
%% falls mid-chunk.
chunks(<<>>, _Size) -> [];
chunks(Bin, Size) when byte_size(Bin) =< Size -> [Bin];
chunks(<<Chunk:1500/binary, Rest/binary>>, Size) -> [Chunk | chunks(Rest, Size)].
