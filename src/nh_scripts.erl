%
% SPDX-License-Identifier: Apache-2.0 OR LGPL-2.1-or-later
%

%%-----------------------------------------------------------------------------
%% @doc Support scripts, run as console commands.
%%
%% NervesHub runs a support script by sending its text on the device topic and
%% waiting for the result. On Nerves the text is Elixir and `nerves_hub_link'
%% evaluates it. AtomVM has no compiler to evaluate anything with, so here a
%% script is a list of console commands, one per line, run in order:
%%
%% ```
%% # What is this device running, and how is it doing?
%% firmware
%% memory
%% net
%% '''
%%
%% Blank lines and lines starting with `#' are skipped. The first line that is
%% not a command stops the script and fails it, so a script written for Nerves
%% reports that it cannot run here rather than reporting nothing at all.
%%
%% == The wire ==
%%
%% ```
%% scripts/run  #{text, ref, timeout?}                   server -> device
%% scripts/run  #{ref, result, output, return, reason?}  device -> server
%% '''
%%
%% `result' is `completed' or `error'. The same event name carries both
%% directions, told apart by which end sent it.
%%
%% == Not rebooting ==
%%
%% `reboot' is refused in a script. NervesHub runs "connecting code" — a script
%% configured on the device, its group or its release — on every join, and a
%% reboot in it would restart the device every time it connected, with nothing
%% short of a new firmware to stop it. Rebooting is what the reboot action and
%% the console are for.
%% @end
%%-----------------------------------------------------------------------------
-module(nh_scripts).

-export([run/1, start/4, default_timeout/0, event/0]).

%% What `nerves_hub_link' waits for a script when NervesHub does not say.
-define(DEFAULT_TIMEOUT, 10000).

-spec event() -> binary().
event() -> <<"scripts/run">>.

-spec default_timeout() -> pos_integer().
default_timeout() -> ?DEFAULT_TIMEOUT.

%%-----------------------------------------------------------------------------
%% @doc Run a script in its own process, sending back `{nh_scripts, Ref, Result}'.
%%
%% A command can block — `geo' makes a network request — and the agent has
%% heartbeats to send, so scripts do not run on it. `Keys' are the firmware
%% keys, which `signature' reports on and which live in the agent's process
%% dictionary rather than anywhere a new process could see them.
%% @end
%%-----------------------------------------------------------------------------
-spec start(binary(), binary(), pid(), [binary()]) -> pid().
start(Ref, Text, Owner, Keys) ->
    {Pid, _Monitor} =
        spawn_monitor(fun() ->
            _ = erlang:put(nh_firmware_keys, Keys),
            Owner ! {nh_scripts, Ref, run(Text)}
        end),
    Pid.

%%-----------------------------------------------------------------------------
%% @doc Run a script, returning the payload to answer with, less its `ref'.
%% @end
%%-----------------------------------------------------------------------------
-spec run(binary()) -> map().
run(Text) when is_binary(Text) ->
    run_lines(commands(Text), [], 0);
run(_NotText) ->
    failed(<<"script text is not a string">>, []).

run_lines([], Output, 0) ->
    %% Nothing ran. On Nerves an empty script evaluates to `nil', and NervesHub
    %% counts connecting code that returns `nil' as not having worked.
    completed(<<"nil">>, Output);
run_lines([], Output, _Ran) ->
    completed(<<"ok">>, Output);
run_lines([Line | Rest], Output, Ran) ->
    Echo = <<"> ", Line/binary, "\n">>,
    case nh_console:parse(Line) of
        {<<"reboot">>, _Args} ->
            failed(<<"reboot is not allowed in a script">>, [Echo | Output]);
        _ ->
            case nh_console:run_command(Line) of
                {ok, Result} ->
                    run_lines(Rest, [plain(Result), Echo | Output], Ran + 1);
                {error, Result} ->
                    failed(<<"unknown command">>, [plain(Result), Echo | Output])
            end
    end.

completed(Return, Output) ->
    #{
        <<"result">> => <<"completed">>,
        <<"output">> => output(Output),
        <<"return">> => Return
    }.

failed(Reason, Output) ->
    #{
        <<"result">> => <<"error">>,
        <<"reason">> => Reason,
        <<"output">> => output(Output),
        <<"return">> => <<>>
    }.

output(Reversed) ->
    iolist_to_binary(lists:reverse(Reversed)).

%% The lines worth running, trimmed, in order.
commands(Text) ->
    %% One separator rather than a list of them: AtomVM's `binary:split/3'
    %% is not one to rely on for alternatives.
    Unix = binary:replace(
        binary:replace(Text, <<"\r\n">>, <<"\n">>, [global]), <<"\r">>, <<"\n">>, [global]
    ),
    Lines = binary:split(Unix, <<"\n">>, [global]),
    [
        Trimmed
     || Line <- Lines,
        (Trimmed = trim(Line)) =/= <<>>,
        binary:first(Trimmed) =/= $#
    ].

trim(Line) ->
    case nh_console:parse(Line) of
        empty -> <<>>;
        {Command, Args} -> iolist_to_binary([Command | [[$\s, Arg] || Arg <- Args]])
    end.

%% The console writes for a terminal. NervesHub shows script output in a page,
%% where a carriage return is noise.
plain(Text) ->
    binary:replace(Text, <<"\r\n">>, <<"\n">>, [global]).
