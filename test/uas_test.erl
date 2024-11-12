
%% -------------------------------------------------------------------
%%
%% uas_test: Basic Test Suite
%%
%% Copyright (c) 2013 Carlos Gonzalez Florido.  All Rights Reserved.
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

-module(uas_test).

-include_lib("eunit/include/eunit.hrl").
-include("../include/nksip.hrl").

-compile([export_all]).


uas_test_() ->
    {setup, spawn, 
        fun() -> start() end,
        fun(_) -> stop() end,
        [
            {timeout, 60, fun uas/0}, 
            {timeout, 60, fun auto/0},
            {timeout, 60, fun timeout/0}
        ]
    }.


start() ->
    tests_util:start_nksip(),

    ok = tests_util:start(server1, ?MODULE, [
        {sip_from, "\"NkSIP Basic SUITE Test Server\" <sip:server1@nksip>"},
        {sip_supported, "a;a_param, 100rel"},
        {sip_uac_auto_register_timer, 1},
        {plugins, [nksip_registrar]},
        {sip_listen, "sip:all:5060, <sip:all:5061;transport=tls>"}
    ]),

    ok = tests_util:start(client1, ?MODULE, [
        {sip_from, "\"NkSIP Basic SUITE Test Client\" <sip:client1@nksip>"},
        {sip_uac_auto_register_timer, 1},
        {sip_listen, ["<sip:all:5070>", "<sip:all:5071;transport=tls>"]},
        {plugins, [nksip_uac_auto_register]}
    ]),
            
    ok = tests_util:start(client2, ?MODULE, [
        {sip_from, "\"NkSIP Basic SUITE Test Client\" <sip:client2@nksip>"}]),

    ok = tests_util:start(server2, ?MODULE, [
        {sip_registrar_min_time, 1},
        {sip_uac_auto_register_timer, 1},
        {plugins, [nksip_registrar]},
        {sip_listen, "sip:all:5080"}
    ]),

    tests_util:log(),
    ?debugFmt("Starting ~p", [?MODULE]).


stop() ->
    ok = nksip:stop(server1),
    ok = nksip:stop(client1),
    ok = nksip:stop(client2).


uas() ->
    % Test loop detection
    {ok, 200, Values1} = nksip_uac:options(client1, "sip:127.0.0.1", [
                                {add, <<"x-nk-op">>, <<"reply-stateful">>},
                                {meta, [call_id, from, cseq_num]}]),
    [{call_id, CallId1}, {from, From1}, {cseq_num, CSeq1}] = Values1,

    {ok, 482, [{reason_phrase, <<"Loop Detected">>}]} = 
        nksip_uac:options(client1, "sip:127.0.0.1", [
                            {add, <<"x-nk-op">>, <<"reply-stateful">>},
                            {call_id, CallId1}, {from, From1}, {cseq_num, CSeq1}, 
                            {meta, [reason_phrase]}]),

    % Stateless proxies do not detect loops
    {ok, 200, Values3} = nksip_uac:options(client1, "sip:127.0.0.1", [
                            {add, "x-nk-op", "reply-stateless"},
                            {meta, [call_id, from, cseq_num]}]),

    [{_, CallId3}, {_, From3}, {_, CSeq3}] = Values3,
    {ok, 200, []} = nksip_uac:options(client1, "sip:127.0.0.1", [
                        {add, "x-nk-op", "reply-stateless"},
                        {call_id, CallId3}, {from, From3}, {cseq_num, CSeq3}]),

    % Test bad extension endpoint and proxy
    {ok, 420, [{all_headers, Hds5}]} = nksip_uac:options(client1, "sip:127.0.0.1", [
                                           {add, "require", "a,b;c,d"}, 
                                           {meta, [all_headers]}]),
    % 'a' is supported because of app config
    [<<"b,d">>] = proplists:get_all_values(<<"unsupported">>, Hds5),
    
    {ok, 420, [{all_headers, Hds6}]} = nksip_uac:options(client1, "sip:a@external.com", [
                                            {add, "proxy-require", "a,b;c,d"}, 
                                            {route, "<sip:127.0.0.1;lr>"},
                                            {meta, [all_headers]}]),
    [<<"a,b,d">>] = proplists:get_all_values(<<"unsupported">>, Hds6),

    % Force invalid response
    logger:warning("Next warning about a invalid sipreply is expected"),
    {ok, 500,  [{reason_phrase, <<"Invalid Service Response">>}]} = 
        nksip_uac:options(client1, "sip:127.0.0.1", [
            {add, "x-nk-op", "reply-invalid"}, {meta, [reason_phrase]}]),
    ok.


