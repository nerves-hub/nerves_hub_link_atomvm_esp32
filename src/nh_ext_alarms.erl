%
% SPDX-License-Identifier: Apache-2.0 OR LGPL-2.1-or-later
%

%%-----------------------------------------------------------------------------
%% @doc The alarms extension: alarms sent as they are raised and cleared.
%%
%% The health report carries alarms too, but only when NervesHub asks for one,
%% which is hourly on an idle device: an alarm raised just after a report waits
%% an hour, and one raised and cleared between two reports is never seen. With
%% this extension the device says so when it happens.
%%
%% ```
%% server -> device   alarms:sync      {}
%% device -> server   alarms:snapshot  {"alarms": [{"alarm", "description", "raised_at"}, ..]}
%% device -> server   alarms:raised    {"alarm", "description", "raised_at"}
%% device -> server   alarms:cleared   {"alarm", "cleared_at"}
%% '''
%%
%% == Why the application still hands over a set ==
%%
%% The application's `alarms => Fun' returns everything raised right now, as it
%% does for the health report. The events come from comparing that set with the
%% previous one, so an application has one function to write and no event
%% bookkeeping, and a missed event is corrected by the next snapshot.
%%
%% == raised_at ==
%%
%% Taken when the alarm first appears and kept for as long as it stays raised:
%% every snapshot has to send the same time for it. Before the clock is set
%% there is no time to give, and the field is left out rather than sent as
%% 1970; NervesHub uses the time the message arrived.
%%
%% This module has no side effects; `nh_extensions' calls it and `nh_agent'
%% sends what it returns.
%% @end
%%-----------------------------------------------------------------------------
-module(nh_ext_alarms).

-export([new/0, update/3, snapshot/1, current/1]).

%% Name => {Description, RaisedAt}
-type raised() :: #{binary() => {binary(), binary() | undefined}}.

-export_type([raised/0]).

-spec new() -> raised().
new() -> #{}.

%%-----------------------------------------------------------------------------
%% @doc Compare the application's set with what is raised, and say what changed.
%%
%% `Current' is `#{Name => Description}'; `Now' is the time to stamp, or
%% `undefined' without a clock. An alarm whose description changed is sent as
%% raised again: NervesHub updates the description and keeps the first time.
%% @end
%%-----------------------------------------------------------------------------
-spec update(map(), raised(), binary() | undefined) -> {raised(), [{binary(), map()}]}.
update(Current, Raised, Now) ->
    Wanted = maps:from_list([
        {text(Name), text(Description)}
     || {Name, Description} <- maps:to_list(Current)
    ]),

    Cleared = [
        {<<"alarms:cleared">>, stamped(#{<<"alarm">> => Name}, <<"cleared_at">>, Now)}
     || Name <- lists:sort(maps:keys(Raised)), not maps:is_key(Name, Wanted)
    ],

    {Raised1, RaisedEvents} = lists:foldl(
        fun({Name, Description}, {Acc, Events}) ->
            case maps:get(Name, Raised, undefined) of
                {Description, _At} = Same ->
                    {Acc#{Name => Same}, Events};
                {_Other, At} ->
                    {Acc#{Name => {Description, At}}, [raised(Name, Description, At) | Events]};
                undefined ->
                    {Acc#{Name => {Description, Now}}, [raised(Name, Description, Now) | Events]}
            end
        end,
        {#{}, []},
        lists:sort(maps:to_list(Wanted))
    ),

    {Raised1, Cleared ++ lists:reverse(RaisedEvents)}.

%%-----------------------------------------------------------------------------
%% @doc Every alarm raised, as the answer to `alarms:sync'.
%% @end
%%-----------------------------------------------------------------------------
-spec snapshot(raised()) -> map().
snapshot(Raised) ->
    #{
        <<"alarms">> => [
            entry(Name, Description, At)
         || {Name, {Description, At}} <- lists:sort(maps:to_list(Raised))
        ]
    }.

%%-----------------------------------------------------------------------------
%% @doc What is raised, as the application describes it: `#{Name => Description}'.
%% @end
%%-----------------------------------------------------------------------------
-spec current(raised()) -> #{binary() => binary()}.
current(Raised) ->
    maps:map(fun(_Name, {Description, _At}) -> Description end, Raised).

%% ------------------------------------------------------------------- helpers

raised(Name, Description, At) ->
    {<<"alarms:raised">>, entry(Name, Description, At)}.

entry(Name, Description, At) ->
    stamped(#{<<"alarm">> => Name, <<"description">> => Description}, <<"raised_at">>, At).

stamped(Payload, _Key, undefined) -> Payload;
stamped(Payload, Key, At) -> Payload#{Key => At}.

%% Names and descriptions go out as strings; an application handing over an
%% atom or a charlist should not cost it the alarm.
text(Bin) when is_binary(Bin) -> Bin;
text(Atom) when is_atom(Atom) -> atom_to_binary(Atom, utf8);
text(Int) when is_integer(Int) -> integer_to_binary(Int);
text(Other) ->
    try unicode:characters_to_binary(Other) of
        Bin when is_binary(Bin) -> Bin;
        _ -> iolist_to_binary(io_lib:format("~p", [Other]))
    catch
        _:_ -> iolist_to_binary(io_lib:format("~p", [Other]))
    end.
