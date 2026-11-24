%
% SPDX-License-Identifier: Apache-2.0 OR LGPL-2.1-or-later
%

%%-----------------------------------------------------------------------------
%% @doc The geo extension.
%%
%% NervesHub asks with `geo:location:request' and the device answers with
%% `geo:location:update'. There is no GPS here, so the answer comes from a
%% GeoIP lookup against the Nerves project's `whenwhere' service — the same
%% source `nerves_hub_link' uses by default, and about as accurate as an IP
%% address ever is.
%%
%% ```
%% #{source => <<"geoip">>, latitude => -36.8869, longitude => 174.769}
%% '''
%%
%% A failed lookup is reported rather than swallowed, as
%% `#{error_code, error_description}', because a device that answers nothing
%% and a device that cannot resolve look identical from the platform.
%%
%% == A source of its own ==
%%
%% A device that knows better than its IP address — a GPS, a configured
%% position — passes `location => Fun' to the agent. `Fun()' returns the
%% payload to send, `#{<<"source">> => <<"gps">>, <<"latitude">> => ..,
%% <<"longitude">> => ..}', or `undefined' while it has none, and the lookup
%% is not made at all: no second TLS session, no request to the service.
%%
%% `undefined' sends nothing. NervesHub's device page offers to set the
%% location by hand only when it has none, and an error in its place hides
%% that: a device without a fix is better left blank than reported.
%%
%% == Running it ==
%%
%% `resolve/0' makes a network request and blocks until it finishes, so it must
%% not run on the agent's process — that process has heartbeats to send. The
%% agent spawns `start_resolve/1', which sends the result back.
%% @end
%%-----------------------------------------------------------------------------
-module(nh_ext_geo).

-export([
    start_resolve/1,
    start_resolve/2,
    resolve/0,
    resolve/1,
    located/1,
    event/0,
    default_url/0,
    parse_response/1
]).

-define(DEFAULT_URL, <<"https://whenwhere.nerves-project.org/">>).
-define(TIMEOUT, 15000).

%%-----------------------------------------------------------------------------
%% @doc The scoped event a location is sent as.
%% @end
%%-----------------------------------------------------------------------------
-spec event() -> binary().
event() -> <<"geo:location:update">>.

-spec default_url() -> binary().
default_url() -> ?DEFAULT_URL.

%%-----------------------------------------------------------------------------
%% @doc Resolve in a separate process, sending `{nh_ext_geo, Pid, Location}',
%% where `Location' is `undefined' when there is nothing to send.
%% @end
%%-----------------------------------------------------------------------------
-spec start_resolve(pid()) -> pid().
start_resolve(Owner) ->
    start_resolve(Owner, undefined).

%%-----------------------------------------------------------------------------
%% @doc Resolve from `Source', the application's `location' fun, or by GeoIP
%% when there is none.
%% @end
%%-----------------------------------------------------------------------------
-spec start_resolve(pid(), undefined | fun(() -> map() | undefined)) -> pid().
start_resolve(Owner, undefined) ->
    spawn(fun() -> Owner ! {nh_ext_geo, self(), resolve()} end);
start_resolve(Owner, Source) when is_function(Source, 0) ->
    spawn(fun() -> Owner ! {nh_ext_geo, self(), located(Source)} end).

%%-----------------------------------------------------------------------------
%% @doc The payload for what the application's `location' fun returns.
%%
%% `undefined' — no fix yet — stays `undefined', and nothing is sent: the
%% page keeps offering to set the location by hand. A fun that raises is a
%% bug rather than a missing fix, and is reported as `SOURCE_ERROR'.
%% @end
%%-----------------------------------------------------------------------------
-spec located(fun(() -> map() | undefined)) -> map() | undefined.
located(Source) ->
    try Source() of
        Location when is_map(Location) -> Location;
        undefined -> undefined;
        Other -> error_payload(<<"SOURCE_ERROR">>, {bad_location, Other})
    catch
        Class:Reason -> error_payload(<<"SOURCE_ERROR">>, {Class, Reason})
    end.

%%-----------------------------------------------------------------------------
%% @equiv resolve(default_url())
%% @end
%%-----------------------------------------------------------------------------
-spec resolve() -> map().
resolve() -> resolve(?DEFAULT_URL).

%%-----------------------------------------------------------------------------
%% @doc Ask a whenwhere-shaped service where this device is.
%% @end
%%-----------------------------------------------------------------------------
-spec resolve(binary()) -> map().
resolve(Url) ->
    case nh_ota:parse_url(Url) of
        {ok, #{protocol := Protocol, host := Host, port := Port, path := Path}} ->
            %% `ahttp_client' and the TLS underneath it raise as readily as they
            %% return an error, and a resolver that dies takes the answer with
            %% it — the device then looks identical to one that was never asked.
            try fetch(Protocol, Host, Port, Path) of
                {ok, Body} -> parse_response(Body);
                {error, Reason} -> error_payload(<<"HTTP_ERROR">>, Reason)
            catch
                Class:Reason -> error_payload(<<"HTTP_ERROR">>, {Class, Reason})
            end;
        {error, Reason} ->
            error_payload(<<"BAD_URL">>, Reason)
    end.

%%-----------------------------------------------------------------------------
%% @doc Turn a whenwhere response body into the payload NervesHub stores.
%%
%% Coordinates come back as strings and are sent as numbers where they parse:
%% the platform draws them on a map, and a string is not a coordinate. One that
%% will not parse is passed through rather than dropped, so a change at the
%% service shows up as odd data instead of no data.
%% @end
%%-----------------------------------------------------------------------------
-spec parse_response(binary()) -> map().
parse_response(Body) ->
    try json:decode(Body) of
        Decoded when is_map(Decoded) ->
            case
                {
                    maps:get(<<"latitude">>, Decoded, undefined),
                    maps:get(<<"longitude">>, Decoded, undefined)
                }
            of
                {undefined, _} ->
                    error_payload(<<"NO_LOCATION">>, no_coordinates);
                {_, undefined} ->
                    error_payload(<<"NO_LOCATION">>, no_coordinates);
                {Lat, Lon} ->
                    #{
                        <<"source">> => <<"geoip">>,
                        <<"latitude">> => number(Lat),
                        <<"longitude">> => number(Lon)
                    }
            end;
        _ ->
            error_payload(<<"BAD_RESPONSE">>, not_a_map)
    catch
        _:_ -> error_payload(<<"BAD_RESPONSE">>, undecodable)
    end.

number(Value) when is_number(Value) ->
    Value;
number(Value) when is_binary(Value) ->
    try binary_to_float(Value) of
        Float -> Float
    catch
        _:_ ->
            try binary_to_integer(Value) of
                Int -> Int
            catch
                _:_ -> Value
            end
    end;
number(Value) ->
    Value.

error_payload(Code, Reason) ->
    #{<<"error_code">> => Code, <<"error_description">> => describe(Reason)}.

describe(Reason) when is_binary(Reason) -> Reason;
describe(Reason) when is_atom(Reason) -> atom_to_binary(Reason, utf8);
%% mbedtls failures arrive as negative integers, and losing them to a catch-all
%% is what turns a diagnosable failure into "unknown".
describe(Reason) when is_integer(Reason) -> integer_to_binary(Reason);
describe(Reason) when is_tuple(Reason), tuple_size(Reason) > 0 ->
    %% Join the whole tuple rather than its head. `{ssl, closed}' and
    %% `{error, timeout}' both reduce to something useless otherwise, and this
    %% string is all the diagnosis anyone gets from the platform.
    Parts = [describe(Part) || Part <- tuple_to_list(Reason)],
    iolist_to_binary(lists:join(<<":">>, Parts));
describe(_Reason) ->
    <<"unknown">>.

%% ------------------------------------------------------------------- http

%% Passive, and not by preference. AtomVM's `ssl:connect/2' contains
%%
%%     {active, false} = proplists:lookup(active, TLSOptions)
%%
%% so asking for active mode over TLS is a badmatch inside the client rather
%% than an error it returns — the resolver dies and the device looks like one
%% that was never asked. Reading with `recv/2' is the only mode TLS supports
%% here, and it works for plain HTTP too, so both go through it.
fetch(Protocol, Host, Port, Path) ->
    ok = start_tls(Protocol),

    case ahttp_client:connect(Protocol, Host, Port, options(Protocol, Host)) of
        {ok, Conn} ->
            Headers = [{<<"accept">>, <<"application/json">>}],

            case ahttp_client:request(Conn, <<"GET">>, Path, Headers, undefined) of
                {ok, Conn2, _Ref} ->
                    Result = collect(Conn2, <<>>, undefined),
                    _ = ahttp_client:close(Conn2),
                    Result;
                {error, Reason} ->
                    _ = ahttp_client:close(Conn),
                    {error, Reason}
            end;
        {error, Reason} ->
            {error, Reason}
    end.

%% The body is a couple of hundred bytes, so it is buffered whole rather than
%% streamed the way a firmware download has to be.
collect(Conn, Body, Status) ->
    case ahttp_client:recv(Conn, 0) of
        {ok, Conn2, Responses} ->
            case fold(Responses, Body, Status) of
                {done, FinalBody, FinalStatus} -> done(FinalBody, FinalStatus);
                {continue, NextBody, NextStatus} -> collect(Conn2, NextBody, NextStatus)
            end;
        {error, {_Transport, closed}} ->
            %% A server that closes to mark the end of a body has still given
            %% us the body.
            done(Body, Status);
        {error, Reason} ->
            {error, Reason}
    end.

%% == Unverified TLS ==
%%
%% AtomVM's only verification option is `{verify, verify_none}' — its
%% `tls_client_option()' type has no way to pass CA certificates, so the server
%% certificate cannot be checked against anything. Verification is therefore
%% off, because the alternative is not "verified" but "does not connect".
%%
%% That is acceptable for exactly this: a coarse location derived from the
%% device's own public IP, which is not secret and which the device does not
%% act on. It would not be acceptable for anything the device trusted, and it
%% is why this is a location lookup and not a general HTTP client.
options(https, Host) ->
    [
        {active, false},
        {verify, verify_none},
        %% Shared hosts answer with the wrong certificate without it, and the
        %% service sits behind one.
        {server_name_indication, binary_to_list(Host)}
    ];
options(_Protocol, _Host) ->
    [{active, false}].

%% AtomVM's `ssl' is a gen_server holding the RNG state, and `ssl:connect/2'
%% calls it. Nothing starts it for you: `ahttp_client' does not, and neither
%% does the VM, so the first HTTPS request in a program exits `noproc' from
%% somewhere that reads like a bug in the request. Starting it is idempotent.
start_tls(https) ->
    try ssl:start() of
        _ -> ok
    catch
        _:_ -> ok
    end;
start_tls(_Protocol) ->
    ok.

fold([], Body, Status) ->
    {continue, Body, Status};
fold([{status, _Ref, Code} | Rest], Body, _Status) ->
    fold(Rest, Body, Code);
fold([{data, _Ref, Chunk} | Rest], Body, Status) ->
    fold(Rest, <<Body/binary, Chunk/binary>>, Status);
fold([{done, _Ref} | _Rest], Body, Status) ->
    {done, Body, Status};
fold([_Other | Rest], Body, Status) ->
    fold(Rest, Body, Status).

done(Body, 200) -> {ok, Body};
done(_Body, undefined) -> {error, no_response};
done(_Body, Status) -> {error, {http_status, Status}}.
