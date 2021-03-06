% Copyright 2010-2014, Travelping GmbH <info@travelping.com>

% Permission is hereby granted, free of charge, to any person obtaining a
% copy of this software and associated documentation files (the "Software"),
% to deal in the Software without restriction, including without limitation
% the rights to use, copy, modify, merge, publish, distribute, sublicense,
% and/or sell copies of the Software, and to permit persons to whom the
% Software is furnished to do so, subject to the following conditions:

% The above copyright notice and this permission notice shall be included in
% all copies or substantial portions of the Software.

% THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
% IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
% FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
% AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
% LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
% FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
% DEALINGS IN THE SOFTWARE.

-module(ejournald).
-behaviour(application).

-include("internal.hrl").

-export([start/2, stop/1]).
-export([start_io/1, start_io/2, stop_io/1,
         start_reader/1, start_reader/2, stop_reader/1,
         get_logs/1, get_logs/2
        ]).
-export([log_notify/2, stop_log_notify/1]).

-define(READER, ejournald_reader).
-define(IO_SERVER, ejournald_io_server).
-define(NOTIFIER, ejournald_notifier).

%% ----------------------------------------------------------------------------------------------------
%% -- types
-type log_level()       ::  emergency | 
                            alert |
                            critical |
                            error | 
                            warning | 
                            notice | 
                            info |
                            debug.

-type erl_opts()        ::  erlang_node |
                            application |
                            code_file |
                            function.

-type reader_options()  ::  {dir, string()}.
                            
-type io_options()      ::  {name, string()} |
                            {log_level, log_level()} |
                            {level_prefix, string()}.

-type log_options()     ::  {direction, direction()} |
                            {since, datetime1970()} |
                            {until, datetime1970()} |
                            {at_most, integer()} |
                            {log_level, log_level()} |
                            {message, boolean()} |
                            {regex, iodata()} |     %% must be compatible with the erlang re module
                            {erl_opts(), atom()}.

-type notify_options()  ::  {message, boolean()} |
                            {regex, iodata()} |
                            {log_level, log_level()} |
                            {dir, list()} |
                            {erl_opts(), atom()}.

-type direction()       ::  ascending | descending.
-type datetime1970()    ::  calendar:datetime1970().
-type sink_fun()        ::  fun( (log_message()) -> any() ).
-type sink()            ::  pid() | sink_fun().
-type log_data()        ::  string() | [ string() ]. %% depends on the 'message' option
-type log_message()     ::  {datetime1970(), log_level(), log_data()} |
                            {'EXIT', pid(), atom()} |
                            journal_invalidate.
-type id()              ::  term() | pid().

%% ----------------------------------------------------------------------------------------------------
%% -- application callbacks
%% @doc Application behaviour callback.
start(_Type, _Args) ->
    {ok, SupPid} = ejournald_sup:start_link(),
    start_reader(?READER, [{dir, undefined}]),  %% default journald reader name is 'ejournald_reader'
    start_io(journald, []),                     %% default io server name is 'journald'
    {ok, SupPid}.

%% @doc Application behaviour callback.
stop(_State) ->
    ok.

%% ----------------------------------------------------------------------------------------------------
%% -- interface for ejournald_io_server
%% @doc Start the default I/O-server named ejournald_io_server and identified by the name "ejournald_io_server" for journald.
-spec start_io( [io_options()] ) -> {ok, pid()} | {error, any()}.
start_io(Options) ->
    ejournald_sup:start(?IO_SERVER, Options).

-spec start_io( term(), [io_options()] ) -> {ok, pid()} | {error, any()}.
%% @doc Start an I/O-server with own options. The 'name' option is mandatory and used in journald logs.
start_io(Name, Options) ->
    ejournald_sup:start(?IO_SERVER, Name, Options).

%% @doc Stop an I/O-server with its name or pid.
-spec stop_io( term() ) -> ok | {error, any()}.
stop_io(Id) ->
    ejournald_sup:stop(Id).

%% ----------------------------------------------------------------------------------------------------
%% -- API for ejournald_reader
%% @doc Start an unnamed reader.
-spec start_reader( [reader_options()] ) -> {ok, pid()} | {error, any()}.
start_reader(Options) ->
    ejournald_sup:start(?READER, Options).