auto() ->
    % Start a new server to test ping and register options
    % nksip:stop(server2),
    % ok = tests_util:start(server2, ?MODULE, [
    %     {plugins, [nksip_registrar]},
    %     {sip_listen, "sip:all:5080"},
    %     {sip_registrar_min_time, 1},
    %     {sip_uac_auto_register_timer, 1}
    % ]),
    timer:sleep(200),
    {error, service_not_found} = nksip_uac_auto_register:start_ping(none, ping1, "sip::a", []),
    {error, invalid_uri} = nksip_uac_auto_register:start_ping(client1, ping1, "sip::a", []),
    Ref = make_ref(),
    
    ok = nkservice:put(client1, callback, {Ref, self()}),
    
    {ok, true} = nksip_uac_auto_register:start_ping(client1, ping1, 
                                "<sip:127.0.0.1:5080;transport=tcp>", [{expires, 5}]),

    {error, service_not_found} = nksip_uac_auto_register:start_register(none, reg1, "sip::a", []),
    {error, invalid_uri} = nksip_uac_auto_register:start_register(client1, reg1, "sip::a", []),
    {ok, true} = nksip_uac_auto_register:start_register(client1, reg1, 
                                "<sip:127.0.0.1:5080;transport=tcp>", [{expires, 1}]),

    [{ping1, true, _}] = nksip_uac_auto_register:get_pings(client1),
    [{reg1, true, _}] = nksip_uac_auto_register:get_registers(client1),

    ok = tests_util:wait(Ref, [{ping, ping1, true}, {reg, reg1, true}]),

    logger:notice("Next notices about connection error to port 9999 are expected"),
    {ok, false} = nksip_uac_auto_register:start_ping(client1, ping2, 
                                            "<sip:127.0.0.1:9999;transport=tcp>",
                                            [{expires, 1}]),
    {ok, false} = nksip_uac_auto_register:start_register(client1, reg2, 
                                            "<sip:127.0.0.1:9999;transport=tcp>",
                                            [{expires, 1}]),
    ok = tests_util:wait(Ref, [{ping, ping2, false}, {reg, reg2, false}]),

    [{ping1, true,_}, {ping2, false,_}] = 
        lists:sort(nksip_uac_auto_register:get_pings(client1)),
    [{reg1, true,_}, {reg2, false,_}] = 
        lists:sort(nksip_uac_auto_register:get_registers(client1)),
    
    ok = nksip_uac_auto_register:stop_ping(client1, ping2),
    ok = nksip_uac_auto_register:stop_register(client1, reg2),

    [{ping1, true, _}] = nksip_uac_auto_register:get_pings(client1),
    [{reg1, true, _}] = nksip_uac_auto_register:get_registers(client1),

    ok = nksip_uac_auto_register:stop_ping(client1, ping1),
    ok = nksip_uac_auto_register:stop_register(client1, reg1),
    ok = nksip:stop(server2),
    timer:sleep(500),
    logger:notice("Next notice about connection error to port 5080 is expected"),
    {ok, false} = nksip_uac_auto_register:start_ping(client1, ping3, 
                                            "<sip:127.0.0.1:5080;transport=tcp>",
                                            [{expires, 1}]),
    ok = nksip_uac_auto_register:stop_ping(client1, ping3),
    [] = nksip_uac_auto_register:get_pings(client1),
    [] = nksip_uac_auto_register:get_registers(client1),
    ok.


timeout() ->
    SipC1 = "<sip:127.0.0.1:5070;transport=tcp>",

    % ok = nksip:update(client1, [{sipapp_timeout, 0.02}]),

    % % Client1 callback module has a 50msecs delay in route()
    % {ok, 500, [{reason_phrase, <<"No Server Response">>}]} = 
    %     nksip_uac:options(client2, SipC1, [{meta,[reason_phrase]}]),

    ok = nksip:update(client1, [{sip_timer_t1, 10}, {sip_timer_c, 1}]),

    Hd1 = {add, "x-nk-sleep", 2000},
    {ok, 408, [{reason_phrase, <<"No-INVITE Timeout">>}]} = 
        nksip_uac:options(client2, SipC1, [Hd1, {meta, [reason_phrase]}]),

    Hds2 = [{add, "x-nk-op", busy}, {add, "x-nk-sleep", 2000}],
    {ok, 408, [{reason_phrase, <<"Timer C Timeout">>}]} = 
        nksip_uac:invite(client2, SipC1, [{meta,[reason_phrase]}|Hds2]),
    ok.



