-module(presence_plugin_app).

-behaviour(application).

-emqx_plugin(?MODULE).

-export([
    start/2,
    stop/1
]).

start(_StartType, _StartArgs) ->
    {ok, Sup} = presence_plugin_sup:start_link(),
    presence_plugin:load(application:get_all_env()),

    emqx_ctl:register_command(presence_plugin, {presence_plugin_cli, cmd}),
    {ok, Sup}.

stop(_State) ->
    emqx_ctl:unregister_command(presence_plugin),
    presence_plugin:unload().
