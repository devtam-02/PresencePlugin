-module(presence_plugin).

%% for #message{} record
%% no need for this include if we call emqx_message:to_map/1 to convert it to a map
-include_lib("emqx/include/emqx.hrl").
-include_lib("emqx/include/emqx_hooks.hrl").

%% for logging
-include_lib("emqx/include/logger.hrl").
-include("presence_plugin.hrl").

-export([
    load/1,
    unload/0
]).

-import(presence_plugin_config, [get_config_by_key/1]).

%% Client Lifecycle Hooks
-export([
    on_client_connect/3,
    on_client_connected/3,
    on_client_disconnected/4
]).

%% Message Pubsub Hooks
-export([
    on_message_publish/2,
    on_message_puback/5,
    on_message_delivered/3,
    on_message_acked/3,
    on_message_dropped/4
]).

%% Called when the plugin application start
load(Env) ->
    kafka_init(Env),
    hook('client.connect', {?MODULE, on_client_connect, [Env]}),
    hook('client.connected', {?MODULE, on_client_connected, [Env]}),
    hook('client.disconnected', {?MODULE, on_client_disconnected, [Env]}),
    hook('message.publish', {?MODULE, on_message_publish, [Env]}),
    hook('message.puback', {?MODULE, on_message_puback, [Env]}),
    hook('message.delivered', {?MODULE, on_message_delivered, [Env]}),
    hook('message.acked', {?MODULE, on_message_acked, [Env]}),
    hook('message.dropped', {?MODULE, on_message_dropped, [Env]}).

%%--------------------------------------------------------------------
%% Client Lifecycle Hooks
%%--------------------------------------------------------------------

on_client_connect(ConnInfo, Props, _Env) ->
    %% this is to demo the usage of EMQX's structured-logging macro
    %% * Recommended to always have a `msg` field,
    %% * Use underscore instead of space to help log indexers,
    %% * Try to use static fields
    ?SLOG(error, #{
        msg => "demo_log_msg_on_client_connect",
        conninfo => ConnInfo,
        props => Props
    }),
    send_presence_to_kafka(),
    %% If you want to refuse this connection, you should return with:
    %% {stop, {error, ReasonCode}}
    %% the ReasonCode can be found in the emqx_reason_codes.erl
    {ok, Props}.

on_client_connected(ClientInfo = #{clientid := ClientId}, ConnInfo, _Env) ->
    io:format(
        "Client(~s) connected, ClientInfo:~n~p~n, ConnInfo:~n~p~n",
        [ClientId, ClientInfo, ConnInfo]
    ),
    %% Gửi event đến Kafka
    send_presence_to_kafka().

on_client_disconnected(ClientInfo = #{clientid := ClientId}, ReasonCode, ConnInfo, _Env) ->
    io:format(
        "Client(~s) disconnected due to ~p, ClientInfo:~n~p~n, ConnInfo:~n~p~n",
        [ClientId, ReasonCode, ClientInfo, ConnInfo]
    ).

%%--------------------------------------------------------------------
%% Message PubSub Hooks
%%--------------------------------------------------------------------

%% Transform message and return
on_message_publish(Message = #message{topic = <<"$SYS/", _/binary>>}, _Env) ->
    {ok, Message};
on_message_publish(Message, _Env) ->
    io:format("Publish ~p~n", [emqx_message:to_map(Message)]),
    {ok, Message}.

on_message_puback(_PacketId, #message{topic = _Topic} = Message, _PubRes, RC, _Env) ->
    NewRC =
        case RC of
            %% Demo: some service do not want to expose the error code (129) to client;
            %% so here it remap 129 to 128
            129 -> 128;
            _ -> RC
        end,
    io:format(
        "Puback ~p RC: ~p~n",
        [emqx_message:to_map(Message), NewRC]
    ),
    {ok, NewRC}.

on_message_dropped(#message{topic = <<"$SYS/", _/binary>>}, _By, _Reason, _Env) ->
    ok;
on_message_dropped(Message, _By = #{node := Node}, Reason, _Env) ->
    io:format(
        "Message dropped by node ~p due to ~p:~n~p~n",
        [Node, Reason, emqx_message:to_map(Message)]
    ).

on_message_delivered(_ClientInfo = #{clientid := ClientId}, Message, _Env) ->
    io:format(
        "Message delivered to client(~s):~n~p~n",
        [ClientId, emqx_message:to_map(Message)]
    ),
    {ok, Message}.

on_message_acked(_ClientInfo = #{clientid := ClientId}, Message, _Env) ->
    io:format(
        "Message acked by client(~s):~n~p~n",
        [ClientId, emqx_message:to_map(Message)]
    ).

%% Called when the plugin application stop
unload() ->
    brod:stop_client(kafka_client),
    ?SLOG(info, "Kafka client stopped"),

    unhook('client.connect', {?MODULE, on_client_connect}),
    unhook('client.connected', {?MODULE, on_client_connected}),
    unhook('client.disconnected', {?MODULE, on_client_disconnected}),
    unhook('client.unsubscribe', {?MODULE, on_client_unsubscribe}),
    unhook('message.publish', {?MODULE, on_message_publish}),
    unhook('message.puback', {?MODULE, on_message_puback}),
    unhook('message.delivered', {?MODULE, on_message_delivered}),
    unhook('message.acked', {?MODULE, on_message_acked}),
    unhook('message.dropped', {?MODULE, on_message_dropped}).


kafka_init(_Env) ->
    ?SLOG(info, "Start to init kafka...... ~n"),
    {ok, _} = application:ensure_all_started(brod),
    KafkaHost = get_config_by_key(?KAFKA_HOST),
    KafkaPort = get_config_by_key(?KAFKA_PORT),
    KafkaPresenceTopic = iolist_to_binary(get_config_by_key(?KAFKA_PRESENCE_TOPIC)),
    ok = brod:start_client([{KafkaHost, KafkaPort}], kafka_client),
    ok = brod:start_producer(kafka_client, KafkaPresenceTopic, []),
    ?SLOG(info, "Init kafka successfully.....~n").

send_presence_to_kafka() ->
    try
        % Danh sách thông tin cần gửi
        MsgBody = [
            {type, <<"presence">>},
            {id, <<"213441">>},
            {sub, <<"asdaf">>},
            {clientId, <<"sdfsfg">>}
        ],
        {ok, Mb} = emqx_utils_json:safe_encode(MsgBody),
        Payload = iolist_to_binary(Mb),
        KafkaPresenceTopic = iolist_to_binary(get_config_by_key(?KAFKA_PRESENCE_TOPIC)),
        
        % Sử dụng pattern matching để bắt lỗi
        case brod:produce_cb(kafka_client, KafkaPresenceTopic, hash, "", Payload, fun(_,_) -> ok end) of
            {ok, _} -> ok;
            {error, Reason} -> 
                ?SLOG(error, #{
                    msg => "failed_to_send_to_kafka",
                    reason => Reason
                })
        end
    catch
        Class:Error ->
            ?SLOG(error, #{
                msg => "exception_in_send_presence_to_kafka",
                class => Class,
                error => Error
            })
    end.

hook(HookPoint, MFA) ->
    %% use highest hook priority so this module's callbacks
    %% are evaluated before the default hooks in EMQX
    emqx_hooks:add(HookPoint, MFA, _Property = ?HP_HIGHEST).

unhook(HookPoint, MFA) ->
    emqx_hooks:del(HookPoint, MFA).
