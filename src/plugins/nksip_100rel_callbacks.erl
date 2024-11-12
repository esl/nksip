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

%% @doc NkSIP Event State Compositor Plugin Callbacks
-module(nksip_100rel_callbacks).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-include("../include/nksip.hrl").
-include("../include/nksip_call.hrl").

-export([plugin_deps/0, plugin_config/2, plugin_start/2, plugin_stop/2]).
-export([sip_prack/2]).
-export([nks_sip_parse_uac_opts/2, 
         nks_sip_uac_pre_response/3, nks_sip_uac_response/4, 
         nks_sip_parse_uas_opt/3, nks_sip_uas_timer/3,
         nks_sip_uas_send_reply/3, nks_sip_uas_sent_reply/1, nks_sip_uas_method/4]).



%% ===================================================================
%% Plugin
%% ===================================================================

plugin_deps() ->
    [nksip].


plugin_config(Config, _Service) ->
    Allow1 = maps:get(sip_allow, Config, nksip_syntax:default_allow()),
    Allow2 = nklib_util:store_value(<<"PRACK">>, Allow1),
    Supported1 = maps:get(sip_supported, Config, nksip_syntax:default_supported()),
    Supported2 = nklib_util:store_value(<<"100rel">>, Supported1),
    Config2 = Config#{sip_allow=>Allow2, sip_supported=>Supported2},
    {ok, Config2}.


