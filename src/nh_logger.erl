%
% SPDX-License-Identifier: Apache-2.0 OR LGPL-2.1-or-later
%

%%-----------------------------------------------------------------------------
%% @doc A `logger' handler that sends log events to NervesHub.
%%
%% Saves an application from calling `nerves_hub_link:send_log/3' by hand, which
%% is the difference between a logging extension that gets used and one that is
%% forgotten.
%%
%% ```
%% logger_manager:start_link(#{
%%     log_level => info,
%%     logger => [
%%         {handler, default, logger_std_h, #{}},
%%         nh_logger:handler(#{level => info})
%%     ]
%% })
%% '''
%%
%% Handlers are given to `logger_manager' when it starts and there is no
%% `add_handler/3' on AtomVM, so this is arranged by the application at startup
%% rather than by the agent when it connects. Nothing starts `logger_manager'
%% on AtomVM either: an application that wants logging at all has to start it,
%% and one that does not has no handlers for this to be added to.
%%
%% == What it does not catch ==
%%
%% Only what goes through `logger'. `io:format/2', `console:print/1' and
%% Elixir's `IO.puts/1' write straight to the console and never reach a handler,
%% and a good deal of AtomVM code — including most examples — logs that way.
%%
%% Elixir has no `Logger' on AtomVM at all: `exavmlib' does not ship one, so an
%% Elixir application calls `:logger' directly and is caught by the same
%% handler. There is nothing that can be done for `IO.puts'.
%%
%% == Messages must be charlists or reports ==
%%
%% `logger:do_log/4' accepts a list or a map and raises `badarg' on anything
%% else, so a **binary message crashes the process that logged it** before any
%% handler runs. That is upstream of this module and nothing here can soften
%% it.
%%
%% It catches Elixir code in particular, where the obvious call is the one that
%% fails:
%%
%%     :logger.info("started")            %% badarg, a binary
%%     :logger.info(~c"started")          %% fine, a charlist
%%     :logger.info(#{event => started})  %% fine, a report
%%
%% Erlang code is less exposed, since a double-quoted string is already a list
%% there.
%%
%% == Finding the agent ==
%%
%% The handler is configured before the agent exists, so it looks the agent up
%% by registered name each time. Start the agent with `register => Name' to give
%% it one. Until it is registered, and after it stops, events are dropped rather
%% than queued: a device that cannot talk to NervesHub should not spend its
%% memory remembering why.
%% @end
%%-----------------------------------------------------------------------------
-module(nh_logger).

-export([log/2, handler/0, handler/1, message/1]).

-define(DEFAULT_AGENT, nerves_hub_link).

%%-----------------------------------------------------------------------------
%% @equiv handler(#{level => info})
%% @end
%%-----------------------------------------------------------------------------
-spec handler() -> tuple().
handler() -> handler(#{level => info}).

%%-----------------------------------------------------------------------------
%% @doc The entry to add to `logger_manager''s handler list.
%% @end
%%-----------------------------------------------------------------------------
%% A level is filled in when it is missing: `logger' reads it out of the handler
%% config without a default, so a handler without one takes the logger down on
%% the first message rather than at startup.
-spec handler(map()) -> tuple().
handler(Config) when is_map(Config) ->
    {handler, nerves_hub, ?MODULE, maps:merge(#{level => info}, Config)}.

%%-----------------------------------------------------------------------------
%% @doc Called by `logger' for each event this handler's level allows.
%% @end
%%-----------------------------------------------------------------------------
-spec log(map(), map()) -> ok.
log(Event, Config) ->
    case agent(Config) of
        undefined ->
            ok;
        Agent when Agent =:= self() ->
            %% The agent logging something would otherwise be asked to send it
            %% to itself while it is doing so.
            ok;
        Agent ->
            forward(Agent, Event)
    end.

forward(Agent, Event) ->
    Level = level(maps:get(level, Event, info)),
    Message = message(maps:get(msg, Event, <<>>)),
    Timestamp = maps:get(timestamp, Event, undefined),
    Meta = meta(maps:get(meta, Event, #{})),

    case nh_ext_logs:line_at(Level, Message, Meta, Timestamp) of
        {ok, Line} ->
            %% Fire and forget. A handler that blocked would stall whichever
            %% process was logging, which on a device is every process.
            Agent ! {push_extension, nh_ext_logs:event(), Line},
            ok;
        {error, _Reason} ->
            %% Before the clock is set there is no honest timestamp, and
            %% NervesHub drops a line without one anyway.
            ok
    end,
    report(Agent, Level, Event).

%% A crash is also an error report. The agent drops it unless the
%% `error_reports' extension is enabled.
report(Agent, <<"error">>, Event) ->
    case nh_ext_error_reports:from_log(Event) of
        {ok, Report} ->
            Agent ! {push_extension, nh_ext_error_reports:event(), Report},
            ok;
        ignore ->
            ok
    end;
report(_Agent, _Level, _Event) ->
    ok.

agent(Config) ->
    case maps:get(agent, Config, ?DEFAULT_AGENT) of
        Pid when is_pid(Pid) -> Pid;
        Name when is_atom(Name) -> whereis(Name);
        _Other -> undefined
    end.

level(Level) when is_atom(Level) -> atom_to_binary(Level, utf8);
level(Level) when is_binary(Level) -> Level;
level(_Level) -> <<"info">>.

%%-----------------------------------------------------------------------------
%% @doc Render a `logger' message as text.
%%
%% `logger' hands over one of three shapes, and a handler has to render all of
%% them or lose whichever it does not. Public so that `nh_console_h' renders a
%% line the same way this does.
%% @end
%%-----------------------------------------------------------------------------
-spec message(term()) -> binary().
message({string, String}) ->
    text(String);
message({report, Report}) ->
    text(io_lib:format("~p", [Report]));
%% AtomVM's logger refuses a binary message before a handler ever sees it, so
%% this shape does not arise there. It is handled anyway because the same
%% handler runs under OTP in tests, where binaries are accepted, and rendering
%% one as a term would give the term instead of the message.
message({Format, []}) when is_binary(Format) ->
    Format;
message({Format, Args}) when is_binary(Format), is_list(Args) ->
    message({binary_to_list(Format), Args});
message({Format, Args}) when is_list(Format), is_list(Args) ->
    try io_lib:format(Format, Args) of
        Rendered -> text(Rendered)
    catch
        %% A format string and arguments that do not match would otherwise take
        %% down whichever process was logging.
        _:_ -> text(io_lib:format("~p", [{Format, Args}]))
    end;
message(Other) ->
    text(io_lib:format("~p", [Other])).

text(Value) when is_binary(Value) ->
    Value;
text(Value) ->
    try iolist_to_binary(Value) of
        Binary -> Binary
    catch
        _:_ -> <<"?">>
    end.

%% Only the fields worth an index. A logger's metadata can carry anything,
%% including terms that would not survive being turned into strings.
meta(Meta) when is_map(Meta) ->
    Wanted = [module, function, line, file, pid],

    maps:from_list([
        {atom_to_binary(Key, utf8), Meta2}
     || Key <- Wanted, (Meta2 = maps:get(Key, Meta, undefined)) =/= undefined
    ]);
meta(_Meta) ->
    #{}.
