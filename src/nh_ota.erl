%
% SPDX-License-Identifier: Apache-2.0 OR LGPL-2.1-or-later
%

%%-----------------------------------------------------------------------------
%% @doc Applying a firmware update.
%%
%% NervesHub sends an `update' message naming a URL, a size and a SHA-256. This
%% downloads that archive into the slot the device is not running, checks it,
%% and points the boot path at it. Nothing reboots here — see `nh_slots' for the
%% slot model and `commit/0' and `revert/0' for what happens on the way back up.
%%
%% == Nothing is held in memory ==
%%
%% A packbeam is far larger than the heap an ESP32 has to spare, so the download
%% is streamed: `ahttp_client' hands back `{data, Ref, Bin}' as the socket
%% delivers it, each chunk is buffered only to a flash block, written, hashed
%% and dropped. Peak memory is one block, whatever the archive weighs.
%%
%% == What is checked, and when ==
%%
%% The digest is computed while writing rather than by reading the partition
%% back, so a download that was corrupted in flight is caught. The archive is
%% then read back from flash and walked, which catches a write that did not
%% land. Only after both does the boot path move.
%%
%% Order matters: until the boot path is written the device still boots what it
%% was running, so a failure at any earlier point costs nothing but the
%% download.
%%
%% == When the connection drops ==
%%
%% A download that fails part way is tried again, resuming from the last byte
%% received with a `Range' request, a few times with a growing pause between.
%% Only a failure another attempt would not fix — a 404, a flash write that
%% failed — ends it at once. A server that answers a `Range' request with the
%% whole archive gets it taken from the start, after erasing again.
%%
%% == On trial ==
%%
%% Arming an update puts it on trial. `begin_trial/1' counts each boot of it,
%% `commit/0' ends the trial once it has proved itself, and `revert/0' points
%% the device back at what it ran before. `nh_agent' drives all three.
%% @end
%%-----------------------------------------------------------------------------
-module(nh_ota).

-export([available/0, available/1, apply_update/1, apply_update/2]).
-export([start_update/2, start_update/3]).
-export([pending/0, pending/1, commit/0, commit/1, revert/0, revert/1]).
-export([begin_trial/1, begin_trial/2, reverted/0, reverted/1]).
-export([parse_url/1, digest_matches/2]).

%% Our own NVS namespace. `atomvm' belongs to the loader, and writing our
%% bookkeeping into it would be writing into someone else's keys.
-define(NVS_NAMESPACE, nerves_hub).
-define(NVS_PENDING, pending_slot).
-define(NVS_PREVIOUS, previous_slot).
-define(NVS_BOOT_ATTEMPTS, boot_attempts).
-define(NVS_REVERTED, reverted).

%% Buffered before each flash write. One erase sector, so writes stay aligned
%% and a chunky download does not turn into hundreds of tiny writes.
-define(BLOCK_SIZE, 4096).

%% How many times a download is tried again after the first attempt fails, and
%% how long to wait between: from the first delay, doubling to the second.
-define(DEFAULT_MAX_RETRIES, 5).
-define(DEFAULT_RETRY_BACKOFF, {2000, 30000}).

-type update_result() :: {ok, binary()} | {error, term()}.

%% The three things here that only exist on a device: flash and NVS through
%% `esp', the download through `ahttp_client', and reading back what was
%% written through `nh_flash'. Each is a module name rather than a direct call,
%% so a test can hand over one that records what it was asked to do.
%%
%% Same idiom as `transport' in `nh_agent', and for the same reason: the
%% install path is the one place in this library where a mistake writes to
%% flash, and it was the least tested because none of it could run off a board.
-define(DEFAULT_ESP, esp).
-define(DEFAULT_HTTP, ahttp_client).
-define(DEFAULT_FLASH, nh_flash).

esp(Opts) -> maps:get(esp, Opts, ?DEFAULT_ESP).
http(Opts) -> maps:get(http, Opts, ?DEFAULT_HTTP).
flash(Opts) -> maps:get(flash, Opts, ?DEFAULT_FLASH).

