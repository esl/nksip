%% -------------------------------------------------------------------
%%
%% Copyright (c) 2015 Carlos Gonzalez Florido.  All Rights Reserved.
%%
%% This file is provided to you under the Apache License,
%% Version 2.0 (the "License"); you may not use this file
%% except in compliance with the License.  You may obtain
%% a copy of the License at
%%
%%   http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing,
%% software distributed under the License is distributed on an
%% "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
%% KIND, either express or implied.  See the License for the
%% specific language governing permissions and limitations
%% under the License.
%%
%% -------------------------------------------------------------------

%% @private Call Distribution Router
-module(nksip_router).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-behaviour(gen_server).

-export([incoming_sync/1, incoming_sync/4]).
-export([get_all_calls/0]).
-export([pending_msgs/0, pending_work/0]).
-export([send_work_sync/3, send_work_async/3]).
-export([pos2name/1, start_link/2]).
-export([init/1, terminate/2, code_change/3, handle_call/3, handle_cast/2,
            handle_info/2]).

-include("nksip.hrl").
-include("nksip_call.hrl").



%% ===================================================================
%% Public
%% ===================================================================

%% @doc Sends a synchronous piece of {@link nksip_call_worker:work()} to a call.
-spec send_work_sync(nksip:srv_id(), nksip:call_id(), nksip_call_worker:work()) ->
    any() | {error, too_many_calls | looped_process | {exit, term()}}.

send_work_sync(SrvId, CallId, Work) ->
    Name = name(CallId),
    Timeout = nksip_config_cache:sync_call_time(),
    WorkSpec = {send_work_sync, SrvId, CallId, Work, self()},
    case nklib_util:call(Name, WorkSpec, Timeout) of
        {error, {exit, {{timeout, _}, _StackTrace}}} ->
            {error, {exit, timeout}};
        {error, {exit, Exit}} ->
            ?warning(SrvId, CallId, "error calling send_work_sync (~p): ~p",
                     [work_id(Work), Exit]),
            {error, {exit, Exit}};
        Other ->
            Other
    end.


%% @doc Called when a new request or response has been received.
-spec incoming_sync(nksip:request()|nksip:response()) ->
    ok | {error, too_many_calls | looped_process | {exit, term()}}.