plugin_start(Config, #{name:=Name}) ->
    logger:info("Plugin ~p started (~s)", [?MODULE, Name]),
    {ok, Config}.


plugin_stop(Config, #{name:=Name}) ->
    logger:info("Plugin ~p stopped (~s)", [?MODULE, Name]),
    Allow1 = maps:get(sip_allow, Config, []),
    Allow2 = Allow1 -- [<<"PRACK">>],
    Supported1 = maps:get(sip_supported, Config, []),
    Supported2 = Supported1 -- [<<"100rel">>],
    {ok, Config#{sip_allow=>Allow2, sip_supported=>Supported2}}.


%% ===================================================================
%% Specific
%% ===================================================================


%% @doc Called when a valid PRACK request is received.
-spec sip_prack(Req::nksip:request(), Call::nksip:call()) ->
    {reply, nksip:sipreply()} | noreply.

sip_prack(_Req, _Call) ->
    {reply, ok}.



%% ===================================================================
%% SIP Core
%% ===================================================================


%% @doc Called to parse specific UAC options
-spec nks_sip_parse_uac_opts(nksip:request(), nksip:optslist()) ->
    {error, term()}|{continue, list()}.

nks_sip_parse_uac_opts(Req, Opts) ->
    case lists:keyfind(prack_callback, 1, Opts) of
        {prack_callback, Fun} when is_function(Fun, 2) ->
            {continue, [Req, Opts]};
        {prack_callback, _} ->
            {error, {invalid_config, prack_callback}};
        false ->
            {continue, [Req, Opts]} 
    end.


%% @doc Called after the UAC pre processes a response
-spec nks_sip_uac_pre_response(nksip:response(),  nksip_call:trans(), nksip:call()) ->
    {ok, nksip:call()} | continue.

nks_sip_uac_pre_response(Resp, UAC, Call) ->
    case nksip_100rel:is_prack_retrans(Resp, UAC) of
        true ->
            ?call_info("UAC received retransmission of reliable provisional "
                       "response", []),
            {ok, Call};
        false ->
            continue
    end.


%% @doc Called after the UAC processes a response
-spec nks_sip_uac_response(nksip:request(), nksip:response(), 
                        nksip_call:trans(), nksip:call()) ->
    continue | {ok, nksip:call()}.

nks_sip_uac_response(_Req, Resp, UAC, Call) ->
    #trans{id=Id, from=From, method=Method} = UAC,
    #sipmsg{
        class = {resp, Code, _Reason}, 
        dialog_id = DialogId,
        require = Require
    } = Resp,
    case From of
        {fork, _} ->
            continue;
        _ when Method=='INVITE', Code>100, Code<200 ->
            case lists:member(<<"100rel">>, Require) of
                true -> nksip_100rel:send_prack(Resp, Id, DialogId, Call);
                false -> continue
            end;
        _ ->
            continue
    end.


%% @doc Called to parse specific UAS options
-spec nks_sip_parse_uas_opt(nksip:request(), nksip:response(), nksip:optslist()) ->
    {continue, list()}.

nks_sip_parse_uas_opt(Req, Resp, Opts) ->
    #sipmsg{class={req, Method}, require=ReqRequire, supported=ReqSupported} = Req,
    #sipmsg{class={resp, Code, _}, require=RespRequire} = Resp,
    case 
        (Method=='INVITE' andalso Code>100 andalso Code<200
        andalso lists:member(<<"100rel">>, ReqRequire))
        orelse
        lists:member(do100rel, Opts) 
    of
        true ->
            case lists:member(<<"100rel">>, ReqSupported) of
                true -> 
                    Resp1 = case lists:member(<<"100rel">>, RespRequire) of
                        true -> Resp;
                        false -> Resp#sipmsg{require=[<<"100rel">>|RespRequire]}
                    end,
                    Opts1 = nklib_util:delete(Opts, do100rel),
                    {continue, [Req, Resp1, Opts1]};
                false -> 
                    Opts1 = nklib_util:delete(Opts, do100rel),
                    {continue, [Req, Resp, Opts1]}
            end;
        false ->
            {continue, [Req, Resp, Opts]}
    end.


%% @doc Called when a new reponse is going to be sent
-spec nks_sip_uas_send_reply({nksip:response(), nksip:optslist()}, 
                             nksip_call:trans(), nksip_call:call()) ->
    {continue, list()} | {error, term()}.

nks_sip_uas_send_reply({Resp, SendOpts}, UAS, Call) ->
    case nksip_sipmsg:require(<<"100rel">>, Resp) of
        true ->
            case nksip_100rel:uas_store_info(Resp, UAS) of
                {ok, Resp1, UAS1} ->
                    {continue, [{Resp1, SendOpts}, UAS1, Call]};
                {error, Error} ->
                    {error, Error}
            end;
        false -> 
            {continue, [{Resp, SendOpts}, UAS, Call]}
    end.


%% @doc Called when a new reponse is sent
-spec nks_sip_uas_sent_reply(nksip_call:call()) ->
    {ok, nksip_call:call()} | {continue, list()}.

nks_sip_uas_sent_reply(#call{trans=[UAS|_]}=Call) ->
    #trans{status=Status, response=Resp, code=Code} = UAS,
    case nksip_sipmsg:require(<<"100rel">>, Resp) of
        true when Status==invite_proceeding, Code<200 ->
            UAS1 = nksip_100rel:timeout_timer(UAS, Call),
            UAS2 = nksip_100rel:retrans_timer(UAS1, Call),
            {ok, nksip_call_lib:update(UAS2, Call)};
        _ ->
            {continue, [Call]}
    end.



 %% @doc Called when a new request has to be processed
-spec nks_sip_uas_method(nksip:method(), nksip:request(), 
                      nksip_call:trans(), nksip_call:call()) ->
    {ok, nksip_call:trans(), nksip_call:call()} | {continue, list()}.

nks_sip_uas_method('PRACK', Req, UAS, Call) ->
    {UAS1, Call1} = nksip_100rel:uas_method(Req, UAS, Call),
    {ok, UAS1, Call1};

nks_sip_uas_method(Method, Req, UAS, Call) ->
    {continue, [Method, Req, UAS, Call]}.


%% @doc Called when a UAS timer is fired
-spec nks_sip_uas_timer(nksip_call_lib:timer()|term(), nksip_call:trans(), 
                        nksip_call:call()) ->
    {ok, nksip_call:call()} | continue.

nks_sip_uas_timer(nksip_100rel_prack_retrans, #trans{id=Id, response=Resp}=UAS, Call) ->
    #sipmsg{class={resp, Code, _Reason}} = Resp,
    UAS2 = case nksip_call_uas_transp:resend_response(Resp, []) of
        {ok, _} ->
            ?call_info("UAS ~p retransmitting 'INVITE' ~p reliable response", 
                       [Id, Code]),
            nksip_100rel:retrans_timer(UAS, Call);
        {error, _} -> 
            ?call_notice("UAS ~p could not retransmit 'INVITE' ~p reliable response", 
                         [Id, Code]),
            UAS1 = UAS#trans{status=finished},
            nksip_call_lib:timeout_timer(cancel, UAS1, Call)
    end,
    {ok, nksip_call_lib:update(UAS2, Call)};

nks_sip_uas_timer(nksip_100rel_prack_timeout, #trans{id=Id, method=Method}=UAS, Call) ->
    ?call_notice("UAS ~p ~p reliable provisional response timeout", [Id, Method]),
    Reply = {internal_error, <<"Reliable Provisional Response Timeout">>},
    {ok, nksip_call_uas:do_reply(Reply, UAS, Call)};

nks_sip_uas_timer(_Tag, _UAS, _Call) ->
    continue.