%%%%%%%%%%%%%%%%%%%%%%%  CallBacks (servers and clients) %%%%%%%%%%%%%%%%%%%%%


service_init(#{name:=Id}, State) ->
    ok = nkservice:put(Id, domains, [<<"nksip">>, <<"127.0.0.1">>, <<"[::1]">>]),
    {ok, State}.


sip_route(Scheme, User, Domain, Req, _Call) ->
    case nksip_request:srv_name(Req) of
        {ok, server1} ->
            Opts = [record_route, {insert, "x-nk-server", server1}],
            Domains = nkservice:get(server1, domains),
            case lists:member(Domain, Domains) of
                true when User =:= <<>> ->
                    case nksip_request:header(<<"x-nk-op">>, Req) of
                        {ok, [<<"reply-request">>]} ->
                            Body = base64:encode(term_to_binary(Req)),
                            {reply, {ok, [{body, Body}, contact]}};
                        {ok, [<<"reply-stateless">>]} ->
                            {reply_stateless, ok};
                        {ok, [<<"reply-stateful">>]} ->
                            {reply, ok};
                        {ok, [<<"reply-invalid">>]} ->
                            {reply, 'INVALID'};
                        {ok, [<<"force-error">>]} ->
                            error(test_error);
                        {ok, _} ->
                            process
                    end;
                true when Domain =:= <<"nksip">> ->
                    case nksip_registrar:find(server1, Scheme, User, Domain) of
                        [] -> {reply, temporarily_unavailable};
                        UriList -> {reply, {proxy, UriList, Opts}}
                    end;
                _ ->
                    {proxy, ruri, Opts}
            end;
        _ ->
            timer:sleep(500),
            process
    end.


sip_invite(Req, _Call) ->
    tests_util:save_ref(Req),
    Op = case nksip_request:header(<<"x-nk-op">>, Req) of
        {ok, [Op0]} -> Op0;
        {ok, _} -> <<"decline">>
    end,
    Sleep = case nksip_request:header(<<"x-nk-sleep">>, Req) of
        {ok, [Sleep0]} -> nklib_util:to_integer(Sleep0);
        {ok, _} -> 0
    end,
    {ok, ReqId} = nksip_request:get_handle(Req),
    {ok, DialogId} = nksip_dialog:get_handle(Req),
    proc_lib:spawn(
        fun() ->
            case Sleep of
                0 -> ok;
                _ -> timer:sleep(Sleep)
            end,
            case Op of
                <<"ok">> ->
                    nksip_request:reply({ok, []}, ReqId);
                <<"answer">> ->
                    SDP = nksip_sdp:new("client2", 
                                            [{"test", 4321, [{rtpmap, 0, "codec1"}]}]),
                    nksip_request:reply({ok, [{body, SDP}]}, ReqId);
                <<"busy">> ->
                    nksip_request:reply(busy, ReqId);
                <<"increment">> ->
                    {ok, SDP1} = nksip_dialog:meta(invite_local_sdp, DialogId),
                    SDP2 = nksip_sdp:increment(SDP1),
                    nksip_request:reply({ok, [{body, SDP2}]}, ReqId);
                _ ->
                    nksip_request:reply(decline, ReqId)
            end
        end),
    noreply.


sip_options(Req, _Call) ->
    case nksip_request:header(<<"x-nk-sleep">>, Req) of
        {ok, [Sleep0]} -> 
            {ok, ReqId} = nksip_request:get_handle(Req),
            spawn(
                fun() ->
                    nksip_request:reply(101, ReqId), 
                    timer:sleep(nklib_util:to_integer(Sleep0)),
                    nksip_request:reply({ok, [contact]}, ReqId)
                end),
            noreply;
        {ok, _} ->
            {reply, {ok, [contact]}}
    end.


sip_uac_auto_register_updated_ping(PingId, OK, SrvId) ->
    {Ref, Pid} = nkservice:get(SrvId, callback, []),
    Pid ! {Ref, {ping, PingId, OK}},
    ok.


sip_uac_auto_register_updated_reg(RegId, OK, SrvId) ->
    {Ref, Pid} = nkservice:get(SrvId, callback, []),
    Pid ! {Ref, {reg, RegId, OK}},
    ok.






