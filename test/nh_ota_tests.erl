%
% SPDX-License-Identifier: Apache-2.0 OR LGPL-2.1-or-later
%
-module(nh_ota_tests).

-include_lib("eunit/include/eunit.hrl").

unavailable_off_device_test() ->
    ?assertNot(nh_ota:available()),
    ?assertEqual({error, no_flash_access}, nh_ota:apply_update(#{})).

parse_url_splits_what_the_client_needs_test() ->
    ?assertEqual(
        {ok, #{
            protocol => http,
            host => <<"192.168.1.137">>,
            port => 4000,
            path => <<"/firmware/1/abc.avm">>
        }},
        nh_ota:parse_url(<<"http://192.168.1.137:4000/firmware/1/abc.avm">>)
    ).

parse_url_defaults_the_port_to_the_scheme_test() ->
    {ok, #{port := 80, protocol := http}} = nh_ota:parse_url(<<"http://example.com/f.avm">>),
    {ok, #{port := 443, protocol := https}} = nh_ota:parse_url(<<"https://example.com/f.avm">>).

parse_url_handles_a_bare_host_test() ->
    ?assertMatch({ok, #{path := <<"/">>}}, nh_ota:parse_url(<<"http://example.com">>)),
    ?assertMatch(
        {ok, #{path := <<"/">>, port := 8080}}, nh_ota:parse_url(<<"http://example.com:8080">>)
    ).

parse_url_keeps_the_query_string_test() ->
    {ok, #{path := Path}} = nh_ota:parse_url(<<"https://h/firmware/a.avm?sig=xyz&t=1">>),
    ?assertEqual(<<"/firmware/a.avm?sig=xyz&t=1">>, Path).

parse_url_accepts_a_string_test() ->
    ?assertMatch({ok, #{host := <<"example.com">>}}, nh_ota:parse_url("http://example.com/f.avm")).

parse_url_refuses_what_it_cannot_handle_test() ->
    ?assertEqual({error, {missing_update_field, firmware_url}}, nh_ota:parse_url(undefined)),
    ?assertMatch({error, {unsupported_url, _}}, nh_ota:parse_url(<<"ftp://example.com/f.avm">>)),
    ?assertMatch({error, {unsupported_url, _}}, nh_ota:parse_url(<<"/firmware/a.avm">>)),
    ?assertMatch({error, {invalid_port, _}}, nh_ota:parse_url(<<"http://h:0/f.avm">>)),
    ?assertMatch({error, {invalid_port, _}}, nh_ota:parse_url(<<"http://h:notaport/f.avm">>)),
    ?assertMatch({error, {invalid_url_authority, _}}, nh_ota:parse_url(<<"http:///f.avm">>)).

%% NervesHub stores a firmware checksum upper case; this library works in lower
%% case. Comparing them literally would reject every good download.
digest_matches_ignores_case_test() ->
    Lower = <<"b0f128ddca6ac62c8b95b7830acf46d2c156f6e9ef8cde41126661a969c3c8ad">>,
    Upper = <<"B0F128DDCA6AC62C8B95B7830ACF46D2C156F6E9EF8CDE41126661A969C3C8AD">>,

    ?assert(nh_ota:digest_matches(Lower, Upper)),
    ?assert(nh_ota:digest_matches(Lower, Lower)),
    ?assert(nh_ota:digest_matches(Upper, Lower)).

digest_matches_rejects_a_different_archive_test() ->
    ?assertNot(nh_ota:digest_matches(<<"aaaa">>, <<"bbbb">>)),
    ?assertNot(nh_ota:digest_matches(<<"aaaa">>, <<"aaaab">>)).

%% A missing checksum must never pass. An update NervesHub did not describe
%% fully is one to refuse, not one to install unchecked.
digest_matches_refuses_a_missing_checksum_test() ->
    ?assertNot(nh_ota:digest_matches(<<"aaaa">>, undefined)),
    ?assertNot(nh_ota:digest_matches(<<"aaaa">>, not_a_binary)).

%% ------------------------------------------------------------------ commit/0

%% `commit/0` used to be unable to fail: `nvs_erase` ended in `catch _:_ -> ok`,
%% so a device could report a commit that never happened and leave the pending
%% marker on flash while believing the firmware was validated. The agent has
%% always handled `{error, _}` here -- the branch was simply unreachable.
%%
%% There is no `esp` module on the host, so `apply` raises `undef` and this
%% exercises exactly the path that used to be swallowed.
a_commit_that_cannot_write_nvs_is_reported_test() ->
    ?assertMatch({error, {nvs_erase_failed, _Key, _Reason}}, nh_ota:commit()).

%% ============================================================================
%% The install path, off a device
%%
%% `nh_ota' reaches flash, NVS and the network through module names, so these
%% drive the whole of `apply_update/2' against fakes. Until the seam existed
%% none of this could run anywhere but a board, which is why the module that
%% writes firmware was the least tested one in the library.
%% ============================================================================

-define(SLOT, <<"alt.avm">>).

%% A body big enough to cross the 4096 byte block boundary several times and
%% end on a partial block, which is where a streaming writer goes wrong.
body() -> <<<<(X rem 256)>> || X <- lists:seq(1, 10000)>>.

digest(Bin) -> nh_metadata:hex(crypto:hash(sha256, Bin)).

opts(Extra) ->
    maps:merge(
        #{
            esp => nh_ota_fake_esp,
            http => nh_ota_fake_http,
            flash => nh_ota_fake_flash,
            slot => ?SLOT,
            %% Retries are real sleeps, and a test has no weak link to wait out.
            retry_backoff => {1, 2}
        },
        Extra
    ).

payload(Body) ->
    #{
        <<"firmware_url">> => <<"https://example.com/firmware.avm">>,
        <<"size">> => byte_size(Body),
        <<"checksum">> => digest(Body)
    }.

setup() ->
    ok = nh_ota_fake_esp:start(),
    ok = nh_ota_fake_http:serve(body()),
    ok = nh_ota_fake_flash:expect(#{avm_sha256 => digest(body())}).

cleanup(_) ->
    nh_ota_fake_esp:stop(),
    nh_ota_fake_http:stop(),
    nh_ota_fake_flash:stop().

install_test_() ->
    {setup, fun setup/0, fun cleanup/1, [
        {"the bytes written are the bytes downloaded", fun bytes_written_match/0},
        {"the slot is erased before anything is written", fun erases_first/0},
        {"the boot path moves last", fun boot_path_moves_last/0}
    ]}.

bytes_written_match() ->
    {ok, ?SLOT} = nh_ota:apply_update(payload(body()), opts(#{})),

    %% Padded to a multiple of four; the archive's own length bounds it on read.
    Written = nh_ota_fake_esp:written(),
    ?assertEqual(body(), binary:part(Written, 0, byte_size(body()))).

erases_first() ->
    %% 10000 bytes rounds up to three 4096 byte sectors.
    ?assertEqual([{?SLOT, 0, 12288}], nh_ota_fake_esp:erased()).

boot_path_moves_last() ->
    Nvs = nh_ota_fake_esp:nvs(),

    ?assertEqual(?SLOT, maps:get({nerves_hub, pending_slot}, Nvs)),
    ?assertEqual(<<"/dev/partition/by-name/alt.avm">>, maps:get({atomvm, boot_path}, Nvs)).

%% The half that matters. A download that does not match what NervesHub said it
%% would be must not reach the boot path.
a_checksum_mismatch_is_refused_test() ->
    ok = nh_ota_fake_esp:start(),
    ok = nh_ota_fake_http:serve(body()),
    ok = nh_ota_fake_flash:expect(#{avm_sha256 => digest(body())}),

    Payload = (payload(body()))#{<<"checksum">> => digest(<<"something else">>)},
    Result = nh_ota:apply_update(Payload, opts(#{})),

    cleanup(ok),
    ?assertMatch({error, {checksum_mismatch, _, _}}, Result).

%% What landed in flash is read back and compared, so a write that silently
%% dropped bytes is caught before the device is pointed at it.
a_written_archive_that_reads_back_wrong_is_refused_test() ->
    ok = nh_ota_fake_esp:start(),
    ok = nh_ota_fake_http:serve(body()),
    ok = nh_ota_fake_flash:expect(#{avm_sha256 => digest(<<"not what was written">>)}),

    Result = nh_ota:apply_update(payload(body()), opts(#{})),

    cleanup(ok),
    ?assertMatch({error, {written_archive_mismatch, _, _}}, Result).

a_failed_write_stops_the_install_test() ->
    ok = nh_ota_fake_esp:start(),
    ok = nh_ota_fake_http:serve(body()),
    ok = nh_ota_fake_flash:expect(#{avm_sha256 => digest(body())}),
    ok = nh_ota_fake_esp:fail(write),

    Result = nh_ota:apply_update(payload(body()), opts(#{})),
    Nvs = nh_ota_fake_esp:nvs(),

    cleanup(ok),
    ?assertMatch({error, {write_failed, _, _}}, Result),
    %% And nothing was armed, so the device still boots what it had.
    ?assertEqual(undefined, maps:get({atomvm, boot_path}, Nvs, undefined)).

a_refused_connection_is_an_error_not_a_crash_test() ->
    ok = nh_ota_fake_esp:start(),
    ok = nh_ota_fake_http:fail_connect(),
    ok = nh_ota_fake_flash:expect(#{}),

    Result = nh_ota:apply_update(payload(body()), opts(#{})),

    cleanup(ok),
    %% Tried again, since a refused connection is often a moment's outage, and
    %% reported once the retries are spent.
    ?assertMatch({error, {download_failed, {connect_failed, _}}}, Result).

a_non_200_response_is_refused_test() ->
    ok = nh_ota_fake_esp:start(),
    ok = nh_ota_fake_http:serve(body(), 404),
    ok = nh_ota_fake_flash:expect(#{}),

    Result = nh_ota:apply_update(payload(body()), opts(#{})),

    cleanup(ok),
    ?assertEqual({error, {http_status, 404}}, Result).

%% ------------------------------------------------------- pending/commit/revert

markers_test_() ->
    {setup, fun() -> nh_ota_fake_esp:start() end, fun(_) -> nh_ota_fake_esp:stop() end, [
        {"nothing is pending on a fresh device", fun nothing_pending/0},
        {"commit clears the markers an update left", fun commit_clears/0},
        {"revert points the boot path back", fun revert_restores/0}
    ]}.

nothing_pending() ->
    ?assertEqual(none, nh_ota:pending(#{esp => nh_ota_fake_esp})).

commit_clears() ->
    Opts = #{esp => nh_ota_fake_esp},
    ok = nh_ota_fake_esp:nvs_set_binary(nerves_hub, pending_slot, ?SLOT),
    ok = nh_ota_fake_esp:nvs_set_binary(nerves_hub, previous_slot, <<"main.avm">>),

    ?assertEqual({ok, ?SLOT}, nh_ota:pending(Opts)),
    ?assertEqual(ok, nh_ota:commit(Opts)),
    ?assertEqual(none, nh_ota:pending(Opts)).

revert_restores() ->
    Opts = #{esp => nh_ota_fake_esp},
    ok = nh_ota_fake_esp:nvs_set_binary(nerves_hub, previous_slot, <<"main.avm">>),

    ?assertEqual({ok, <<"main.avm">>}, nh_ota:revert(Opts)),
    ?assertEqual(
        <<"/dev/partition/by-name/main.avm">>,
        maps:get({atomvm, boot_path}, nh_ota_fake_esp:nvs())
    ).

%% ------------------------------------------------------------ resuming

%% A dropped connection picks up where it stopped. The second request asks for
%% the rest, and what lands in flash is still exactly the archive.
a_dropped_download_resumes_from_where_it_stopped_test() ->
    ok = nh_ota_fake_esp:start(),
    ok = nh_ota_fake_http:serve(body(), #{drops => [5000]}),
    ok = nh_ota_fake_flash:expect(#{avm_sha256 => digest(body())}),

    Result = nh_ota:apply_update(payload(body()), opts(#{})),
    Written = nh_ota_fake_esp:written(),
    Requests = nh_ota_fake_http:requests(),

    cleanup(ok),
    ?assertEqual({ok, ?SLOT}, Result),
    ?assertEqual(body(), binary:part(Written, 0, byte_size(body()))),
    ?assertMatch([[], [{<<"Range">>, <<"bytes=5000-">>}]], Requests).

%% A server may ignore `Range'. The whole archive comes back, and it has to be
%% taken from the start: the digest so far covers bytes it is about to resend.
a_server_that_ignores_range_is_taken_from_the_start_test() ->
    ok = nh_ota_fake_esp:start(),
    ok = nh_ota_fake_http:serve(body(), #{drops => [5000], ranges => false}),
    ok = nh_ota_fake_flash:expect(#{avm_sha256 => digest(body())}),

    Result = nh_ota:apply_update(payload(body()), opts(#{})),
    Written = nh_ota_fake_esp:written(),
    Erased = nh_ota_fake_esp:erased(),

    cleanup(ok),
    ?assertEqual({ok, ?SLOT}, Result),
    ?assertEqual(body(), binary:part(Written, 0, byte_size(body()))),
    %% Erased again before the rewrite, since flash cannot be written twice.
    ?assertEqual(2, length(Erased)).

a_download_that_keeps_dropping_gives_up_test() ->
    ok = nh_ota_fake_esp:start(),
    ok = nh_ota_fake_http:serve(body(), #{drops => [100, 100, 100]}),
    ok = nh_ota_fake_flash:expect(#{}),

    Result = nh_ota:apply_update(payload(body()), opts(#{max_retries => 2})),
    Nvs = nh_ota_fake_esp:nvs(),

    cleanup(ok),
    ?assertMatch({error, {download_failed, {incomplete, _, _}}}, Result),
    ?assertEqual(undefined, maps:get({atomvm, boot_path}, Nvs, undefined)).

a_server_error_is_tried_again_test() ->
    ok = nh_ota_fake_esp:start(),
    ok = nh_ota_fake_http:serve(body(), 503),
    ok = nh_ota_fake_flash:expect(#{}),

    Result = nh_ota:apply_update(payload(body()), opts(#{max_retries => 1})),
    Requests = nh_ota_fake_http:requests(),

    cleanup(ok),
    ?assertEqual({error, {download_failed, {http_status, 503}}}, Result),
    ?assertEqual(2, length(Requests)).

each_attempt_is_announced_test() ->
    ok = nh_ota_fake_esp:start(),
    ok = nh_ota_fake_http:serve(body(), #{drops => [5000]}),
    ok = nh_ota_fake_flash:expect(#{avm_sha256 => digest(body())}),

    Self = self(),
    {ok, _} = nh_ota:apply_update(
        payload(body()), opts(#{started => fun() -> Self ! attempt_started end})
    ),

    cleanup(ok),
    ?assertEqual(2, count(attempt_started)).

count(Message) ->
    receive
        Message -> 1 + count(Message)
    after 0 -> 0
    end.

%% ---------------------------------------------------------------- the trial

trial_test_() ->
    {foreach, fun() -> nh_ota_fake_esp:start() end, fun(_) -> nh_ota_fake_esp:stop() end, [
        {"firmware not on trial counts nothing", fun no_trial/0},
        {"each boot on trial is counted", fun boots_are_counted/0},
        {"out of boots, the device reverts", fun out_of_boots_reverts/0},
        {"a commit ends the trial and the revert", fun commit_ends_everything/0},
        {"a new update starts the count again", fun arming_resets_the_count/0}
    ]}.

on_trial() ->
    ok = nh_ota_fake_esp:nvs_set_binary(nerves_hub, pending_slot, ?SLOT),
    ok = nh_ota_fake_esp:nvs_set_binary(nerves_hub, previous_slot, <<"main.avm">>).

esp() -> #{esp => nh_ota_fake_esp}.

no_trial() ->
    ?assertEqual(none, nh_ota:begin_trial(3, esp())),
    ?assertNot(nh_ota:reverted(esp())).

boots_are_counted() ->
    on_trial(),
    ?assertEqual({trial, ?SLOT, 1}, nh_ota:begin_trial(3, esp())),
    ?assertEqual({trial, ?SLOT, 2}, nh_ota:begin_trial(3, esp())),
    ?assertEqual({trial, ?SLOT, 3}, nh_ota:begin_trial(3, esp())).

out_of_boots_reverts() ->
    on_trial(),
    [{trial, _, _} = nh_ota:begin_trial(2, esp()) || _ <- [1, 2]],

    ?assertEqual({reverted, <<"main.avm">>}, nh_ota:begin_trial(2, esp())),
    Nvs = nh_ota_fake_esp:nvs(),
    ?assertEqual(<<"/dev/partition/by-name/main.avm">>, maps:get({atomvm, boot_path}, Nvs)),
    %% No longer on trial, and remembering why.
    ?assertEqual(none, nh_ota:pending(esp())),
    ?assert(nh_ota:reverted(esp())).

commit_ends_everything() ->
    on_trial(),
    {trial, _, 1} = nh_ota:begin_trial(3, esp()),
    ok = nh_ota_fake_esp:nvs_set_binary(nerves_hub, reverted, <<"1">>),

    ok = nh_ota:commit(esp()),

    ?assertEqual(none, nh_ota:begin_trial(3, esp())),
    ?assertNot(nh_ota:reverted(esp())),
    ?assertEqual(
        undefined, maps:get({nerves_hub, boot_attempts}, nh_ota_fake_esp:nvs(), undefined)
    ).

arming_resets_the_count() ->
    on_trial(),
    {trial, _, 1} = nh_ota:begin_trial(3, esp()),
    {trial, _, 2} = nh_ota:begin_trial(3, esp()),

    ok = nh_ota_fake_http:serve(body()),
    ok = nh_ota_fake_flash:expect(#{avm_sha256 => digest(body())}),
    {ok, ?SLOT} = nh_ota:apply_update(payload(body()), opts(#{})),
    nh_ota_fake_http:stop(),
    nh_ota_fake_flash:stop(),

    ?assertEqual({trial, ?SLOT, 1}, nh_ota:begin_trial(3, esp())).
