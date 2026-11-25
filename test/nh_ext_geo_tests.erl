%
% SPDX-License-Identifier: Apache-2.0 OR LGPL-2.1-or-later
%
-module(nh_ext_geo_tests).

-include_lib("eunit/include/eunit.hrl").

%% A real response from whenwhere.nerves-project.org.
body() ->
    <<
        "{\"now\":\"2026-08-22T23:03:21.553Z\",\"time_zone\":\"Pacific/Auckland\","
        "\"latitude\":\"-36.88690\",\"longitude\":\"174.76900\",\"country\":\"NZ\","
        "\"country_region\":\"AUK\",\"city\":\"Auckland\",\"address\":\"182.48.134.168:56733\"}"
    >>.

event_is_the_scoped_name_test() ->
    ?assertEqual(<<"geo:location:update">>, nh_ext_geo:event()).

%% The service sends coordinates as strings; the platform draws them on a map.
coordinates_are_sent_as_numbers_test() ->
    Location = nh_ext_geo:parse_response(body()),

    ?assertEqual(<<"geoip">>, maps:get(<<"source">>, Location)),
    ?assertEqual(-36.8869, maps:get(<<"latitude">>, Location)),
    ?assertEqual(174.769, maps:get(<<"longitude">>, Location)).

%% A change at the service should show up as odd data, not as no data.
an_unparseable_coordinate_is_passed_through_test() ->
    Location = nh_ext_geo:parse_response(<<"{\"latitude\":\"north\",\"longitude\":2}">>),

    ?assertEqual(<<"north">>, maps:get(<<"latitude">>, Location)),
    ?assertEqual(2, maps:get(<<"longitude">>, Location)).

%% A device that answers nothing and one that cannot resolve look identical
%% from the platform, so the failure is reported.
a_response_without_coordinates_is_an_error_test() ->
    Location = nh_ext_geo:parse_response(<<"{\"city\":\"Auckland\"}">>),

    ?assertEqual(<<"NO_LOCATION">>, maps:get(<<"error_code">>, Location)),
    ?assert(maps:is_key(<<"error_description">>, Location)).

undecodable_json_is_an_error_test() ->
    Location = nh_ext_geo:parse_response(<<"not json at all">>),
    ?assertEqual(<<"BAD_RESPONSE">>, maps:get(<<"error_code">>, Location)).

a_bad_url_is_reported_rather_than_crashing_test() ->
    Location = nh_ext_geo:resolve(<<"ftp://example.com/">>),
    ?assertEqual(<<"BAD_URL">>, maps:get(<<"error_code">>, Location)).

the_default_is_the_nerves_project_service_test() ->
    ?assertMatch(
        {_, _}, binary:match(nh_ext_geo:default_url(), <<"whenwhere.nerves-project.org">>)
    ).

%% A GPS, say: what the application returns is what NervesHub gets.
a_location_fun_answers_without_a_lookup_test() ->
    Fix = #{<<"source">> => <<"gps">>, <<"latitude">> => -22.9163, <<"longitude">> => -47.0453},
    ?assertEqual(Fix, nh_ext_geo:located(fun() -> Fix end)).

%% Nothing to send: NervesHub's page then offers to set the location by hand,
%% which it does not over an error.
a_location_fun_without_a_fix_sends_nothing_test() ->
    ?assertEqual(undefined, nh_ext_geo:located(fun() -> undefined end)).

a_location_fun_that_raises_is_reported_test() ->
    Location = nh_ext_geo:located(fun() -> error(gone) end),
    ?assertEqual(<<"SOURCE_ERROR">>, maps:get(<<"error_code">>, Location)).

a_location_fun_returning_something_else_is_reported_test() ->
    Location = nh_ext_geo:located(fun() -> north end),
    ?assertEqual(<<"SOURCE_ERROR">>, maps:get(<<"error_code">>, Location)).

the_resolver_sends_the_fun_s_answer_back_test() ->
    Fix = #{<<"source">> => <<"gps">>, <<"latitude">> => 1.0, <<"longitude">> => 2.0},
    Pid = nh_ext_geo:start_resolve(self(), fun() -> Fix end),
    receive
        {nh_ext_geo, Pid, Location} -> ?assertEqual(Fix, Location)
    after 1000 -> ?assert(false)
    end.
