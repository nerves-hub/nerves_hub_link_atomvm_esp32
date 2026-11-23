-module(atomvm_calls_tests).

%% The tests run on the BEAM, which has every function OTP has. A device runs
%% AtomVM, which does not, and a call to one it lacks is an `undef' crash that
%% no test here would see. This keeps out the ones known to be missing, so the
%% same mistake is not made twice.

-include_lib("eunit/include/eunit.hrl").

%% {Module, Function, Arity}, with '_' for any function or any arity.
-define(MISSING, [
    {maps, without, 2},
    {persistent_term, '_', '_'}
]).

no_call_to_a_function_atomvm_lacks_test() ->
    ?assertEqual([], [
        {Mod, Call}
     || Mod <- modules(), Call <- lists:usort(calls(Mod)), missing(Call)
    ]).

modules() ->
    Ebin = filename:dirname(code:which(nh_agent)),
    App = filename:join(Ebin, "nerves_hub_link_atomvm_esp32.app"),
    {ok, [{application, _, Props}]} = file:consult(App),
    proplists:get_value(modules, Props).

calls(Mod) ->
    {ok, {Mod, [{abstract_code, {raw_abstract_v1, Forms}}]}} =
        beam_lib:chunks(code:which(Mod), [abstract_code]),
    walk(Forms, []).

walk({call, _, {remote, _, {atom, _, M}, {atom, _, F}}, Args} = _Call, Acc) ->
    walk(Args, [{M, F, length(Args)} | Acc]);
walk({'fun', _, {function, {atom, _, M}, {atom, _, F}, {integer, _, A}}}, Acc) ->
    [{M, F, A} | Acc];
walk(Term, Acc) when is_tuple(Term) ->
    walk(tuple_to_list(Term), Acc);
walk([H | T], Acc) ->
    walk(T, walk(H, Acc));
walk(_, Acc) ->
    Acc.

missing({M, F, A}) ->
    lists:any(
        fun({M1, F1, A1}) ->
            M1 =:= M andalso (F1 =:= '_' orelse F1 =:= F) andalso (A1 =:= '_' orelse A1 =:= A)
        end,
        ?MISSING
    ).
