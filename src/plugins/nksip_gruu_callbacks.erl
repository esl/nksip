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

%% @doc NkSIP GRUU Plugin Callbacks
-module(nksip_gruu_callbacks).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-include("../include/nksip.hrl").
-include("../include/nksip_call.hrl").
-include("nksip_registrar.hrl").
-export([plugin_deps/0, plugin_config/2, plugin_start/2, plugin_stop/2]).
-export([nks_sip_registrar_request_opts/2, nks_sip_registrar_update_regcontact/4,
         nks_sip_uac_response/4]).



%% ===================================================================
%% Plugin
%% ===================================================================

plugin_deps() ->
    [nksip, nksip_registrar].


plugin_config(Config, _Service) ->
    Supported1 = maps:get(sip_supported, Config, nksip_syntax:default_supported()),
    Supported2 = nklib_util:store_value(<<"gruu">>, Supported1),
    Config2 = Config#{sip_supported=>Supported2},
    {ok, Config2}.


plugin_start(Config, #{name:=Name}) ->
    logger:info("Plugin ~p started (~s)", [?MODULE, Name]),
    {ok, Config}.


plugin_stop(Config, #{name:=Name}) ->
    logger:info("Plugin ~p stopped (~s)", [?MODULE, Name]),
    Supported1 = maps:get(sip_supported, Config, []),
    Supported2 = Supported1 -- [<<"gruu">>],
    {ok, Config#{sip_supported=>Supported2}}.



%% ===================================================================
%% Specific
%% ===================================================================


%% @private
nks_sip_registrar_request_opts(#sipmsg{srv_id=SrvId, contacts=Contacts}=Req, Opts) ->
    case 
        lists:member(<<"gruu">>, ?GET_CONFIG(SrvId, supported)) andalso 
        nksip_sipmsg:supported(<<"gruu">>, Req)
    of
        true -> 
        	lists:foreach(
        		fun(Contact) -> nksip_gruu_lib:check_gr(Contact, Req) end,
        		Contacts),
        	{continue, [Req, [{gruu, true}|Opts]]};
        false -> 
        	{continue, [Req, Opts]}
    end.


%% @private
nks_sip_registrar_update_regcontact(RegContact, Base, Req, Opts) ->
	RegContact1 = nksip_gruu_lib:update_regcontact(RegContact, Base, Req, Opts),
    {continue, [RegContact1, Base, Req, Opts]}.


%% @private
nks_sip_uac_response(Req, Resp, UAC, Call) ->
    nksip_gruu_lib:update_gruu(Resp),
    {continue, [Req, Resp, UAC, Call]}.
