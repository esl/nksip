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

%% @doc NkSIP Stats Plugin Callbacks
-module(nksip_stats_callbacks).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-include("../include/nksip.hrl").

-export([plugin_deps/0, plugin_start/2, plugin_stop/2]).
-export([nks_sip_transport_uas_sent/1]).



% ===================================================================
%% Plugin specific
%% ===================================================================

plugin_deps() ->
    [nksip].


plugin_start(Config, #{name:=Name}) ->
    case whereis(nksip_debug_srv) of
        undefined ->
            Child = {
                nksip_debug_srv,
                {nksip_debug_srv, start_link, []},
                permanent,
                5000,
                worker,
                [nksip_debug_srv]
            },
            {ok, _Pid} = supervisor:start_child(nksip_sup, Child);
        _ ->
            ok
    end,
    logger:info("Plugin ~p started (~s)", [?MODULE, Name]),
    {ok, Config}.


plugin_stop(Config, #{name:=Name}) ->
    logger:info("Plugin ~p stopped (~s)", [?MODULE, Name]),
    {ok, Config}.



% ===================================================================
%% SIP Core
%% ===================================================================

%% @doc Called when the transport has just sent a response
-spec nks_sip_transport_uas_sent(nksip:response()) ->
    continue.

nks_sip_transport_uas_sent(#sipmsg{start=Start}) ->
    Elapsed = nklib_util:l_timestamp()-Start,
    nksip_stats:response_time(Elapsed),
    continue.