incoming_sync(#sipmsg{srv_id=SrvId, call_id=CallId}=SipMsg) ->
    Name = name(CallId),
    Timeout = nksip_config_cache:sync_call_time(),
    case nklib_util:call(Name, {incoming, SipMsg}, Timeout) of
        {error, {exit, Exit}} -> 
            ?warning(SrvId, CallId, "error calling incoming_sync: ~p", [Exit]),
            {error, {exit, Exit}};
        Result -> 
            Result
    end.


%% @doc Called when a new request or response has been received.
-spec incoming_sync(nksip:srv_id(), nksip:call_id(), nkpacket:nkport(), binary()) ->
    ok | {error, too_many_calls | looped_process | {exit, term()}}.

incoming_sync(SrvId, CallId, NkPort, Msg) ->
    Name = name(CallId),
    Timeout = nksip_config_cache:sync_call_time(),
    case nklib_util:call(Name, {incoming, SrvId, CallId, NkPort, Msg}, Timeout) of
        {error, {exit, Exit}} -> 
            ?warning(SrvId, CallId, "error calling incoming_sync: ~p", [Exit]),
            {error, {exit, Exit}};
        Result -> 
            Result
    end.


%% @doc Get all started calls.
-spec get_all_calls() ->
    [{nksip:srv_id(), nksip:call_id(), pid()}].

get_all_calls() ->
    Fun = fun(Name, Acc) -> [call_fold(Name)|Acc] end,
    lists:flatten(router_fold(Fun)).


%% @private
pending_work() ->
    router_fold(fun(Name, Acc) -> Acc+gen_server:call(Name, works) end, 0).


%% @private
pending_msgs() ->
    router_fold(
        fun(Name, Acc) ->
            Pid = whereis(Name),
            {_, Len} = erlang:process_info(Pid, message_queue_len),
            Acc + Len
        end,
        0).


%% ===================================================================
%% gen_server
%% ===================================================================

-type work_item() :: 
    {reference(), {pid(), term()}, nksip_call_worker:work()}.

-record(state, {
    pos :: integer(),
    name :: atom(),
    services = #{} :: #{SrvId::pid() => {nksip:srv_id(), [CallPid::pid()]}},
    works = #{} :: #{CallPid::pid()=>{nksip:srv_id(), nksip:call_id(), [work_item()]}}
}).


%% @private
start_link(Pos, Name) ->
    gen_server:start_link({local, Name}, ?MODULE, [Pos, Name], []).
        
%% @private 
-spec init(term()) ->
    {ok, #state{}}.

init([Pos, Name]) ->
    Name = ets:new(Name, [named_table, protected]),
    {ok, #state{pos=Pos, name=Name}}.


%% @private
-spec handle_call(term(), {pid(), term()}, #state{}) ->
    {reply, term(), #state{}} | {noreply, #state{}}.

handle_call({send_work_sync, SrvId, CallId, Work, Caller}, From, State) ->
    case send_work_sync(SrvId, CallId, Work, Caller, From, State) of
        {ok, State1} -> 
            {noreply, State1};
        {error, Error} ->
            case Error of
                service_not_found ->
                    ok;
                _ ->
                    ?error(SrvId, CallId, "error sending work ~p: ~p", [Work, Error])
            end,
            {reply, {error, Error}, State}
    end;

handle_call({incoming, SipMsg}, _From, State) ->
    #sipmsg{srv_id=SrvId, call_id=CallId} = SipMsg,
    case send_work_sync(SrvId, CallId, {incoming, SipMsg}, none, none, State) of
        {ok, State1} -> 
            {reply, ok, State1};
        {error, Error} ->
            ?error(SrvId, CallId, "error processing incoming message: ~p", [Error]),
            {reply, {error, Error}, State}
    end;

handle_call({incoming, SrvId, CallId, Transp, Msg}, _From, State) ->
    case send_work_sync(SrvId, CallId, {incoming, SrvId, CallId, Transp, Msg}, none, none, State) of
        {ok, State1} -> 
            {reply, ok, State1};
        {error, Error} ->
            ?error(SrvId, CallId, "error processing incoming message: ~p", [Error]),
            {reply, {error, Error}, State}
    end;


handle_call(works, _From, #state{works=Works}=State) ->
    {reply, maps:size(Works), State};

handle_call(Msg, _From, State) -> 
    logger:error("Module ~p received unexpected call ~p", [?MODULE, Msg]),
    {noreply, State}.


%% @private
-spec handle_cast(term(), #state{}) ->
    {noreply, #state{}}.

handle_cast({incoming, SipMsg}, State) ->
    #sipmsg{srv_id=SrvId, call_id=CallId} = SipMsg,
    case send_work_sync(SrvId, CallId, {incoming, SipMsg}, none, none, State) of
        {ok, State1} -> 
            {noreply, State1};
        {error, Error} ->
            ?error(SrvId, CallId, "error processing incoming message: ~p", [Error]),
            {noreply, State}
    end;

handle_cast(Msg, State) ->
    logger:error("Module ~p received unexpected event: ~p", [?MODULE, Msg]),
    {noreply, State}.


%% @private
-spec handle_info(term(), #state{}) ->
    {noreply, #state{}}.

handle_info({sync_work_received, Ref, Pid}, #state{works=Works}=State) ->
    Works1 = case maps:find(Pid, Works) of
        {ok, {_SrvId, _CallId, [{Ref, _From, _Work}]}} ->
            maps:remove(Pid, Works);
        {ok, {SrvId, CallId, WorkList}} ->
            WorkList1 = lists:keydelete(Ref, 1, WorkList),
            maps:put(Pid, {SrvId, CallId, WorkList1}, Works);
        error ->
            logger:warning("Receiving sync_work_received for unknown work"),
            Works
    end,
    {noreply, State#state{works=Works1}};

handle_info({'DOWN', _MRef, process, Pid, _Reason}, State) ->
    #state{name=Name, services=Srvs, works=Works} = State,
    case maps:find(Pid, Srvs) of
        {ok, {SrvId, CallPids}} ->
            % A service is down
            logger:info("Service ~p (~p) down at ~p. Calls: ~p", 
                          [SrvId, SrvId:name(), Name, CallPids]),
            lists:foreach(fun(CallPid) -> gen_server:cast(CallPid, stop) end, CallPids),
            State1 = State#state{services=maps:remove(Pid, Srvs)},
            {noreply, State1};
        error ->
            % A call is down
            State1 = remove_call(Pid, State),
            State2 = case maps:find(Pid, Works) of
                {ok, {SrvId, CallId, WorkList}} -> 
                    % We had pending work for this process.
                    % Actually, we know the process has stopped normally before processing
                    % these requests (it hasn't failed due to an error).
                    % If the process had failed due to an error processing the work,
                    % the "received work" message would have been received an the work will
                    % not be present in Works.
                    St = State1#state{works=maps:remove(Pid, Works)},
                    resend_worklist(SrvId, CallId, lists:reverse(WorkList), St);
                error ->
                    State1
            end,
            {noreply, State2}
    end;

handle_info(Info, State) -> 
    logger:warning("Module ~p received unexpected info: ~p", [?MODULE, Info]),
    {noreply, State}.


%% @private
-spec code_change(term(), #state{}, term()) ->
    {ok, #state{}}.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.


%% @private
-spec terminate(term(), #state{}) ->
    ok.

terminate(_Reason, _State) ->  
    ok.


%% ===================================================================
%% Internal
%% ===================================================================

%% @private 
-spec name(nksip:call_id()) ->
    atom().

name(CallId) ->
    Pos = erlang:phash2(CallId) rem nksip_config_cache:msg_routers(),
    pos2name(Pos).


%% @private
-spec send_work_sync(nksip:srv_id(), nksip:call_id(), nksip_call_worker:work(), 
                     pid() | none, {pid(), term()}, #state{}) ->
    {ok, #state{}} | {error, looped_process | service_not_found | too_many_calls}.

send_work_sync(SrvId, CallId, Work, Caller, From, #state{name=Name}=State) ->
    case find_call_pid(Name, SrvId, CallId) of
        {ok, Caller} ->
            {error, looped_process};
        {ok, CallPid} -> 
            do_send_work_sync(CallPid, SrvId, CallId, Work, From, State);
        not_found ->
            case whereis(SrvId) of
                undefined ->
                    {error, service_not_found};
                SrvPid ->
                    do_call_start(SrvId, SrvPid, CallId, Work, From, State)
            end
    end.

%% @private
-spec do_send_work_sync(pid(), nksip:srv_id(), nksip:call_id(), nksip_call_worker:work(), 
                        {pid(), term()}, #state{}) ->
    {ok, #state{}}.

do_send_work_sync(CallPid, SrvId, CallId, Work, From, #state{works=Works}=State) ->
    Ref = make_ref(),
    nksip_call_srv:sync_work(CallPid, Ref, self(), Work, From),
    Works1 = case maps:find(CallPid, Works) of
        {ok, {_, _, WorkList}} ->
            maps:put(CallPid, {SrvId, CallId, [{Ref, From, Work}|WorkList]}, Works);
        error ->
            maps:put(CallPid, {SrvId, CallId, [{Ref, From, Work}]}, Works)
    end,
    {ok, State#state{works=Works1}}.
    

%% @private
-spec do_call_start(nksip:srv_id(), pid(), nksip:call_id(), nksip_call_worker:work(), 
                    {pid(), term()}, #state{}) ->
    {ok, #state{}} | {error, too_many_calls}.

do_call_start(SrvId, SrvPid, CallId, Work, From, State) ->
    Max = nksip_config_cache:max_calls(),
    case nklib_counters:value(nksip_calls) < Max of
        true ->
            SrvMax = ?GET_CONFIG(SrvId, max_calls),
            case nklib_counters:value({nksip_calls, SrvId}) < SrvMax of
                true ->
                    {ok, CallPid} = nksip_call_srv:start(SrvId, CallId),
                    State1 = save_call(SrvId, SrvPid, CallId, CallPid, State),
                    do_send_work_sync(CallPid, SrvId, CallId, Work, From, State1);
                false ->
                    {error, too_many_calls}
            end;
        false ->
            {error, too_many_calls}
    end.


%% @doc Sends an asynchronous piece of {@link nksip_call_worker:work()} to a call.
-spec send_work_async(nksip:srv_id(), nksip:call_id(), nksip_call_worker:work()) ->
    ok.

send_work_async(SrvId, CallId, Work) ->
    send_work_async(name(CallId), SrvId, CallId, Work).


%% @private Sends an asynchronous piece of {@link nksip_call_worker:work()} to a call.
-spec send_work_async(atom(), nksip:srv_id(), nksip:call_id(), nksip_call_worker:work()) ->
    ok.

send_work_async(Name, SrvId, CallId, Work) ->
    case find_call_pid(Name, SrvId, CallId) of
        {ok, CallPid} -> 
            nksip_call_srv:async_work(CallPid, Work);
        not_found -> 
            ?info(SrvId, CallId, "trying to send work ~p to deleted call", 
                  [work_id(Work)])
   end.


%% @private
-spec resend_worklist(nksip:srv_id(), nksip:call_id(), 
                      [{reference(), {pid(), term()}|none, nksip_call_worker:work()}], 
                      #state{}) ->
    #state{}.

resend_worklist(_SrvId, _CallId, [], State) ->
    State;

resend_worklist(SrvId, CallId, [{_Ref, From, Work}|Rest], State) ->
    case send_work_sync(SrvId, CallId, Work, none, From, State) of
        {ok, State1} -> 
            ?debug(SrvId, CallId, "resending work ~p from ~p", 
                   [work_id(Work), From]),
            resend_worklist(SrvId, CallId, Rest, State1);
        {error, Error} ->
            case From of
                {Pid, Ref} when is_pid(Pid), is_reference(Ref) ->
                    gen_server:reply(From, {error, Error});
                _ ->
                    ok
            end,
            resend_worklist(SrvId, CallId, Rest, State)
    end.


%% @private
-spec find_call_pid(atom(), nksip:srv_id(), nksip:call_id()) ->
    {ok, pid()} | not_found.

find_call_pid(Name, SrvId, CallId) ->
    case ets:lookup(Name, {call, SrvId, CallId}) of
        [{_, CallPid}] -> {ok, CallPid};
        [] -> not_found
    end.

%% @private
work_id(Tuple) when is_tuple(Tuple) -> element(1, Tuple);
work_id(Other) -> Other.



%% @private
-spec save_call(nksip:srv_id(), pid(), nksip:call_id(), pid(), #state{}) ->
    #state{}.

save_call(SrvId, SrvPid, CallId, CallPid, #state{name=Name, services=Srvs}=State) ->
    erlang:monitor(process, CallPid),
    RefId = {call, SrvId, CallId},
    true = ets:insert(Name, [{RefId, CallPid}, {CallPid, RefId}]),
    OldCalls = case maps:find(SrvPid, Srvs) of
        {ok, {SrvId, OldCalls0}} -> 
            OldCalls0;
        error -> 
            monitor(process, SrvPid),
            []
    end,
    Srvs1 = maps:put(SrvPid, {SrvId, [CallPid|OldCalls]}, Srvs),
    State#state{services=Srvs1}.


%% @private
-spec remove_call(pid(), #state{}) ->
    #state{}.

remove_call(CallPid, #state{pos=Pos, name=Name, services=Srvs}=State) ->
    case ets:lookup(Name, CallPid) of
        [{CallPid, RefId}] ->
            {_, SrvId, CallId} = RefId,
            ?debug(SrvId, CallId, "Router ~p unregistering call", [Pos]),
            ets:delete(Name, CallPid), 
            ets:delete(Name, RefId),
            case whereis(SrvId) of
                undefined ->
                    State;
                SrvPid ->
                    case maps:find(SrvPid, Srvs) of
                        {ok, {SrvId, CallPids}} ->
                            CallPids1 = CallPids -- [CallPid],
                            Srvs1 = maps:put(SrvPid, {SrvId, CallPids1}, Srvs),
                            State#state{services=Srvs1};
                        error ->
                            % It could be already deleted
                            State
                    end
            end;
        [] ->
            State
    end.


%% @private
router_fold(Fun) ->
    router_fold(Fun, []).

router_fold(Fun, Init) ->
    lists:foldl(
        fun(Pos, Acc) -> Fun(pos2name(Pos), Acc) end,
        Init,
        lists:seq(0, nksip_config_cache:msg_routers()-1)).

%% @private
call_fold(Name) ->
    ets:foldl(
        fun(Record, Acc) ->
            case Record of
                {{call, SrvId, CallId}, Pid} when is_pid(Pid) ->
                    [{SrvId, CallId, Pid}|Acc];
                _ ->
                    Acc
            end
        end,
        [],
        Name).



%% @private
-spec pos2name(integer()) -> 
    atom().

% Ugly but speedy
pos2name(0) -> nksip_router_0;
pos2name(1) -> nksip_router_1;
pos2name(2) -> nksip_router_2;
pos2name(3) -> nksip_router_3;
pos2name(4) -> nksip_router_4;
pos2name(5) -> nksip_router_5;
pos2name(6) -> nksip_router_6;
pos2name(7) -> nksip_router_7;
pos2name(8) -> nksip_router_8;
pos2name(9) -> nksip_router_9;
pos2name(10) -> nksip_router_10;
pos2name(11) -> nksip_router_11;
pos2name(12) -> nksip_router_12;
pos2name(13) -> nksip_router_13;
pos2name(14) -> nksip_router_14;
pos2name(15) -> nksip_router_15;
pos2name(16) -> nksip_router_16;
pos2name(17) -> nksip_router_17;
pos2name(18) -> nksip_router_18;
pos2name(19) -> nksip_router_19;
pos2name(20) -> nksip_router_20;
pos2name(21) -> nksip_router_21;
pos2name(22) -> nksip_router_22;
pos2name(23) -> nksip_router_23;
pos2name(24) -> nksip_router_24;
pos2name(25) -> nksip_router_25;
pos2name(26) -> nksip_router_26;
pos2name(27) -> nksip_router_27;
pos2name(28) -> nksip_router_28;
pos2name(29) -> nksip_router_29;
pos2name(30) -> nksip_router_30;
pos2name(31) -> nksip_router_31;
pos2name(P) -> list_to_atom("nksip_router_"++integer_to_list(P)).

