%%%-------------------------------------------------------------------
%%% @author David Alpha Fox <>
%%% @copyright (C) 2014, David Alpha Fox
%%% @doc
%%%
%%% @end
%%% Created : 29 Jul 2014 by David Alpha Fox <>
%%%-------------------------------------------------------------------
-module(fog_id).

-behaviour(gen_server).
-include ("priv/protocol.hrl").

%% API
-export([start_link/1]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
		 terminate/2, code_change/3]).
-export([channel/0]).
-define(SERVER, ?MODULE).
-define(TIMEOUT, timer:seconds(60)).
-record(state, {
	ip,
	port,
	connected,
	heart_beat,
	miss,
	waiting,
	socket,
	buff
	}).

channel()->
	Pid = self(),
	gen_server:cast(?SERVER,{channel,Pid}),
    receive
    	{channel, Channel} -> 
    		{ok,Channel}
        after ?TIMEOUT ->
            gen_server:cast(?SERVER,{cancel_channel,Pid}),
            receive
                {channel, Channel} -> 
                	Channel
                after 0 -> 
                    throw({channel_timeout})
            end
    end.

start_link(Args) ->
	IP = proplists:get_value(ip,Args),
	Port = proplists:get_value(port,Args),
	HeartBeat = proplists:get_value(heart_beat,Args),
	gen_server:start_link({local, ?SERVER}, ?MODULE, {IP,Port,HeartBeat}, []).

init({IP,Port,HeartBeat}) ->
	State = #state{
		ip = IP,
		port = Port,
		connected = false,
		heart_beat = HeartBeat,
		miss = 0,
		waiting = queue:new(),
		socket = undefined,
		buff = <<>>
	},  
	{ok,State,0}.

handle_call(_Request, _From, State) ->
	Reply = ok,
	{reply, Reply, State}.

handle_cast({channel,Pid},#state{connected = true,heart_beat = HeartBeat,waiting = Waiting,socket = Socket} = State)->
	NewWaiting = queue:in(Pid, Waiting),
	Packet = protocol_marshal:write(?REQ_CHANNEL,undefined,undefined),
	ranch_ssl:send(Socket,Packet),
	NewState = State#state{waiting = NewWaiting},
	{noreply, NewState,HeartBeat};

handle_cast({cancel_channel,Pid},#state{heart_beat = HeartBeat,waiting = Waiting} = State)->
	NewWaiting = queue:filter(
                     fun(Q) -> Q =/= Pid end,
                     Waiting),
	NewState = State#state{waiting = NewWaiting},
	{noreply, NewState,HeartBeat};

handle_cast(_Msg, State) ->
	HeartBeat = State#state.heart_beat,
	{noreply, State,HeartBeat}.
	
handle_info({ssl, Socket, Bin},#state{heart_beat = HeartBeat,socket = Socket,buff = Buff} = State) ->
  % Flow control: enable forwarding of next TCP message
  ok = ranch_ssl:setopts(Socket, [{active, false}]),
  {Cmds,NewBuff} = protocol_marshal:read(<<Buff/bits,Bin/bits>>),
  NewState = process(Cmds,State),
  ok = ranch_ssl:setopts(Socket, [{active, once}]),
  NewState1 = NewState#state{buff = NewBuff},
  {noreply,NewState1,HeartBeat};

handle_info({ssl_closed, Socket}, #state{socket = Socket} = State) ->
	lager:log(info,?MODULE,"Remote Close"),
	{stop, ssl_closed, State};


handle_info(timeout,#state{ip = IP,port = Port,connected = false,heart_beat = HeartBeat} = State )->
	lager:log(info,?MODULE,"Try to connect to ~s:~p~n",[IP,Port]),
	Result = ranch_ssl:connect(IP,Port,[]),
	NewState = case Result of
		{ok,Socket}->
			ok = ranch_ssl:setopts(Socket, [{active, once}]),
			State#state{connected = true,socket = Socket};
		{error,Error}->
			lager:log(error,?MODULE,"Connect to ~s:~p fail. Reason: ~p~n",[IP,Port,Error]),
			State
		end,
	{noreply,NewState,HeartBeat};

handle_info(timeout,#state{connected = true,heart_beat = HeartBeat,miss = Miss,socket = Socket} = State)->
	Packet = protocol_marshal:write(?REQ_PING,undefined,undefined),
	ranch_ssl:send(Socket,Packet),
	{noreply,State,HeartBeat};

handle_info({'DOWN', _MonitorRef, process, Pid, _Info},#state{heart_beat = HeartBeat,socket = Socket} = State) -> 
	hm_misc:demonitor(Pid,multiplex_monitor),
	case ets:match_object(multiplex_mapper,{'_',Pid}) of
		[] ->
			{noreply,State,HeartBeat};
		[{ID,Pid}] ->
			ets:delete(multiplex_mapper,ID),
			case State#state.connected of
				true ->
					Packet = protocol_marshal:write(?REQ_CLOSE,ID,undefined),
					try
						ranch_ssl:send(Socket,Packet)
					catch
						_:_Reason ->
							ok
					end;
				_->
					ok
				end,
  			{noreply, State,HeartBeat}
	end;

handle_info(_Info, State) ->
	HeartBeat = State#state.heart_beat,
	{noreply, State,HeartBeat}.

terminate(_Reason, _State) ->
	io:format("Die Die~n"),
	ok.

code_change(_OldVsn, State, _Extra) ->
	{ok, State}.

disptach(Waiting,Channel)->
	W = queue:out(Waiting),
	{R,NW} = case W of 
		{{value, Pid},NewWaiting} ->
			case erlang:is_process_alive(Pid) of
				true ->
					erlang:send(Pid,{channel,Channel}),
					{ok,NewWaiting};
				_->
					{again,NewWaiting}
			end;
		_->
			{ok,Waiting}
	end,
	case R of
		again ->
			disptach(NW,Channel);
		_->
			NW
	end.

process([],State)->
	State;
process([H|T],State)->
	Waiting = State#state.waiting,
	Socket = State#state.socket,
	{R,NewState} = case H of
		{?RSP_PONG,_,_}->
			{ok,State};
		{?RSP_CHANNEL,_,ID} ->
			NewWaiting = disptach(Waiting,ID),
			{ok,State#state{waiting = NewWaiting}}
		end,
	NewState2 = case R of
		ok ->
			NewState;
		_ ->
			ranch_ssl:send(Socket,R),
			NewState
	end,
	process(T,NewState2).
