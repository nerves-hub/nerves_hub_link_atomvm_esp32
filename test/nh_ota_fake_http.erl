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
%%
%% `serve_cut/2' cuts each connection in turn: `{At, stall}' stops handing out
%% data after byte `At' of the body and never answers again, `{At, close}'
%% closes there. A request with `Range: bytes=N-' gets 206 and the body from
%% `N'; `ranges/0' says what each request asked for.
-module(nh_ota_fake_http).

-export([serve/1, serve/2, serve_cut/2, fail_connect/0, ranges/0, stop/0, requests/0]).
-export([connect/4, request/5, recv/2, close/1]).

-define(NAME, ?MODULE).

%% @equiv serve(Body, 200)
serve(Body) -> serve(Body, 200).

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
        honour_ranges => maps:get(ranges, Opts, true),
        cuts => [{drop, After} || After <- maps:get(drops, Opts, [])]
    }).

serve_cut(Body, Cuts) ->
    start(#{connect => ok, body => Body, status => 200, honour_ranges => true, cuts => Cuts}).

fail_connect() ->
    start(#{connect => fail, body => <<>>, status => 200, honour_ranges => true, cuts => []}).

ranges() -> call(ranges).

%% The headers of every request made, oldest first.
requests() -> call(requests).

start(State) ->
    stop(),
    register(?NAME, spawn(fun() -> loop(State#{batches => [], ranges => [], requests => []}) end)),
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
        spent ->
            {error, {ssl, closed}};
        stall ->
            receive
            after infinity -> ok
            end;
        Responses ->
            {ok, conn, Responses}
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
        {From, ranges} ->
            From ! {?NAME, maps:get(ranges, State)},
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
                [stall | _] ->
                    From ! {?NAME, stall},
                    loop(State);
                [Batch | Rest] ->
                    From ! {?NAME, Batch},
                    loop(State#{batches => Rest})
            end
    end.

respond(Headers, #{body := Body, status := Status, cuts := Cuts} = State) ->
    {Range, Start} = range(Headers),
    {Code, From} =
        case {Status, maps:get(honour_ranges, State), Start} of
            {200, true, N} when is_integer(N) -> {206, N};
            _ -> {Status, 0}
        end,
    {Cut, Later} =
        case Cuts of
            [] -> {none, []};
            [C | Cs] -> {C, Cs}
        end,
    State#{
        batches => batches(Body, Code, From, Cut),
        cuts => Later,
        ranges => maps:get(ranges, State) ++ [Range],
        requests => [Headers | maps:get(requests, State)]
    }.

range(Headers) ->
    case lists:keyfind(<<"Range">>, 1, Headers) of
        {_, Value} ->
            Bin = iolist_to_binary(Value),
            <<"bytes=", Rest/binary>> = Bin,
            [N | _] = binary:split(Rest, <<"-">>),
            {Bin, binary_to_integer(N)};
        false ->
            {none, none}
    end.

%% One batch per `recv', 1500 bytes at a time, so a 4096 byte block boundary
%% falls mid-chunk. A drop counts from where this response starts; a cut, from
%% the start of the body.
batches(Body, Status, From, none) ->
    batches(Body, Status, From, {byte_size(Body), done});
batches(Body, Status, From, {drop, After}) ->
    End = min(From + After, byte_size(Body)),
    How =
        case End =:= byte_size(Body) of
            true -> done;
            false -> close
        end,
    batches(Body, Status, From, {End, How});
batches(Body, Status, From, {At, How}) ->
    Part = binary:part(Body, From, At - From),
    head(Status) ++ [[{data, ref, Chunk}] || Chunk <- chunks(Part, 1500)] ++ ending(How).

head(Status) ->
    [[{status, ref, Status}, {header, ref, {<<"content-type">>, <<"application/octet-stream">>}}]].

ending(done) -> [[{done, ref}]];
ending(stall) -> [stall];
ending(close) -> [].

chunks(<<>>, _Size) -> [];
chunks(Bin, Size) when byte_size(Bin) =< Size -> [Bin];
chunks(<<Chunk:1500/binary, Rest/binary>>, Size) -> [Chunk | chunks(Rest, Size)].