%% @doc Start a named reader.
-spec start_reader( term(), [reader_options()] ) -> {ok, pid()} | {error, any()}.
start_reader(Name, Options) ->
    ejournald_sup:start(?READER, Name, Options).

%% @doc Stop a reader by its name or pid.
-spec stop_reader( term() ) -> ok | {error, any()}.
stop_reader(Id) ->
    ejournald_sup:stop(Id).

%% ----------------------------------------------------------------------------------------------------
%% -- API for retrieving logs
%% @doc Get logs from default reader. See get_logs/2.
-spec get_logs( [log_options()] ) -> [ log_message() ] | {error, any()}.
get_logs(Options) ->
    get_logs(?READER, Options).

%% @doc Get logs from a named reader.
-spec get_logs(id(), [log_options()] ) -> [ log_message() ] | {error, any()}.
get_logs(Id, Options) ->
    case check_options(Options) of
        {Error, Reason} -> {Error, Reason};
        ok              -> gen_server:call(Id, {evaluate, Options}, 10000)
    end.
    
%% @doc Starts a worker that monitors the journal and filters new entries. 
%% Note that the message 'journal_invalidate' means that "journal files were added or 
%% removed (possibly due to rotation)" according to the systemd documentation. Thus you 
%% should e.g. refresh your monitors. 
-spec log_notify(sink(), [notify_options()] ) -> {ok, pid()} | {error, any()}.
log_notify(Sink, Options) when is_pid(Sink);is_function(Sink,1) ->
    case check_options(Options) of
        {Error, Reason} -> {Error, Reason};
        ok              -> evaluate_options_notify(Sink, Options)
    end.

%% @doc Stops the worker.
-spec stop_log_notify( pid() ) -> ok | {error, any()}.
stop_log_notify(Pid) ->
    ejournald_notifier_sup:stop(Pid).

%% ----------------------------------------------------------------------------------------------------
%% -- helpers
%% @private
evaluate_options_notify(Sink, Options) -> 
    case Sink of
        undefined -> 
            erlang:error(badarg, {error, no_sink});
        Sink when is_pid(Sink);is_function(Sink,1) ->
            ejournald_notifier_sup:start(Sink, Options)
    end.
    
%% @private
check_options([]) ->
    ok;
check_options([{direction, Dir} | RestOpts]) when Dir=:=ascending;Dir=:=descending ->
    check_options(RestOpts);
check_options([{since, {{Y,M,D}, {H,Min,S}}} | RestOpts]) 
    when is_number(Y),is_number(M),is_number(D),is_number(H),is_number(Min),is_number(S) ->
    check_options(RestOpts);
check_options([{until, {{Y,M,D}, {H,Min,S}}} | RestOpts]) 
    when is_number(Y),is_number(M),is_number(D),is_number(H),is_number(Min),is_number(S) ->
    check_options(RestOpts);
check_options([{at_most, AtMost} | RestOpts ]) when is_number(AtMost) -> 
    check_options(RestOpts);
check_options([{log_level, LogLevel} | RestOpts ]) when is_atom(LogLevel) -> 
    case lists:member(LogLevel, [emergency, alert, critical, error, warning, notice, info, debug]) of
        true    -> check_options(RestOpts);
        false   -> {badarg, {invalid_log_level, LogLevel}}
    end;
check_options([{message, Message} | RestOpts ]) when Message=:=true;Message=:=false -> 
    check_options(RestOpts);
check_options([{dir, Dir} | RestOpts]) when is_list(Dir) -> 
    check_options(RestOpts);
check_options([{regex, Regex} | RestOpts ]) ->
    case re:compile(Regex) of
        {ok, _MP}       -> check_options(RestOpts);
        {error, Error}  -> {badarg, {Regex, Error}}
    end;
check_options([{ErlOpt, Value} | RestOpts]) 
    when ErlOpt=:=application;ErlOpt=:=code_file;ErlOpt=:=function;ErlOpt=:=erl_node,is_atom(Value) -> 
    check_options(RestOpts);
check_options([ Arg | _RestOpts]) -> 
    {badarg, Arg}.