%%-----------------------------------------------------------------------------
%% @doc Whether this platform can write flash at all.
%% @end
%%-----------------------------------------------------------------------------
-spec available() -> boolean().
available() -> available(#{}).

%%-----------------------------------------------------------------------------
%% @doc As `available/0', against a given `esp' module.
%% @end
%%-----------------------------------------------------------------------------
-spec available(map()) -> boolean().
available(Opts) ->
    Esp = esp(Opts),
    erlang:function_exported(Esp, partition_write, 3) andalso
        erlang:function_exported(Esp, partition_erase_range, 3).

%%-----------------------------------------------------------------------------
%% @equiv apply_update(Payload, #{})
%% @end
%%-----------------------------------------------------------------------------
-spec apply_update(map()) -> update_result().
apply_update(Payload) -> apply_update(Payload, #{}).

%%-----------------------------------------------------------------------------
%% @doc Download and install an update, returning the slot it was written to.
%%
%% `Payload' is what NervesHub sends: `firmware_url', `size' and `checksum'.
%% `Opts' may carry:
%%
%% <ul>
%%   <li>`progress', a function of one argument, called with a percentage as
%%       the download proceeds</li>
%%   <li>`started', a function of none, called as each attempt begins</li>
%%   <li>`slot', to override the target</li>
%%   <li>`max_retries', how many times to try again after the first attempt
%%       fails, 5 by default</li>
%%   <li>`retry_backoff', `{FirstMs, MaxMs}' between attempts, `{2000, 30000}'
%%       by default</li>
%% </ul>
%% @end
%%-----------------------------------------------------------------------------
-spec apply_update(map(), map()) -> update_result().
apply_update(Payload, Opts) ->
    case available(Opts) of
        false ->
            {error, no_flash_access};
        true ->
            case target_slot(Opts) of
                {ok, Slot} -> download_into(Slot, Payload, Opts);
                {error, _} = Error -> Error
            end
    end.

target_slot(Opts) ->
    case maps:get(slot, Opts, undefined) of
        undefined -> nh_slots:other((flash(Opts)):boot_partition());
        Slot -> {ok, Slot}
    end.

download_into(Slot, Payload, Opts) ->
    Url = maps:get(<<"firmware_url">>, Payload, maps:get(firmware_url, Payload, undefined)),
    Size = maps:get(<<"size">>, Payload, maps:get(size, Payload, undefined)),
    Checksum = maps:get(<<"checksum">>, Payload, maps:get(checksum, Payload, undefined)),
    Progress = maps:get(progress, Opts, fun(_Percent) -> ok end),

    case parse_url(Url) of
        {ok, Parsed} ->
            case erase(Slot, Size, Opts) of
                ok -> fetch(Slot, Parsed, Size, Checksum, Progress, Opts);
                {error, _} = Error -> Error
            end;
        {error, _} = Error ->
            Error
    end.

%% Only what the archive needs, rounded up to a sector. Whatever is left of the
%% old archive beyond it is unreachable: a packbeam ends at its terminator and
%% `nh_packbeam:byte_length/1' stops there.
erase(_Slot, undefined, _Opts) ->
    {error, {missing_update_field, size}};
erase(Slot, Size, Opts) when is_integer(Size), Size > 0 ->
    Sectors = ((Size + ?BLOCK_SIZE - 1) div ?BLOCK_SIZE) * ?BLOCK_SIZE,
    try apply(esp(Opts), partition_erase_range, [Slot, 0, Sectors]) of
        ok -> ok;
        error -> {error, {erase_failed, Slot, Sectors}};
        Other -> {error, {unexpected_erase, Other}}
    catch
        _:Reason -> {error, {erase_failed, Reason}}
    end;
erase(_Slot, Size, _Opts) ->
    {error, {invalid_update_size, Size}}.

fetch(Slot, Parsed, Size, Checksum, Progress, Opts) ->
    State = #{
        slot => Slot,
        keys => maps:get(keys, Opts, []),
        opts => Opts,
        offset => 0,
        written => 0,
        buffer => <<>>,
        hash => crypto:hash_init(sha256),
        size => Size,
        progress => Progress,
        reported => -1,
        status => undefined,
        retries => 0
    },
    finish(download(Parsed, State), Slot, Checksum, Opts).

%% One attempt after another until the archive is in, a failure that another
%% attempt would not fix, or the retries run out.
%%
%% A retry carries on from the last byte received rather than starting again:
%% the hash is kept as it was, so the bytes a `Range' request returns extend
%% the same digest. On a device a download is the longest a socket is held
%% open, and restarting a few hundred kilobytes over a weak link because the
%% last few failed is how an update never finishes.
download(Parsed, #{retries := Retries, opts := Opts} = State) ->
    case attempt(Parsed, State) of
        {complete, Final} ->
            flush(Final);
        {retry, Reason, Next} ->
            Max = maps:get(max_retries, Opts, ?DEFAULT_MAX_RETRIES),
            case Retries < Max of
                true ->
                    _ = timer:sleep(retry_delay(Retries, Opts)),
                    download(Parsed, Next#{retries => Retries + 1});
                false ->
                    {error, {download_failed, Reason}}
            end;
        {error, _} = Error ->
            Error
    end.

retry_delay(Retries, Opts) ->
    {Min, Max} = maps:get(retry_backoff, Opts, ?DEFAULT_RETRY_BACKOFF),
    nh_backoff:delay(Retries, Min, Max).

attempt(
    #{protocol := Protocol, host := Host, port := Port, path := Path},
    #{opts := Opts} = State
) ->
    Http = http(Opts),
    Started = maps:get(started, Opts, fun() -> ok end),
    _ = Started(),

    %% Passive because AtomVM's `ssl' asserts `{active, false}', and verified
    %% against the bundled CAs. A tampered archive is refused regardless:
    %% `finish/4' checks the sha256 NervesHub sent over the device socket.
    case Http:connect(Protocol, Host, Port, [{active, false}, {verify, verify_peer}]) of
        {ok, Conn} ->
            case Http:request(Conn, <<"GET">>, Path, range(State), undefined) of
                {ok, Conn2, _Ref} ->
                    Result = recv_loop(Conn2, State#{status => undefined}),
                    _ = Http:close(Conn2),
                    Result;
                {error, Reason} ->
                    _ = Http:close(Conn),
                    {retry, {request_failed, Reason}, State}
            end;
        {error, Reason} ->
            {retry, {connect_failed, Reason}, State}
    end.

%% Everything received so far, whether written yet or still buffered.
received(#{offset := Offset, buffer := Buffer}) -> Offset + byte_size(Buffer).

range(State) ->
    case received(State) of
        0 -> [];
        From -> [{<<"Range">>, <<"bytes=", (integer_to_binary(From))/binary, "-">>}]
    end.

recv_loop(Conn, #{opts := Opts} = State) ->
    Http = http(Opts),

    case Http:recv(Conn, 0) of
        {ok, Conn2, Responses} ->
            case handle(Responses, State) of
                {done, Final} -> ended(Final, done);
                {continue, Next} -> recv_loop(Conn2, Next);
                Other -> Other
            end;
        %% Passive mode reports a peer close as an error even when the response
        %% was complete, which is how a body with no length ends.
        {error, {_Transport, closed}} ->
            ended(State, closed);
        {error, Reason} ->
            {retry, {stream_failed, Reason}, State}
    end.

%% The response ended. Whether that was the whole archive is a question for the
%% size NervesHub sent, not for the socket: a connection that drops cleanly
%% halfway looks exactly like one that finished.
ended(#{status := undefined} = State, How) ->
    {retry, {no_response, How}, State};
ended(#{size := Size} = State, How) when is_integer(Size) ->
    case received(State) of
        Received when Received < Size -> {retry, {incomplete, How, Received}, State};
        _ -> {complete, State}
    end;
ended(State, _How) ->
    {complete, State}.

handle([], State) ->
    {continue, State};
handle([{status, _Ref, Status} | Rest], State) ->
    case status(Status, State) of
        {ok, Next} -> handle(Rest, Next);
        Other -> Other
    end;
handle([{header, _Ref, _Header} | Rest], State) ->
    handle(Rest, State);
handle([{trailer_header, _Ref, _Header} | Rest], State) ->
    handle(Rest, State);
handle([{data, _Ref, _Chunk} | _Rest], #{status := undefined} = State) ->
    {retry, body_before_status, State};
handle([{data, _Ref, Chunk} | Rest], State) ->
    case write(Chunk, State) of
        {ok, Next} -> handle(Rest, Next);
        {error, _} = Error -> Error
    end;
handle([{done, _Ref} | _Rest], State) ->
    {done, State}.

%% 206 is the rest of the archive from where the last attempt stopped. 200 is
%% all of it: a server that ignores `Range' is allowed to, and the only thing
%% to do is start again — erasing first, since flash can only be written once
%% between erases. A 5xx may pass; anything else in the 4xx range will not,
%% and asking again only delays saying so.
status(206, State) ->
    {ok, State#{status => 206}};
status(200, State) ->
    case received(State) of
        0 -> {ok, State#{status => 200}};
        _Some -> restart(State)
    end;
status(Status, State) when Status >= 500 ->
    {retry, {http_status, Status}, State};
status(Status, _State) ->
    {error, {http_status, Status}}.

restart(#{slot := Slot, size := Size, opts := Opts} = State) ->
    case erase(Slot, Size, Opts) of
        ok ->
            {ok, State#{
                status => 200,
                offset => 0,
                written => 0,
                buffer => <<>>,
                hash => crypto:hash_init(sha256)
            }};
        {error, _} = Error ->
            Error
    end.

%% Buffer to a block, write whole blocks, keep the remainder. The hash covers
%% the bytes as they arrive, so it catches corruption in flight rather than
%% re-reading what was just written.
write(Chunk, #{buffer := Buffer, hash := Hash} = State) ->
    Combined = <<Buffer/binary, Chunk/binary>>,
    Next = State#{hash => crypto:hash_update(Hash, Chunk)},
    case emit_blocks(Combined, Next) of
        {ok, Emitted} -> {ok, report(Emitted)};
        {error, _} = Error -> Error
    end.

emit_blocks(Buffer, State) when byte_size(Buffer) < ?BLOCK_SIZE ->
    {ok, State#{buffer => Buffer}};
emit_blocks(Buffer, #{slot := Slot, offset := Offset, opts := Opts} = State) ->
    <<Block:?BLOCK_SIZE/binary, Rest/binary>> = Buffer,
    case partition_write(Slot, Offset, Block, Opts) of
        ok ->
            emit_blocks(Rest, State#{
                offset => Offset + ?BLOCK_SIZE,
                written => maps:get(written, State) + ?BLOCK_SIZE
            });
        {error, _} = Error ->
            Error
    end.

%% The tail, which will not be a whole block. Flash writes want a multiple of
%% four bytes, so it is padded; the archive's own length is what bounds it when
%% it is read back, not the partition's.
flush(#{buffer := Buffer, slot := Slot, offset := Offset, opts := Opts} = State) when
    byte_size(Buffer) > 0
->
    Padded = pad4(Buffer),
    case partition_write(Slot, Offset, Padded, Opts) of
        ok ->
            {ok, State#{
                buffer => <<>>,
                offset => Offset + byte_size(Padded),
                written => maps:get(written, State) + byte_size(Buffer)
            }};
        {error, _} = Error ->
            Error
    end;
flush(State) ->
    {ok, State}.

finish({ok, State}, Slot, Checksum, Opts) ->
    #{hash := Hash, written := Written, keys := Keys} = State,
    Digest = nh_metadata:hex(crypto:hash_final(Hash)),

    case digest_matches(Digest, Checksum) of
        true -> verify_and_arm(Slot, Written, Digest, Keys, Opts);
        false -> {error, {checksum_mismatch, Digest, Checksum}}
    end;
finish({error, _} = Error, _Slot, _Checksum, _Opts) ->
    Error.

%% Read it back before arming it. The digest proves what arrived over the wire;
%% this proves what actually landed in flash.
verify_and_arm(Slot, Written, Digest, Keys, Opts) ->
    case (flash(Opts)):read_metadata(Slot) of
        {ok, Metadata} ->
            case maps:get(avm_sha256, Metadata) of
                Digest -> check_signature(Slot, Metadata, Written, Keys, Opts);
                Other -> {error, {written_archive_mismatch, Other, Digest}}
            end;
        {error, Reason} ->
            {error, {unreadable_after_write, Reason}}
    end.

%% Configuring keys is what asks for signatures. A device with none has nothing
%% to check against and installs what NervesHub sent it; a device with keys
%% refuses anything they do not cover, including an archive carrying no
%% signature at all.
%%
%% This runs before the boot path moves, so a rejected archive sits in a slot
%% nothing boots from and the device keeps running what it had.
check_signature(Slot, Metadata, Written, [], Opts) ->
    arm(Slot, Metadata, Written, Opts);
check_signature(Slot, Metadata, Written, Keys, Opts) ->
    case (flash(Opts)):verify_signature(Slot, Keys) of
        {ok, _Key} ->
            arm(Slot, Metadata, Written, Opts);
        {error, verification_unavailable} ->
            %% Keys were configured, so signatures were asked for, and this VM
            %% cannot check them -- see `nh_signature:available/0'. Installing
            %% anyway would quietly drop the guarantee the keys were there to
            %% provide.
            {error, {signature_rejected, verification_unavailable}};
        {error, Reason} ->
            {error, {signature_rejected, Reason}}
    end.

%% The boot path moves last, and the trial markers are written before it: a
%% device that loses power between the two boots what it was already running,
%% while one that loses power after has the markers it needs to reverse the
%% move.
arm(Slot, _Metadata, _Written, Opts) ->
    Previous = (flash(Opts)):boot_partition(),

    with_ok(
        [
            fun() -> nvs_erase(?NVS_BOOT_ATTEMPTS, Opts) end,
            fun() -> nvs_put(?NVS_PREVIOUS, Previous, Opts) end,
            fun() -> nvs_put(?NVS_PENDING, Slot, Opts) end,
            fun() -> nvs_put_atomvm_boot_path(nh_slots:boot_path(Slot), Opts) end
        ],
        Slot
    ).

with_ok([], Result) ->
    {ok, Result};
with_ok([Step | Rest], Result) ->
    case Step() of
        ok -> with_ok(Rest, Result);
        {error, _} = Error -> Error
    end.

%%-----------------------------------------------------------------------------
%% @doc The slot a reboot is on trial for, if any.
%%
%% Set by an update and cleared by `commit/0'. A device that finds one here is
%% running firmware that has not yet proved itself.
%% @end
%%-----------------------------------------------------------------------------
-spec pending() -> {ok, binary()} | none.
pending() -> pending(#{}).

%%-----------------------------------------------------------------------------
%% @doc As `pending/0', against a given `esp' module.
%% @end
%%-----------------------------------------------------------------------------
-spec pending(map()) -> {ok, binary()} | none.
pending(Opts) ->
    case nvs_get(?NVS_PENDING, Opts) of
        undefined -> none;
        Slot -> {ok, Slot}
    end.

%%-----------------------------------------------------------------------------
%% @doc Accept the running firmware, so it is no longer on trial.
%%
%% Called once the device has done something that proves the update worked —
%% joining NervesHub is the evidence this library uses, because an update that
%% cannot reach the server is one nothing could recover from remotely.
%% @end
%%-----------------------------------------------------------------------------
-spec commit() -> ok | {error, term()}.
commit() -> commit(#{}).

%%-----------------------------------------------------------------------------
%% @doc As `commit/0', against a given `esp' module.
%% @end
%%-----------------------------------------------------------------------------
-spec commit(map()) -> ok | {error, term()}.
commit(Opts) ->
    Steps = [
        fun() -> nvs_erase(?NVS_PENDING, Opts) end,
        fun() -> nvs_erase(?NVS_PREVIOUS, Opts) end,
        fun() -> nvs_erase(?NVS_BOOT_ATTEMPTS, Opts) end,
        %% A firmware that proved itself is the end of whatever revert came
        %% before it, so the device stops reporting one.
        fun() -> nvs_erase(?NVS_REVERTED, Opts) end
    ],
    case with_ok(Steps, ok) of
        {ok, ok} -> ok;
        {error, _} = Error -> Error
    end.

%%-----------------------------------------------------------------------------
%% @doc Point the boot path back at the firmware that was running before.
%%
%% Does not reboot. The caller decides when, because reverting mid-flight and
%% rebooting immediately would cut off whatever it was trying to report.
%% @end
%%-----------------------------------------------------------------------------
-spec revert() -> {ok, binary()} | {error, term()}.
revert() -> revert(#{}).

%%-----------------------------------------------------------------------------
%% @doc As `revert/0', against a given `esp' module.
%% @end
%%-----------------------------------------------------------------------------
-spec revert(map()) -> {ok, binary()} | {error, term()}.
revert(Opts) ->
    case nvs_get(?NVS_PREVIOUS, Opts) of
        undefined ->
            {error, nothing_to_revert_to};
        Previous ->
            case nvs_put_atomvm_boot_path(nh_slots:boot_path(Previous), Opts) of
                ok ->
                    _ = commit(Opts),
                    %% Remembered past the reboot, so the firmware that comes
                    %% back up can tell NervesHub it is running because the
                    %% update did not work.
                    _ = nvs_put(?NVS_REVERTED, <<"1">>, Opts),
                    {ok, Previous};
                {error, _} = Error ->
                    Error
            end
    end.

%%-----------------------------------------------------------------------------
%% @doc Whether this device is running firmware it reverted to.
%%
%% True from a revert until the next update proves itself.
%% @end
%%-----------------------------------------------------------------------------
-spec reverted() -> boolean().
reverted() -> reverted(#{}).

-spec reverted(map()) -> boolean().
reverted(Opts) ->
    nvs_get(?NVS_REVERTED, Opts) =:= <<"1">>.

%%-----------------------------------------------------------------------------
%% @equiv begin_trial(MaxAttempts, #{})
%% @end
%%-----------------------------------------------------------------------------
-spec begin_trial(pos_integer()) -> none | {trial, binary(), pos_integer()} | {reverted, binary()}.
begin_trial(MaxAttempts) -> begin_trial(MaxAttempts, #{}).

%%-----------------------------------------------------------------------------
%% @doc Count this boot against firmware that is on trial.
%%
%% Called once per boot, before anything that could fail. A firmware on trial
%% gets `MaxAttempts' boots to reach NervesHub; one that has used them all is
%% reverted here, and the caller should restart the device into what it was
%% running before.
%%
%% Counting boots rather than trusting a timer is what catches the firmware
%% that crashes before any timer could fire: each crash is a boot, and the
%% count is in NVS where the crash cannot take it.
%%
%% Returns `none' for firmware that is not on trial, `{trial, Slot, Attempt}'
%% for one that has boots left, and `{reverted, Previous}' for one that had
%% none.
%% @end
%%-----------------------------------------------------------------------------
-spec begin_trial(pos_integer(), map()) ->
    none | {trial, binary(), pos_integer()} | {reverted, binary()}.
begin_trial(MaxAttempts, Opts) ->
    case pending(Opts) of
        none ->
            none;
        {ok, Slot} ->
            Attempt = boot_attempts(Opts) + 1,
            case Attempt > MaxAttempts of
                true ->
                    case revert(Opts) of
                        {ok, Previous} ->
                            {reverted, Previous};
                        {error, _} ->
                            %% Nothing to go back to. Carrying on is the only
                            %% option left, and counting further would not
                            %% change that.
                            {trial, Slot, Attempt}
                    end;
                false ->
                    _ = nvs_put(?NVS_BOOT_ATTEMPTS, integer_to_binary(Attempt), Opts),
                    {trial, Slot, Attempt}
            end
    end.

boot_attempts(Opts) ->
    case nvs_get(?NVS_BOOT_ATTEMPTS, Opts) of
        undefined ->
            0;
        Bin ->
            try binary_to_integer(Bin) of
                N when N >= 0 -> N;
                _ -> 0
            catch
                _:_ -> 0
            end
    end.

%%-----------------------------------------------------------------------------
%% @doc Run an update in its own process, reporting back to the caller.
%%
%% The download takes as long as it takes, and the agent has heartbeats to send
%% while it runs — so it does not run on the agent's process. The caller
%% receives `{nh_ota, self(), started}' each time a download attempt begins,
%% `{nh_ota, self(), {progress, Percent}}' as it goes and
%% `{nh_ota, self(), Result}' at the end.
%% @end
%%-----------------------------------------------------------------------------
-spec start_update(map(), pid()) -> pid().
start_update(Payload, Owner) ->
    start_update(Payload, Owner, #{}).

%%-----------------------------------------------------------------------------
%% @doc As `start_update/2', with options for `apply_update/2'.
%% @end
%%-----------------------------------------------------------------------------
-spec start_update(map(), pid(), map()) -> pid().
start_update(Payload, Owner, Opts) ->
    %% Monitored, not just spawned. A download that dies without sending a
    %% result would otherwise leave the agent waiting for one forever, and the
    %% platform seeing an update that started and never finished.
    {Pid, _Ref} =
        spawn_monitor(fun() ->
            Self = self(),
            Progress = fun(Percent) -> Owner ! {nh_ota, Self, {progress, Percent}} end,
            Started = fun() -> Owner ! {nh_ota, Self, started} end,
            Owner !
                {nh_ota, Self,
                    apply_update(Payload, Opts#{progress => Progress, started => Started})}
        end),

    Pid.

%%-----------------------------------------------------------------------------
%% @doc Compare a computed digest against the one NervesHub sent.
%%
%% Case insensitive: NervesHub stores a firmware checksum upper case and this
%% library works in lower case, and a comparison that failed on that alone
%% would reject every good download.
%% @end
%%-----------------------------------------------------------------------------
-spec digest_matches(binary(), binary() | undefined) -> boolean().
digest_matches(_Digest, undefined) -> false;
digest_matches(Digest, Checksum) when is_binary(Checksum) -> lower(Digest) =:= lower(Checksum);
digest_matches(_Digest, _Checksum) -> false.

lower(Bin) -> <<<<(lower_char(C))>> || <<C>> <= Bin>>.

lower_char(C) when C >= $A, C =< $Z -> C + 32;
lower_char(C) -> C.

%%-----------------------------------------------------------------------------
%% @doc Split a firmware URL into what `ahttp_client:connect/4' takes.
%%
%% Deliberately small: NervesHub hands out ordinary absolute URLs, and a full
%% URI parser is not something to carry onto a device for that.
%% @end
%%-----------------------------------------------------------------------------
-spec parse_url(binary() | string() | undefined) -> {ok, map()} | {error, term()}.
parse_url(undefined) ->
    {error, {missing_update_field, firmware_url}};
parse_url(Url) when is_list(Url) ->
    parse_url(list_to_binary(Url));
parse_url(<<"http://", Rest/binary>>) ->
    split_authority(http, 80, Rest);
parse_url(<<"https://", Rest/binary>>) ->
    split_authority(https, 443, Rest);
parse_url(Url) ->
    {error, {unsupported_url, Url}}.

split_authority(Protocol, DefaultPort, Rest) ->
    {Authority, Path} =
        case binary:match(Rest, <<"/">>) of
            {Pos, _} ->
                {binary:part(Rest, 0, Pos), binary:part(Rest, Pos, byte_size(Rest) - Pos)};
            nomatch ->
                {Rest, <<"/">>}
        end,

    case binary:split(Authority, <<":">>) of
        [Host] when byte_size(Host) > 0 ->
            {ok, #{protocol => Protocol, host => Host, port => DefaultPort, path => Path}};
        [Host, PortBin] when byte_size(Host) > 0 ->
            case port_number(PortBin) of
                {ok, Port} ->
                    {ok, #{protocol => Protocol, host => Host, port => Port, path => Path}};
                error ->
                    {error, {invalid_port, PortBin}}
            end;
        _ ->
            {error, {invalid_url_authority, Authority}}
    end.

port_number(Bin) ->
    try binary_to_integer(Bin) of
        Port when Port > 0, Port =< 65535 -> {ok, Port};
        _ -> error
    catch
        _:_ -> error
    end.

%% Percentages only, and only when one changes, so a large download does not
%% turn into hundreds of messages to the server.
report(#{size := Size, written := Written, reported := Reported, progress := Progress} = State) when
    is_integer(Size), Size > 0
->
    Percent = min(100, (Written * 100) div Size),
    case Percent > Reported of
        true ->
            _ = Progress(Percent),
            State#{reported => Percent};
        false ->
            State
    end;
report(State) ->
    State.

pad4(Bin) ->
    case byte_size(Bin) rem 4 of
        0 -> Bin;
        Rem -> <<Bin/binary, 0:((4 - Rem) * 8)>>
    end.

partition_write(Slot, Offset, Data, Opts) ->
    try apply(esp(Opts), partition_write, [Slot, Offset, Data]) of
        ok -> ok;
        error -> {error, {write_failed, Slot, Offset}};
        Other -> {error, {unexpected_write, Other}}
    catch
        _:Reason -> {error, {write_failed, Reason}}
    end.

nvs_put_atomvm_boot_path(Path, Opts) ->
    try apply(esp(Opts), nvs_set_binary, [atomvm, boot_path, Path]) of
        ok -> ok;
        Other -> {error, {boot_path_not_set, Other}}
    catch
        _:Reason -> {error, {boot_path_not_set, Reason}}
    end.

nvs_put(Key, Value, Opts) ->
    try apply(esp(Opts), nvs_set_binary, [?NVS_NAMESPACE, Key, Value]) of
        ok -> ok;
        Other -> {error, {nvs_write_failed, Key, Other}}
    catch
        _:Reason -> {error, {nvs_write_failed, Key, Reason}}
    end.

nvs_get(Key, Opts) ->
    try apply(esp(Opts), nvs_get_binary, [?NVS_NAMESPACE, Key]) of
        Value when is_binary(Value) -> Value;
        _ -> undefined
    catch
        _:_ -> undefined
    end.

%% `esp:nvs_erase_key/2' returns `ok' and does nothing when the key is not
%% there, so "already gone" needs no special case here. Anything else is a
%% failure worth reporting: swallowing it would let `commit/0' report a commit
%% that did not happen, leaving the pending marker on flash while the device
%% believes the firmware is validated.
nvs_erase(Key, Opts) ->
    try apply(esp(Opts), nvs_erase_key, [?NVS_NAMESPACE, Key]) of
        ok -> ok;
        Other -> {error, {nvs_erase_failed, Key, Other}}
    catch
        _:Reason -> {error, {nvs_erase_failed, Key, Reason}}
    end.
