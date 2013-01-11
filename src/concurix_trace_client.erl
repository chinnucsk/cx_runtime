-module(concurix_trace_client).

-export([start_trace_client/0, send_summary/1, stop_trace_client/0]).

-record(tcstate, {proctable, linktable, runinfo}).

stop_trace_client() ->
	%% TODO when this is a gen server clean up the ets tables too 
	dbg:stop_clear().
	
start_trace_client() ->
	dbg:start(),
	Stats = ets:new(linkstats, [public, named_table]),
	Procs = ets:new(procinfo, [public, named_table]),
	%% TODO -- use real auth, send to both s3 for storage as well as cx for dynamic display
	RunInfo = concurix_run:get_run_info(),	
	State = #tcstate{proctable = Procs, linktable = Stats, runinfo = RunInfo},
	
	Pid = dbg:tracer(process, {fun(A,B) -> handle_trace_message(A,B) end, State }),
	dbg:p(all, [s,p]),
	timer:apply_interval(2000, concurix_trace_client, send_summary, [State]),
	ok.

handle_trace_message({trace, Sender, send, Data, Recipient}, State) ->
	update_proc_table([Sender, Recipient], State),
	case ets:lookup(State#tcstate.linktable, {Sender, Recipient}) of
		[] ->
			ets:insert(State#tcstate.linktable, {{Sender, Recipient}, 1});
		_X ->
			ets:update_counter(State#tcstate.linktable, {Sender, Recipient}, 1)
	end,	
	State;
handle_trace_message({trace, Pid, exit, Reason}, State) ->
	ets:select_delete(State#tcstate.linktable, [ { {{'_', Pid},'_'}, [], [true]}, { {{Pid, '_'}, '_'}, [], [true] } ]),
	ets:select_delete(State#tcstate.proctable, [ { {Pid, '_'}, [], [true]}]),
	State;
handle_trace_message({trace, Creator, spawn, Pid, Data}, State) ->
	case Data of 
		{proc_lib, init_p, [_App, _Caller, Mod, Fun, Args]} ->
			ok;
		{erlang, apply, [Fun, Args]} ->
			Mod = erlang;
		{Mod, Fun, Args} ->
			ok;
		X ->
			io:format("got unknown spawn of ~p ~n", [X]),
			Mod = unknown,
			Fun = X,
			Args = []
	end,

	Arity = length(Args),
	Key = {Pid, {Mod, Fun, Arity}},
	ets:insert(State#tcstate.proctable, Key),
	State;
handle_trace_message(Msg, State) ->
	%%io:format("msg = ~p ~n", [Msg]),
	State.
	
send_summary(State)->
	Procs  = ets:tab2list(State#tcstate.proctable),
	Links = ets:tab2list(State#tcstate.linktable),
	
	TempProcs = [ [{name, pid_to_s(Pid)}, {module, M}, {function, F}, {arity, A}, local_process_info(Pid, reductions)] || {Pid, {M, F, A}} <- Procs ],
	TempLinks = [ [{source, pid_to_s(A)}, {target, pid_to_s(B)}, {value, C}] || {{A, B}, C} <- Links],
	
	Send = [{nodes, TempProcs}, {links, TempLinks}],

	Data = lists:flatten(io_lib:format("~p", [Send])),

	Encoded = "data=" ++ http_uri:encode(Data),
	RunId   = proplists:get_value(run_id, State#tcstate.runinfo),
	[{api_key, APIkey}] = 			ets:lookup(concurix_config_master, api_key),
	
	Url = "http://localhost:8001/bench/process_graph_data/" ++ RunId ++ "/" ++ APIkey,
	Reply = httpc:request(post, {Url, [], "application/x-www-form-urlencoded", Encoded}, [], []),
	case Reply of
		{_, {{_Version, 200, _ReasonPhrase}, _Headers, Body}} -> 
			ok = concurix_compile:eval_string(Body);
		_X ->
			{Mega, Secs, Micro} = now(), 
			lists:flatten(io_lib:format("local-~p-~p-~p",[Mega, Secs, Micro]))
	end.
	
pid_to_s(Pid) ->
	lists:flatten(io_lib:format("~p", [Pid])).
	
	
%
%
update_proc_table([], State) ->
	ok;
update_proc_table([Pid | Tail], State) ->
	case ets:lookup(State#tcstate.proctable, Pid) of
		[] ->
			case Pid of 
				Pid when is_pid(Pid) ->
					{initial_call, {Mod, Fun, Arity}} = process_info(Pid, initial_call);
				Pid when is_port(Pid) ->
					Info = erlang:port_info(Pid),
					Mod = port,
					Fun = proplists:get_value(name, Info),
					Arity = 0;
				Pid when is_atom(Pid) ->
					P = whereis(Pid),
					{initial_call, {Mod, Fun, Arity}} = process_info(P, initial_call);
				Pid ->
					Mod = unknown,
					Fun = Pid,
					Arity = 0
			end,
			ets:insert(State#tcstate.proctable, {Pid, {Mod, Fun, Arity}});
		_X ->
			ok
	end,
	update_proc_table(Tail, State).
	
local_process_info(Pid, reductions) when is_pid(Pid) ->
	process_info(Pid, reductions);
local_process_info(Pid, reductions) when is_atom(Pid) ->
	process_info(whereis(Pid), reductions);
local_process_info(Pid, reductions) ->
	{reductions, 1}.