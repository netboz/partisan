%% -------------------------------------------------------------------
%%
%% Copyright (c) 2016 Christopher Meiklejohn.  All Rights Reserved.
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

%% -----------------------------------------------------------------------------
%% @doc This module realises the {@link partisan_peer_service_manager}
%% behaviour implementing a peer-to-peer partial mesh topology using the
%% <a href="https://bit.ly/3Hy7bfi">Hyparview membership protocol</a>.
%%
%% == Characteristics ==
%% <ul>
%% <li>Uses TCP/IP.</li>
%% <li>Nodes are considered "failed" when connection is dropped.</li>
%% <li>Nodes maintain partial views of the network. Every node will contain and
%% active view that forms a connected grah, and a passive view of backup links
%% are used to repair graph connectivity under failure. Some links to passive
%% nodes are kept open for fast replacement of failed nodes in the active
%% view. So the view is probabilistic. </li>
%% <li>The algorithm constantly works towards and ensures that eventually the
%% membership is a fully-connected component. </li>
%% <li>Point-to-point messaging for connected nodes with a minimum of 1 hop via
%% transitive message delivery (as not all nodes directly connected). Delivery
%% is probabilistic.</li>
%% <li>Scalability to up-to 2,000 nodes.</li>
%% </ul>
%%
%% @end
%% -----------------------------------------------------------------------------
-module(partisan_hyparview_peer_service_manager).
-author("Christopher S. Meiklejohn <christopher.meiklejohn@gmail.com>").

-behaviour(gen_server).
-behaviour(partisan_peer_service_manager).

-include("partisan_logger.hrl").
-include("partisan.hrl").

-define(DEFAULT_PASSIVE_VIEW_MAINTENANCE_INTERVAL, 10000).
-define(RANDOM_PROMOTION_INTERVAL, 5000).

%% partisan_peer_service_manager callbacks
-export([cast_message/2]).
-export([cast_message/3]).
-export([cast_message/4]).
-export([decode/1]).
-export([forward_message/2]).
-export([forward_message/3]).
-export([forward_message/4]).
-export([get_local_state/0]).
-export([inject_partition/2]).
-export([join/1]).
-export([leave/0]).
-export([leave/1]).
-export([members/0]).
-export([members_for_orchestration/0]).
-export([myself/0]).
-export([on_down/2]).
-export([on_up/2]).
-export([partitions/0]).
-export([receive_message/2]).
-export([reserve/1]).
-export([resolve_partition/1]).
-export([send_message/2]).
-export([start_link/0]).
-export([sync_join/1]).
-export([update_members/1]).

%% debug.
-export([active/0,
         active/1,
         passive/0]).

%% gen_server callbacks
-export([init/1,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         terminate/2,
         code_change/3]).

%% temporary exceptions
-export([delete_state_from_disk/0]).

-type active() :: sets:set(node_spec()).
-type passive() :: sets:set(node_spec()).
-type reserved() :: dict:dict(atom(), node_spec()).
-type tag() :: atom().
%% The epoch indicates how many times the node is restarted.
-type epoch() :: non_neg_integer().
%% The epoch_count indicates how many disconnect messages are generated.
-type epoch_count() :: non_neg_integer().
-type message_id() :: {epoch(), epoch_count()}.
-type message_id_store() :: dict:dict(node_spec(), message_id()).

-record(state, {myself :: node_spec(),
                active :: active(),
                passive :: passive(),
                reserved :: reserved(),
                out_links :: list(),
                tag :: tag(),
                max_active_size :: non_neg_integer(),
                min_active_size :: non_neg_integer(),
                max_passive_size :: non_neg_integer(),
                epoch :: epoch(),
                sent_message_map :: message_id_store(),
                recv_message_map :: message_id_store(),
                partitions :: partitions()}).

-type state_t() :: #state{}.

%%%===================================================================
%%% partisan_peer_service_manager callbacks
%%%===================================================================

%% @doc Same as start_link([]).
-spec start_link() -> {ok, pid()} | ignore | {error, term()}.
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% @doc Return membership list.
members() ->
    gen_server:call(?MODULE, members, infinity).

%% @doc Return membership list.
members_for_orchestration() ->
    gen_server:call(?MODULE, members_for_orchestration, infinity).

%% @doc Return myself.
myself() ->
    partisan:node_spec().

%% @doc Return local node's view of cluster membership.
get_local_state() ->
    gen_server:call(?MODULE, get_local_state, infinity).

%% @doc Register a trigger to fire when a connection drops.
on_down(_Name, _Function) ->
    {error, not_implemented}.

%% @doc Register a trigger to fire when a connection opens.
on_up(_Name, _Function) ->
    {error, not_implemented}.

%% @doc Update membership.
update_members(_Nodes) ->
    {error, not_implemented}.


%% -----------------------------------------------------------------------------
%% @doc Send message to a remote peer service manager.
%% @end
%% -----------------------------------------------------------------------------
send_message(Name, Message) ->
    Cmd = {send_message, Name, Message},
    gen_server:call(?MODULE, Cmd, infinity).


%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec cast_message(
    Term :: partisan_remote_ref:p() | partisan_remote_ref:n() | pid(),
    MEssage :: message()) -> ok.

cast_message(Term, Message) ->
    FullMessage = {'$gen_cast', Message},
    forward_message(Term, FullMessage, #{}).


%% -----------------------------------------------------------------------------
%% @doc Cast a message to a remote gen_server.
%% @end
%% -----------------------------------------------------------------------------
cast_message(Node, ServerRef, Message) ->
    cast_message(Node, ServerRef, Message, #{}).


%% -----------------------------------------------------------------------------
%% @doc Cast a message to a remote gen_server.
%% @end
%% -----------------------------------------------------------------------------
cast_message(Node, ServerRef, Message, Options) ->
    FullMessage = {'$gen_cast', Message},
    forward_message(Node, ServerRef, FullMessage, Options).


%% -----------------------------------------------------------------------------
%% @doc Gensym support for forwarding.
%% @end
%% -----------------------------------------------------------------------------
forward_message(Term, Message) ->
    forward_message(Term, Message, #{}).


%% -----------------------------------------------------------------------------
%% @doc Gensym support for forwarding.
%% @end
%% -----------------------------------------------------------------------------
forward_message(Pid, Message, Opts) when is_pid(Pid) ->
    forward_message(partisan:node(), Pid, Message, Opts);

forward_message(RemoteRef, Message, Opts) ->
    partisan_remote_ref:is_pid(RemoteRef)
        orelse partisan_remote_ref:is_name(RemoteRef)
        orelse error(badarg),

    Node = partisan_remote_ref:node(RemoteRef),
    Target = partisan_remote_ref:target(RemoteRef),

    forward_message(Node, Target, Message, Opts).



%% -----------------------------------------------------------------------------
%% @doc Forward message to registered process on the remote side.
%% @end
%% -----------------------------------------------------------------------------
forward_message(Node, ServerRef, Message, Opts) when is_list(Opts) ->
    forward_message(Node, ServerRef, Message, maps:from_list(Opts));

forward_message(Node, ServerRef, Message, Options)
when is_map(Options) ->
    ?LOG_TRACE(#{
        description => "About to send message",
        node => partisan:node(),
        process => ServerRef,
        message => Message
    }),

    %% We ignore channel -> Why?
    FullMessage = {forward_message, Node, ServerRef, Message, Options},

    %% Attempt to fast-path through the memoized connection cache.
    case partisan_peer_connections:dispatch(FullMessage) of
        ok ->
            ok;
        {error, _} ->
            gen_server:call(?MODULE, FullMessage, infinity)
    end.


%% @doc Receive message from a remote manager.
receive_message(Peer, {forward_message, ServerRef, Message} = FullMessage) ->

    case partisan_config:get(disable_fast_receive, true) of
        true ->
            gen_server:call(?MODULE, {receive_message, Peer, FullMessage}, infinity);
        false ->
            partisan_peer_service_manager:process_forward(ServerRef, Message)
    end;
receive_message(Peer, Message) ->
    ?LOG_TRACE(#{
        description => "Manager received message from peer",
        peer_node => Peer,
        message => Message
    }),

    Result = gen_server:call(?MODULE, {receive_message, Message}, infinity),

    ?LOG_TRACE(#{
        description => "Processed message from peer",
        peer_node => Peer,
        message => Message
    }),

    Result.

%% @doc Attempt to join a remote node.
join(Node) ->
    gen_server:call(?MODULE, {join, Node}, infinity).

%% @doc Attempt to join a remote node.
sync_join(_Node) ->
    {error, not_implemented}.

%% @doc Leave the cluster.
leave() ->
    gen_server:call(?MODULE, {leave, partisan:node()}, infinity).

%% @doc Remove another node from the cluster.
leave(Node) ->
    gen_server:call(?MODULE, {leave, Node}, infinity).

%% @doc Reserve a slot for the particular tag.
reserve(Tag) ->
    gen_server:call(?MODULE, {reserve, Tag}, infinity).

%% @doc Inject a partition.
inject_partition(Origin, TTL) ->
    gen_server:call(?MODULE, {inject_partition, Origin, TTL}, infinity).

%% @doc Resolve a partition.
resolve_partition(Reference) ->
    gen_server:call(?MODULE, {resolve_partition, Reference}, infinity).

%% @doc Return partitions.
partitions() ->
    gen_server:call(?MODULE, partitions, infinity).

%%%===================================================================
%%% debugging callbacks
%%%===================================================================

%% @doc Debugging.
active() ->
    gen_server:call(?MODULE, active, infinity).

%% @doc Debugging.
active(Tag) ->
    gen_server:call(?MODULE, {active, Tag}, infinity).

%% @doc Debugging.
passive() ->
    gen_server:call(?MODULE, passive, infinity).

%% @doc Decode state.
decode({state, Active, _Epoch}) ->
    sets:to_list(Active);
decode(Active) ->
    sets:to_list(Active).


%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

%% @private
-spec init([]) -> {ok, state_t()}.
init([]) ->
    %% Seed the random number generator.
    partisan_config:seed(),

    ok = partisan_peer_connections:init(),

    %% Set logger metadata
    logger:set_process_metadata(#{node => partisan:node()}),

    %% Process connection exits.
    process_flag(trap_exit, true),

    Epoch = maybe_load_epoch_from_disk(),

    Myself = myself(),
    Active = sets:add_element(Myself, sets:new()),
    Passive = sets:new(),

    SentMessageMap = dict:new(),
    RecvMessageMap = dict:new(),

    %% Partitions.
    Partitions = [],

    %% Get the default configuration.
    MaxActiveSize = partisan_config:get(max_active_size, 6),
    MinActiveSize = partisan_config:get(min_active_size, 3),
    MaxPassiveSize = partisan_config:get(max_passive_size, 30),

    %% Get tag, if set.
    Tag = partisan_config:get(tag, undefined),

    %% Reserved server slots.
    Reservations = partisan_config:get(reservations, []),
    Reserved = dict:from_list([{T, undefined} || T <- Reservations]),

    %% Schedule periodic maintenance of the passive view.
    schedule_passive_view_maintenance(),

    %% Schedule tree peers refresh.
    schedule_tree_refresh(),

    %% Schedule periodic random promotion when it is enabled.
    case partisan_config:get(random_promotion, true) of
        true ->
            schedule_random_promotion();
        false ->
            ok
    end,

    %% Verify we don't have too many reservations.
    case length(Reservations) > MaxActiveSize of
        true ->
            {stop, reservation_limit_exceeded};
        false ->
            {ok, #state{myself=Myself,
                        active=Active,
                        passive=Passive,
                        reserved=Reserved,
                        tag=Tag,
                        out_links=[],
                        max_active_size=MaxActiveSize,
                        min_active_size=MinActiveSize,
                        max_passive_size=MaxPassiveSize,
                        epoch=Epoch + 1,
                        sent_message_map=SentMessageMap,
                        recv_message_map=RecvMessageMap,
                        partitions=Partitions}}
    end.

%% @private
-spec handle_call(term(), {pid(), term()}, state_t()) ->
    {reply, term(), state_t()}.

handle_call(partitions, _From, #state{partitions=Partitions}=State) ->
    {reply, {ok, Partitions}, State};

handle_call({leave, _Node}, _From, State) ->
    {reply, error, State};

handle_call({join, #{name := _Name} = Node}, _From, State) ->
    gen_server:cast(?MODULE, {join, Node}),
    {reply, ok, State};

handle_call({resolve_partition, Reference}, _From, State) ->
    Partitions = handle_partition_resolution(Reference, State),
    {reply, ok, State#state{partitions=Partitions}};

handle_call({inject_partition, Origin, TTL}, _From, #state{myself=Myself}=State) ->
    Reference = make_ref(),

    ?LOG_DEBUG(#{
        description => "Injecting partition",
        origin => Origin,
        myself => Myself,
        ttl => TTL
    }),

    case Origin of
        Myself ->
            Partitions = handle_partition_injection(Reference, Origin, TTL, State),
            {reply, {ok, Reference}, State#state{partitions=Partitions}};
        _ ->
            Result = do_send_message(
                Origin,
                {inject_partition, Reference, Origin, TTL}
            ),

            case Result of
                {error, Error} ->
                    {reply, {error, Error}, State};
                ok ->
                    {reply, {ok, Reference}, State}
            end
    end;

handle_call({reserve, Tag}, _From,
            #state{reserved=Reserved0,
                   max_active_size=MaxActiveSize}=State) ->
    Present = dict:fetch_keys(Reserved0),

    case length(Present) < MaxActiveSize of
        true ->
            Reserved = case lists:member(Tag, Present) of
                true ->
                    Reserved0;
                false ->
                    dict:store(Tag, undefined, Reserved0)
            end,
            {reply, ok, State#state{reserved=Reserved}};
        false ->
            {reply, {error, no_available_slots}, State}
    end;

handle_call(active, _From, #state{active=Active}=State) ->
    {reply, {ok, Active}, State};

handle_call({active, Tag},
            _From,
            #state{reserved=Reserved}=State) ->
    Result = case dict:find(Tag, Reserved) of
        {ok, #{name := Peer}} ->
            {ok, Peer};
        {ok, undefined} ->
            {ok, undefined};
        error ->
            error
    end,
    {reply, Result, State};

handle_call(passive, _From, #state{passive=Passive}=State) ->
    {reply, {ok, Passive}, State};

handle_call({send_message, Name, Message}, _From, #state{}=State) ->
    Result = do_send_message(Name, Message),
    {reply, Result, State};

handle_call({forward_message, Name, ServerRef, Message, Options}, _From,
            #state{partitions=Partitions}=State) ->
    IsPartitioned = lists:any(fun(#{name := N}) ->
                                      case N of
                                          Name ->
                                              true;
                                          _ ->
                                              false
                                      end
                              end, Partitions),
    case IsPartitioned of
        true ->
            {reply, {error, partitioned}, State};
        false ->
            Result = do_send_message(
                Name,
                {forward_message, ServerRef, Message},
                Options
            ),
            {reply, Result, State}
    end;

handle_call({receive_message, Message}, _From, State) ->
    gen_server:cast(?MODULE, {receive_message, Message}),
    {reply, ok, State};

handle_call(members, _From, #state{myself=Myself,
                                   active=Active}=State) ->
    ?LOG_DEBUG(#{
        description => "Node active view",
        myself => Myself,
        members => members(Active)
    }),
    ActiveMembers = [P || #{name := P} <- members(Active)],
    {reply, {ok, ActiveMembers}, State};

handle_call(members_for_orchestration, _From, #state{active=Active}=State) ->
    {reply, {ok, members(Active)}, State};

handle_call(get_local_state, _From, #state{active=Active,
                                           epoch=Epoch}=State) ->
    {reply, {ok, {state, Active, Epoch}}, State};

handle_call(connections, _From,
            #state{myself=Myself, active=Active}=State) ->
    %% get a list of all the client connections to the various peers of the active view
    Cs = lists:map(
        fun(Peer) ->
            Pids = partisan_peer_connections:processes(Peer),
            ?LOG_DEBUG(#{
                description => "Peer connection processes",
                peer_node => Peer,
                connection_processes => Pids
            }),
            {Peer, Pids}
        end,
        members(Active) -- [Myself]
    ),
    {reply, {ok, Cs}, State};

handle_call(Event, _From, State) ->
    ?LOG_WARNING(#{description => "Unhandled call event", event => Event}),
    {reply, ok, State}.

%% @private
-spec handle_cast(term(), state_t()) -> {noreply, state_t()}.

handle_cast({join, Peer},
            #state{myself=Myself0,
                   tag=Tag0,
                   epoch=Epoch0}=State0) ->
    %% Trigger connection.
    ok = partisan_util:maybe_connect(Peer),

    ?LOG_DEBUG(#{
        description => "Sending JOIN message",
        node => Myself0,
        peer_node => Peer
    }),

    %% Send the JOIN message to the peer.
    do_send_message(Peer, {join, Myself0, Tag0, Epoch0}),

    %% Return.
    {noreply, State0};

handle_cast({receive_message, Message}, State0) ->
    handle_message(Message, State0);

%% @doc Handle disconnect messages.
handle_cast({disconnect, Peer}, #state{active=Active0}=State0) ->
    case sets:is_element(Peer, Active0) of
        true ->
            %% If a member of the active view, remove it.
            Active = sets:del_element(Peer, Active0),
            State = add_to_passive_view(Peer,
                                        State0#state{active=Active}),
            ok = disconnect(Peer),
            {noreply, State};
        false ->
            {noreply, State0}
    end;

handle_cast(Event, State) ->
    ?LOG_WARNING(#{description => "Unhandled cast event", event => Event}),
    {noreply, State}.

%% @private
-spec handle_info(term(), state_t()) -> {noreply, state_t()}.

handle_info(random_promotion, #state{myself=Myself,
                                     active=Active0,
                                     passive=Passive,
                                     reserved=Reserved0,
                                     min_active_size=MinActiveSize0}=State0) ->
    State = case has_reached_the_limit({active, Active0, Reserved0},
                                       MinActiveSize0) of
                true ->
                    %% Do nothing if the active view reaches the MinActiveSize.
                    State0;
                false ->
                    RandomPeer = select_random(Passive, [Myself]),
                    move_peer_from_passive_to_active(RandomPeer, State0)
            end,

    %% Schedule periodic random promotion.
    schedule_random_promotion(),

    {noreply, State};

handle_info(tree_refresh, #state{}=State) ->
    %% Get lazily computed outlinks.
    OutLinks = retrieve_outlinks(),

    %% Reschedule.
    schedule_tree_refresh(),

    {noreply, State#state{out_links=OutLinks}};

handle_info(passive_view_maintenance,
            #state{myself=Myself,
                   active=Active,
                   passive=Passive}=State0) ->
    Exchange0 = %% Myself.
                [Myself] ++

                % Random members of the active list.
                select_random_sublist(Active, k_active()) ++

                %% Random members of the passive list.
                select_random_sublist(Passive, k_passive()),

    Exchange = lists:usort(Exchange0),

    %% Select random member of the active list.
    State = case select_random(Active, [Myself]) of
                undefined ->
                    State0;
                Random ->
                    %% Trigger connection.
                    ok = partisan_util:maybe_connect(Random),

                    %% Forward shuffle request.
                    do_send_message(
                        Random, {shuffle, Exchange, arwl(), Myself}
                    ),

                    State0
            end,

    %% Schedule periodic maintenance of the passive view.
    schedule_passive_view_maintenance(),

    {noreply, State};

handle_info({'EXIT', From, Reason}, State0) ->
    ?LOG_DEBUG(#{
        description => "Connection process died active view",
        process => From,
        reason => Reason
    }),

    #state{
        myself = Myself,
        active = Active0,
        passive = Passive0
    } = State0,

    %% Prune active connections from dictionary.
    try partisan_peer_connections:prune(From) of
        {Peer, _Connections} ->

            %% If it was in the passive view and our connection attempt failed,
            %% remove from the passive view altogether.
            Passive = case is_in_passive_view(Peer, Passive0) of
                true ->
                    remove_from_passive_view(Peer, Passive0);
                false ->
                    Passive0
            end,

            %% If it was in the active view and our connection attempt failed,
            %% remove from the active view altogether.
            {Active, RemovedFromActive} =
                case is_in_active_view(Peer, Active0) of
                    true ->
                        {remove_from_active_view(Peer, Active0), true};
                    false ->
                        {Active0, false}
                end,

            State = case RemovedFromActive of
                true ->
                    RandomPeer = select_random(Passive, [Myself]),
                    move_peer_from_passive_to_active(
                        RandomPeer, State0#state{active=Active, passive=Passive}
                    );
                false ->
                    State0#state{active=Active, passive=Passive}
            end,

            ?LOG_DEBUG(#{
                description => "Active view",
                myself => Myself,
                active_view => members(State#state.active)
            }),

            {noreply, State}
    catch
        error:badarg ->
            {noreply, State0}
    end;

handle_info(
    {connected, Peer, _Channel, _Tag, _PeerEpoch, _RemoteState}, State) ->
    ?LOG_DEBUG(#{
        description => "Node is now connected",
        peer_node => Peer
    }),

    {noreply, State};

handle_info(Event, State) ->
    ?LOG_WARNING(#{description => "Unhandled info event", event => Event}),
    {noreply, State}.

%% @private
-spec terminate(term(), state_t()) -> term().
terminate(_Reason, _State) ->
    Fun =
        fun(_Info, Connections) ->
            lists:foreach(
              fun(Connection) ->
                    Pid = partisan_peer_connections:pid(Connection),
                    catch gen_server:stop(Pid, normal, infinity),
                    ok
              end,
              Connections
            )
         end,
    partisan_peer_connections:foreach(Fun),
    ok.

%% @private
-spec code_change(term() | {down, term()}, state_t(), term()) -> {ok, state_t()}.
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

%% @private
handle_message({resolve_partition, Reference}, State) ->
    Partitions = handle_partition_resolution(Reference, State),
    {noreply, State#state{partitions=Partitions}};

%% @private
handle_message({inject_partition, Reference, Origin, TTL}, State) ->
    Partitions = handle_partition_injection(Reference, Origin, TTL, State),
    {noreply, State#state{partitions=Partitions}};

%% @private
handle_message({join, Peer, PeerTag, PeerEpoch},
               #state{myself=Myself0,
                      active=Active0,
                      tag=Tag0,
                      sent_message_map=SentMessageMap0,
                      recv_message_map=RecvMessageMap0}=State0) ->
    ?LOG_DEBUG(#{
        description => "Node is now connected",
        myself => Myself0,
        peer_node => Peer,
        peer_epoch => PeerEpoch
    }),

    IsAddable = is_addable(PeerEpoch, Peer, SentMessageMap0),
    NotInActiveView = not sets:is_element(Peer, Active0),
    State = case IsAddable andalso NotInActiveView of
        true ->
            ?LOG_DEBUG(#{
                description => "Adding peer node to the active view",
                peer_node => Peer
            }),
            %% Establish connections.
            ok = partisan_util:maybe_connect(Peer),
            Connected = partisan_peer_connections:is_connected(Peer),
            case Connected of
                true ->
                    %% only find the peer connection will add the peer to the active
                    %% Add to active view.
                    State1 = add_to_active_view(Peer, PeerTag, State0),
                    LastDisconnectId = get_current_id(Peer, RecvMessageMap0),
                    %% Send the NEIGHBOR message to origin, that will update it's view.
                    do_send_message(
                        Peer,
                        {neighbor, Myself0, Tag0, LastDisconnectId, Peer}
                    ),

                    %% Random walk for forward join.
                    %% Since we might have dropped peers from the active view when
                    %% adding this one we need to use the most up to date active view,
                    %% and that's the one that's currently in the state
                    %% also disregard the the new joiner node
                    Peers =
                        (members(State1#state.active) -- [Myself0]) -- [Peer],

                    ok = lists:foreach(
                        fun(P) ->
                            %% Establish connections.
                            ok = partisan_util:maybe_connect(P),

                            ?LOG_DEBUG(#{
                                description => "Forwarding join of to active view peer",
                                from => Peer,
                                to => P
                            }),

                            Message = {
                                forward_join,
                                Peer, PeerTag, PeerEpoch, arwl(), Myself0
                            },

                            do_send_message(P, Message),

                            ok
                        end,
                        Peers
                    ),

                    ?LOG_DEBUG(#{
                        description => "Active view",
                        myself => Myself0,
                        active_view => members(State1#state.active)
                    }),

                    %% Notify with event.
                    notify(State1),

                    %% Return.
                    State1;
                false ->
                    State0
            end;
        false ->
            ?LOG_DEBUG(#{
                description => "Peer node will not be added to the active view",
                peer_node => Peer
            }),
            State0
    end,

    {noreply, State};

%% @private
handle_message({neighbor, Peer, PeerTag, DisconnectId, _Sender},
               #state{myself=Myself0,
                      sent_message_map=SentMessageMap0}=State0) ->
    ?LOG_DEBUG(#{
        description => "Node received the NEIGHBOR message from peer",
        myself => Myself0,
        peer_node => Peer,
        peer_tag =>  PeerTag
    }),

    State = case is_addable(DisconnectId, Peer, SentMessageMap0) of
                true ->
                    %% Establish connections.
                    ok = partisan_util:maybe_connect(Peer),
                    Connected = partisan_peer_connections:is_connected(Peer),

                    case Connected of
                        true ->
                            %% Add node into the active view.
                            State1 = add_to_active_view(
                                Peer, PeerTag, State0
                            ),
                            ?LOG_DEBUG(#{
                                description => "Active view",
                                myself => Myself0,
                                active_view => members(State1#state.active)
                            }),
                            State1;
                        false ->
                            State0
                    end;
                false ->
                    State0
            end,

    %% Notify with event.
    notify(State),

    {noreply, State};

%% @private
handle_message({forward_join, Peer, PeerTag, PeerEpoch, TTL, Sender},
               #state{myself=Myself0,
                      active=Active0,
                      tag=Tag0,
                      sent_message_map=SentMessageMap0,
                      recv_message_map=RecvMessageMap0}=State0) ->
    ?LOG_DEBUG("Node ~p received the FORWARD_JOIN message from ~p about ~p",
               [Myself0, Sender, Peer]),

    ActiveViewSize = sets:size(Active0),
    State = case TTL =:= 0 orelse ActiveViewSize =:= 1 of
        true ->
            ?LOG_DEBUG("FORWARD_JOIN: ttl(~p) expired or only one peer in active view (~p), "
                       "adding ~p tagged ~p to active view",
                       [TTL, ActiveViewSize, Peer, PeerTag]),

            IsAddable0 = is_addable(PeerEpoch, Peer, SentMessageMap0),
            NotInActiveView0 = not sets:is_element(Peer, Active0),
            case IsAddable0 andalso NotInActiveView0 of
                true ->
                    %% Establish connections.
                    ok = partisan_util:maybe_connect(Peer),

                    Connected = partisan_peer_connections:is_connected(Peer),

                    case Connected of
                        true ->
                            %% Add to our active view.
                            State1 = add_to_active_view(Peer, PeerTag, State0),

                            LastDisconnectId = get_current_id(Peer, RecvMessageMap0),
                            %% Send neighbor message to origin, that will update it's view.
                            Message = {
                                neighbor,
                                Myself0, Tag0, LastDisconnectId, Peer
                            },

                            do_send_message(Peer, Message),

                            ?LOG_DEBUG(#{
                                description => "Active view",
                                myself => Myself0,
                                active_view => members(State1#state.active)
                            }),

                            State1;
                        false ->
                            State0
                    end;
                false ->
                    ?LOG_DEBUG("Peer node ~p will not be added to the active view",
                               [Peer]),
                    State0
            end;
        false ->
            %% If we run out of peers before we hit the PRWL, that's
            %% fine, because exchanges between peers will eventually
            %% repair the passive view during shuffles.
            State2 = case TTL =:= prwl() of
                         true ->
                             ?LOG_DEBUG("FORWARD_JOIN: Passive walk ttl expired, adding ~p to "
                                        "the passive view", [Peer]),
                             add_to_passive_view(Peer, State0);
                         false ->
                             State0
                     end,

            %% Don't forward the join to the sender, ourself, or the joining peer.
            case select_random(Active0, [Sender, Myself0, Peer]) of
                undefined ->
                    IsAddable1 = is_addable(PeerEpoch, Peer, SentMessageMap0),
                    NotInActiveView1 = not sets:is_element(Peer, Active0),
                    case IsAddable1 andalso NotInActiveView1 of
                        true ->
                            ?LOG_DEBUG("FORWARD_JOIN: No node for forward, adding ~p to active view",
                                      [Peer]),
                            %% Establish connections.
                            ok = partisan_util:maybe_connect(Peer),

                            Connected = partisan_peer_connections:is_connected(
                                Peer
                            ),

                            case Connected of
                                true ->
                                    %% Add to our active view.
                                    State3 = add_to_active_view(
                                        Peer, PeerTag, State2
                                    ),
                                    LastDisconnectId = get_current_id(Peer, RecvMessageMap0),
                                    %% Send neighbor message to origin, that will
                                    %% update it's view.
                                    Message = {
                                        neighbor,
                                        Myself0, Tag0, LastDisconnectId, Peer
                                    },
                                    do_send_message(Peer, Message),

                                    ?LOG_DEBUG(#{
                                        description => "Active view",
                                        myself => Myself0,
                                        active_view => members(State3#state.active)
                                    }),

                                    State3;
                                false ->
                                    State0
                            end;
                        false ->
                            ?LOG_DEBUG("Peer node ~p will not be added to the active view",
                                       [Peer]),
                            State2
                    end;
                Random ->
                    %% Establish any new connections.
                    ok = partisan_util:maybe_connect(Random),

                    ?LOG_DEBUG("FORWARD_JOIN: forwarding to ~p",
                               [Random]),

                    Message =
                    {forward_join, Peer, PeerTag, PeerEpoch, TTL - 1, Myself0},

                    %% Forward join.
                    do_send_message(Random, Message),

                    State2
            end
    end,

    %% Notify with event.
    notify(State),

    {noreply, State};

%% @private
handle_message({disconnect, Peer, DisconnectId},
               #state{myself=Myself0,
                      active=Active0,
                      passive=Passive,
                      recv_message_map=RecvMessageMap0}=State0) ->
    ?LOG_DEBUG("Node ~p received the DISCONNECT message from ~p with ~p",
               [Myself0, Peer, DisconnectId]),

    case is_valid_disconnect(Peer, DisconnectId, RecvMessageMap0) of
        false ->
            %% Ignore the older disconnect message.
            {noreply, State0};
        true ->
            %% Remove from active
            Active = sets:del_element(Peer, Active0),

            ?LOG_DEBUG(#{
                description => "Active view",
                myself => Myself0,
                active_view => members(Active)
            }),

            %% Add to passive view.
            State1 = add_to_passive_view(Peer,
                                         State0#state{active=Active}),

            %% Update the AckMessageMap.
            RecvMessageMap = dict:store(Peer, DisconnectId, RecvMessageMap0),

            %% Trigger disconnection.
            ok = disconnect(Peer),

            State = case sets:size(Active) == 1 of
                        true ->
                            %% the peer that disconnected us just got moved to the
                            %% passive view, exclude it when selecting a new one to
                            %% move back into the active view
                            RandomPeer = select_random(Passive, [Myself0, Peer]),
                            ?LOG_DEBUG("Node ~p is isolated, moving random peer ~p from passive "
                                       "to active view",
                                       [RandomPeer, Myself0]),
                            move_peer_from_passive_to_active(RandomPeer,
                                State1#state{recv_message_map=RecvMessageMap});
                        false ->
                            State1#state{recv_message_map=RecvMessageMap}
                    end,

            {noreply, State}
    end;

%% @private
handle_message({neighbor_request, Peer, Priority, PeerTag, DisconnectId, Exchange},
               #state{myself=Myself0,
                      active=Active0,
                      passive=Passive0,
                      tag=Tag0,
                      sent_message_map=SentMessageMap0,
                      recv_message_map=RecvMessageMap0}=State0) ->
    ?LOG_DEBUG("Node ~p received the NEIGHBOR_REQUEST message from ~p with ~p",
               [Myself0, Peer, DisconnectId]),

    %% Establish connections.
    ok = partisan_util:maybe_connect(Peer),

    Exchange_Ack0 = %% Myself.
                    [Myself0] ++

                    % Random members of the active list.
                    select_random_sublist(Active0, k_active()) ++

                    %% Random members of the passive list.
                    select_random_sublist(Passive0, k_passive()),

    Exchange_Ack = lists:usort(Exchange_Ack0),

    State2 =
        case neighbor_acceptable(Priority, PeerTag, State0) of
            true ->
                case is_addable(DisconnectId, Peer, SentMessageMap0) of
                    true ->
                        Connected = partisan_peer_connections:is_connected(
                            Peer
                        ),
                        case Connected of
                            true ->
                                ?LOG_DEBUG("Node ~p accepted neighbor peer ~p",
                                            [Myself0, Peer]),
                                LastDisconnectId = get_current_id(Peer, RecvMessageMap0),
                                %% Reply to acknowledge the neighbor was accepted.
                                do_send_message(
                                  Peer,
                                  {neighbor_accepted, Myself0, Tag0, LastDisconnectId, Exchange_Ack}),

                                State1 = add_to_active_view(
                                    Peer, PeerTag, State0
                                ),
                                ?LOG_DEBUG(#{
                                    description => "Active view",
                                    myself => Myself0,
                                    active_view => members(State1#state.active)
                                }),

                                State1;
                            false ->
                                %% the connections does not change, the peer can not be connected
                                State0
                        end;
                    false ->
                        ?LOG_DEBUG("Node ~p rejected neighbor peer ~p",
                                   [Myself0, Peer]),
                        %% Reply to acknowledge the neighbor was rejected.
                        do_send_message(Peer,
                                        {neighbor_rejected, Myself0, Exchange_Ack}),

                        State0
                end;
            false ->
                ?LOG_DEBUG("Node ~p rejected neighbor peer ~p",
                           [Myself0, Peer]),
                %% Reply to acknowledge the neighbor was rejected.
                do_send_message(Peer, {neighbor_rejected, Myself0}),

                State0
        end,

    State = merge_exchange(Exchange, State2),

    %% Notify with event.
    notify(State),

    {noreply, State};

%% @private
handle_message({neighbor_rejected, Peer, Exchange},
               #state{myself=Myself0} = State0) ->
    ?LOG_DEBUG("Node ~p received the NEIGHBOR_REJECTED message from ~p",
               [Myself0, Peer]),

    %% Trigger disconnection.
    ok = disconnect(Peer),

    State = merge_exchange(Exchange, State0),

    {noreply, State};

%% @private
handle_message({neighbor_accepted, Peer, PeerTag, DisconnectId, Exchange},
               #state{myself=Myself0,
                      sent_message_map=SentMessageMap0} = State0) ->
    ?LOG_DEBUG("Node ~p received the NEIGHBOR_ACCEPTED message from ~p with ~p",
               [Myself0, Peer, DisconnectId]),

    State1 = case is_addable(DisconnectId, Peer, SentMessageMap0) of
                 true ->
                     %% Add node into the active view.
                     add_to_active_view(Peer, PeerTag, State0);
                 false ->
                     State0
             end,

    State = merge_exchange(Exchange, State1),

    %% Notify with event.
    notify(State),

    {noreply, State};

handle_message({shuffle_reply, Exchange, _Sender}, State0) ->
    State = merge_exchange(Exchange, State0),
    {noreply, State};

handle_message({shuffle, Exchange, TTL, Sender},
               #state{myself=Myself,
                      active=Active0,
                      passive=Passive0}=State0) ->
    ?LOG_DEBUG("Node ~p received the SHUFFLE message from ~p",
               [Myself, Sender]),
    %% Forward to random member of the active view.
    State = case TTL > 0 andalso sets:size(Active0) > 1 of
        true ->
            State1 = case select_random(Active0, [Sender, Myself]) of
                         undefined ->
                             State0;
                         Random ->
                             %% Trigger connection.
                             ok = partisan_util:maybe_connect(Random),

                             %% Forward shuffle until random walk complete.
                             do_send_message(
                                 Random,
                                {shuffle, Exchange, TTL - 1, Myself}
                            ),

                             State0
                     end,

            State1;
        false ->
            %% Randomly select nodes from the passive view and respond.
            ResponseExchange = select_random_sublist(Passive0,
                                                     length(Exchange)),

            %% Trigger connection.
            ok = partisan_util:maybe_connect(Sender),

            do_send_message(
                Sender,
                {shuffle_reply, ResponseExchange, Myself}
            ),

            State2 = merge_exchange(Exchange, State0),
            State2
    end,
    {noreply, State};

handle_message({relay_message, NodeSpec, Message, TTL}, #state{} = State) ->
    ?LOG_TRACE(
        "Node ~p received tree relay to ~p", [partisan:node(), NodeSpec]
    ),

    OutLinks = State#state.out_links,
    Active = State#state.active,

    ActiveMembers = [P || #{name := P} <- members(Active)],

    case lists:member(NodeSpec, ActiveMembers) of
        true ->
            do_send_message(
                NodeSpec, Message, #{out_links => OutLinks, transitive => true}
            );
        false ->
            case TTL of
                0 ->
                    %% No longer forward.
                    ?LOG_DEBUG(
                        "TTL expired, dropping message for node ~p: ~p",
                        [NodeSpec, Message]
                    ),
                    ok;
                _ ->
                    Opts = #{out_links => OutLinks},
                    do_tree_forward(NodeSpec, Message, Opts, TTL),
                    ok
            end
    end,

    {noreply, State};

handle_message({forward_message, ServerRef, Message}, State) ->
    partisan_peer_service_manager:process_forward(ServerRef, Message),
    {noreply, State}.

%% @private
zero_epoch() ->
    Epoch = 0,
    persist_epoch(Epoch),
    Epoch.

%% @private
data_root() ->
    case application:get_env(partisan, partisan_data_dir) of
        {ok, PRoot} ->
            filename:join(PRoot, "peer_service");
        undefined ->
            undefined
    end.

%% @private
write_state_to_disk(Epoch) ->
    case data_root() of
        undefined ->
            ok;
        Dir ->
            File = filename:join(Dir, "cluster_state"),
            ok = filelib:ensure_dir(File),
            ok = file:write_file(File, term_to_binary(Epoch))
    end.

%% @private
delete_state_from_disk() ->
    case data_root() of
        undefined ->
            ok;
        Dir ->
            File = filename:join(Dir, "cluster_state"),
            ok = filelib:ensure_dir(File),
            case file:delete(File) of
                ok ->
                    ?LOG_DEBUG(#{description => "Leaving cluster, removed cluster_state"});
                {error, Reason} ->
                    ?LOG_DEBUG("Unable to remove cluster_state for reason ~p", [Reason])
            end
    end.

%% @private
maybe_load_epoch_from_disk() ->
    case data_root() of
        undefined ->
            zero_epoch();
        Dir ->
            case filelib:is_regular(filename:join(Dir, "cluster_state")) of
                true ->
                    {ok, Bin} = file:read_file(filename:join(Dir, "cluster_state")),
                    binary_to_term(Bin);
                false ->
                    zero_epoch()
            end
    end.

%% @private
persist_epoch(Epoch) ->
    write_state_to_disk(Epoch).

%% @private
members(Set) ->
    sets:to_list(Set).

%% @private
-spec disconnect(Node :: node_spec()) -> ok.

disconnect(Node) ->
    try partisan_peer_connections:prune(Node) of
        {_Info, Connections} ->
            [
                begin
                    Pid = partisan_peer_connections:pid(Connection),
                    ?LOG_DEBUG(
                        "disconnecting node ~p by stopping connection pid ~p",
                        [Node, Pid]
                    ),
                    unlink(Pid),
                    _ = catch gen_server:stop(Pid)
                end
                || Connection <- Connections
            ],
            ok
    catch
        error:badarg ->
            ok
    end.


%% @private
-spec do_send_message(Node :: atom() | node_spec(), Message :: term()) ->
    ok | {error, disconnected} | {error, not_yet_connected} | {error, term()}.

do_send_message(Node, Message) ->
    do_send_message(Node, Message, #{}).


%% @private
-spec do_send_message(
    Node :: atom() | node_spec(), Message :: term(), Options :: map()) ->
    ok | {error, disconnected} | {error, not_yet_connected} | {error, term()}.

do_send_message(Node, Message, Options) when is_atom(Node) ->
    Broadcast = partisan_config:get(broadcast, false),
    Transitive = maps:get(transitive, Options, false),

    case partisan_peer_connections:dispatch_pid(Node) of
        {ok, Pid} ->
            try
                gen_server:call(Pid, {send_message, Message})
            catch
                Class:EReason ->
                    ?LOG_DEBUG("failed to send a message to ~p due to ~p:~p", [Node, Class, EReason]),
                    {error, EReason}
            end;

        {error, Reason} ->
            case Reason of
                not_yet_connected ->
                    ?LOG_DEBUG(#{
                        description => "Node not yet connected when sending message to peer node.",
                        message => Message,
                        peer_node => Node,
                        options => #{broadcast => Broadcast, transitive => Transitive}
                    });
                disconnected ->
                    ?LOG_DEBUG(#{
                        description => "Node disconnected when sending message to peer node.",
                        message => Message,
                        peer_node => Node,
                        options => #{broadcast => Broadcast, transitive => Transitive}
                    })
            end,

            case {Broadcast, Transitive} of
                {true, true} ->
                    TTL = partisan_config:get(relay_ttl, ?RELAY_TTL),
                    do_tree_forward(Node, Message, Options, TTL);

                {true, false} ->
                    ok;

                {false, _} ->
                    {error, Reason}
            end
    end;

do_send_message(#{name := Node}, Message, Options) ->
    do_send_message(Node, Message, Options).


%% @private
select_random(View, Omit) ->
    List = members(View) -- lists:flatten([Omit]),

    %% Catch exceptions where there may not be enough members.
    try
        Index = rand:uniform(length(List)),
        lists:nth(Index, List)
    catch
        _:_ ->
            undefined
    end.


%% @private
select_random_sublist(View, K) ->
    List = members(View),
    lists:sublist(shuffle(List), K).


%% @doc Add to the active view.
%%
%% However, interesting race condition here: if the passive random walk
%% timer exceeded and the node was added to the passive view, we might
%% also have the active random walk timer exceed *after* because of a
%% network delay; if so, we have to remove this element from the passive
%% view, otherwise it will exist in both places.
%%
add_to_active_view(#{name := Name}=Peer, Tag,
                   #state{active=Active0,
                          myself=Myself,
                          passive=Passive0,
                          reserved=Reserved0,
                          max_active_size=MaxActiveSize}=State0) ->
    IsNotMyself = not (Name =:= partisan:node()),
    NotInActiveView = not sets:is_element(Peer, Active0),
    case IsNotMyself andalso NotInActiveView of
        true ->
            %% See above for more information.
            Passive = remove_from_passive_view(Peer, Passive0),

            #state{active=Active1} = State1 = case is_full({active, Active0, Reserved0}, MaxActiveSize) of
                true ->
                    drop_random_element_from_active_view(State0#state{passive=Passive});
                false ->
                    State0#state{passive=Passive}
            end,

            ?LOG_DEBUG("Node ~p adds ~p to active view with tag ~p",
                       [Myself, Peer, Tag]),

            %% Add to the active view.
            Active = sets:add_element(Peer, Active1),

            %% Fill reserved slot if necessary.
            Reserved = case dict:find(Tag, Reserved0) of
                {ok, undefined} ->
                    ?LOG_DEBUG(#{description => "Node added to reserved slot!"}),
                    dict:store(Tag, Peer, Reserved0);
                {ok, _} ->
                    %% Slot already filled, treat this as a normal peer.
                    ?LOG_DEBUG(#{description => "Node added to active view, but reserved slot already full!"}),
                    Reserved0;
                error ->
                    ?LOG_DEBUG("Tag is not reserved: ~p ~p", [Tag, Reserved0]),
                    Reserved0
            end,

            State2 = State1#state{active=Active,
                                  passive=Passive,
                                  reserved=Reserved},

            persist_epoch(State2#state.epoch),

            State2;
        false ->
            State0
    end.

%% @doc Add to the passive view.
add_to_passive_view(#{name := Name}=Peer,
                    #state{myself=Myself,
                           active=Active0,
                           passive=Passive0,
                           max_passive_size=MaxPassiveSize}=State0) ->

    IsNotMyself = not (Name =:= partisan:node()),
    NotInActiveView = not sets:is_element(Peer, Active0),
    NotInPassiveView = not sets:is_element(Peer, Passive0),
    Passive = case IsNotMyself andalso NotInActiveView andalso NotInPassiveView of
        true ->
            Passive1 = case is_full({passive, Passive0}, MaxPassiveSize) of
                true ->
                    Random = select_random(Passive0, [Myself]),
                    sets:del_element(Random, Passive0);
                false ->
                    Passive0
            end,
            sets:add_element(Peer, Passive1);
        false ->
            Passive0
    end,
    State = State0#state{passive=Passive},
    persist_epoch(State#state.epoch),
    State.

%% @private
is_full({active, Active, Reserved}, MaxActiveSize) ->
    %% Find the slots that are reserved, but not filled.
    Open = dict:fold(fun(Key, Value, Acc) ->
                      case Value of
                          undefined ->
                              [Key | Acc];
                          _ ->
                              Acc
                      end
              end, [], Reserved),
    sets:size(Active) + length(Open) >= MaxActiveSize;

is_full({passive, Passive}, MaxPassiveSize) ->
    sets:size(Passive) >= MaxPassiveSize.

%% @doc Process of removing a random element from the active view.
drop_random_element_from_active_view(
        #state{myself=Myself0,
               active=Active0,
               reserved=Reserved0,
               epoch=Epoch0,
               sent_message_map=SentMessageMap0}=State0) ->
    ReservedPeers = dict:fold(fun(_K, V, Acc) -> [V | Acc] end,
                              [],
                              Reserved0),
    %% Select random peer, but omit the peers in reserved slots and omit
    %% ourself from the active view.
    case select_random(Active0, [Myself0, ReservedPeers]) of
        undefined ->
            State0;
        Peer ->
            ?LOG_DEBUG("Removing and disconnecting peer: ~p", [Peer]),

            %% Remove from the active view.
            Active = sets:del_element(Peer, Active0),

            %% Add to the passive view.
            State = add_to_passive_view(Peer,
                                        State0#state{active=Active}),

            %% Trigger connection.
            ok = partisan_util:maybe_connect(Peer),

            %% Get next disconnect id for the peer.
            NextId = get_next_id(Peer, Epoch0, SentMessageMap0),
            %% Update the SentMessageMap.
            SentMessageMap = dict:store(Peer, NextId, SentMessageMap0),

            %% Let peer know we are disconnecting them.
            do_send_message(Peer, {disconnect, Myself0, NextId}),

            %% Trigger disconnection.
            ok = disconnect(Peer),

            ?LOG_DEBUG(#{
                description => "Active view",
                myself => Myself0,
                active_view => members(Active)
            }),

            State#state{sent_message_map=SentMessageMap}
    end.

%% @private
arwl() ->
    partisan_config:get(arwl, 6).

%% @private
prwl() ->
    partisan_config:get(prwl, 6).

%% @private
remove_from_passive_view(Peer, Passive) ->
    sets:del_element(Peer, Passive).

%% @private
is_in_passive_view(Peer, Passive) ->
    sets:is_element(Peer, Passive).

%% @private
remove_from_active_view(Peer, Active) ->
    sets:del_element(Peer, Active).

%% @private
is_in_active_view(Peer, Active) ->
    sets:is_element(Peer, Active).

%% @private
neighbor_acceptable(Priority, Tag,
                    #state{active=Active,
                           reserved=Reserved,
                           max_active_size=MaxActiveSize}) ->
    %% Broken down for readability.
    case Priority of
        high ->
            %% Always true.
            true;
        _ ->
            case reserved_slot_available(Tag, Reserved) of
                true ->
                    %% Always take.
                    true;
                _ ->
                    %% Otherwise, only if we have a slot available.
                    not is_full({active, Active, Reserved}, MaxActiveSize)
            end
    end.

%% @private
k_active() ->
    3.

%% @private
k_passive() ->
    4.

%% @private
schedule_tree_refresh() ->
    case partisan_config:get(broadcast, false) of
        true ->
            Period = partisan_config:get(tree_refresh, 1000),
            erlang:send_after(Period, ?MODULE, tree_refresh);
        false ->
            ok
    end.

%% @private
schedule_passive_view_maintenance() ->
    Period = partisan_config:get(passive_view_shuffle_period,
                                 ?DEFAULT_PASSIVE_VIEW_MAINTENANCE_INTERVAL),
    erlang:send_after(Period,
                      ?MODULE,
                      passive_view_maintenance).

%% -----------------------------------------------------------------------------
%% @doc
%% http://stackoverflow.com/questions/8817171/shuffling-elements-in-a-list-randomly-re-arrange-list-elements/8820501#8820501
%% @end
%% -----------------------------------------------------------------------------
shuffle(L) ->
    [X || {_, X} <- lists:sort([{rand:uniform(), N} || N <- L])].

%% @private
merge_exchange(Exchange, #state{myself=Myself, active=Active}=State0) ->
    %% Remove ourself and active set members from the exchange.
    ToAdd = lists:usort(Exchange -- ([Myself] ++ members(Active))),

    %% Add to passive set.
    lists:foldl(fun(X, P) -> add_to_passive_view(X, P) end, State0, ToAdd).

%% @private
notify(#state{active=Active}) ->
    catch partisan_peer_service_events:update(Active).

%% @private
reserved_slot_available(Tag, Reserved) ->
    case dict:find(Tag, Reserved) of
        {ok, undefined} ->
            true;
        _ ->
            false
    end.

%% %% @private
%%remove_from_reserved(Peer, Reserved) ->
%%    dict:fold(fun(K, V, Acc) ->
%%                      case V of
%%                          Peer ->
%%                              Acc;
%%                          _ ->
%%                              dict:store(K, V, Acc)
%%                      end
%%              end, dict:new(), Reserved).

%% @private
get_current_id(Peer, MessageMap) ->
    case dict:find(Peer, MessageMap) of
        {ok, Id} ->
            Id;
        error ->
            %% Default value for the messageId:
            %% {First start, No disconnect}
            {1, 0}
    end.

%% @private
get_next_id(Peer, MyEpoch, SentMessageMap) ->
    case dict:find(Peer, SentMessageMap) of
        {ok, {MyEpoch, Cnt}} ->
            {MyEpoch, Cnt + 1};
        error ->
            {MyEpoch, 1}
    end.

%% @private
is_valid_disconnect(Peer, {DisconnectIdEpoch, DisconnectIdCnt}, AckMessageMap) ->
    case dict:find(Peer, AckMessageMap) of
        error ->
            true;
        {ok, {Epoch, Cnt}} ->
            case DisconnectIdEpoch > Epoch of
                true ->
                    true;
                false ->
                    DisconnectIdCnt > Cnt
            end
    end.

%% @private
is_addable({DisconnectIdEpoch, DisconnectIdCnt}, Peer, SentMessageMap) ->
    case dict:find(Peer, SentMessageMap) of
        error ->
            true;
        {ok, {Epoch, Cnt}} ->
            case DisconnectIdEpoch > Epoch of
                true ->
                    true;
                false when DisconnectIdEpoch == Epoch ->
                    DisconnectIdCnt >= Cnt;
                false ->
                    false
            end
    end;
is_addable(PeerEpoch, Peer, SentMessageMap) ->
    case dict:find(Peer, SentMessageMap) of
        error ->
            true;
        {ok, {Epoch, _Cnt}} ->
            PeerEpoch >= Epoch
    end.

%% @private
move_peer_from_passive_to_active(undefined, State) -> State;
move_peer_from_passive_to_active(Peer,
        #state{myself=Myself0,
               active=Active0,
               passive=Passive0,
               tag=Tag0,
               recv_message_map=RecvMessageMap0}=State0) ->
    ?LOG_DEBUG("Node ~p sends the NEIGHBOR_REQUEST to ~p", [Myself0, Peer]),

    Exchange0 = %% Myself.
                [Myself0] ++

                % Random members of the active list.
                select_random_sublist(Active0, k_active()) ++

                %% Random members of the passive list.
                select_random_sublist(Passive0, k_passive()),

    Exchange = lists:usort(Exchange0),

    %% Trigger connection.
    ok = partisan_util:maybe_connect(Peer),

    LastDisconnectId = get_current_id(Peer, RecvMessageMap0),
    do_send_message(
        Peer,
        {neighbor_request, Myself0, high, Tag0, LastDisconnectId, Exchange}
    ),

    State0.

%% @private
schedule_random_promotion() ->
    erlang:send_after(?RANDOM_PROMOTION_INTERVAL,
                      ?MODULE,
                      random_promotion).

%% @private
has_reached_the_limit({active, Active, Reserved}, LimitActiveSize) ->
    %% Find the slots that are reserved, but not filled.
    Open = dict:fold(fun(Key, Value, Acc) ->
        case Value of
            undefined ->
                [Key | Acc];
            _ ->
                Acc
        end
                     end, [], Reserved),
    sets:size(Active) + length(Open) >= LimitActiveSize.

%% @private
propagate_partition_injection(Ref, Origin, TTL, Peer) ->
    ?LOG_DEBUG("Forwarding partition request to: ~p", [Peer]),

    do_send_message(Peer, {inject_partition, Ref, Origin, TTL}).

%% @private
propagate_partition_resolution(Reference, Peer) ->
    ?LOG_DEBUG("Forwarding partition request to: ~p", [Peer]),

    do_send_message(Peer, {resolve_partition, Reference}).

%% @private
handle_partition_injection(Reference, _Origin, TTL,
                           #state{active=Active,
                                  myself=Myself,
                                  partitions=Partitions0}) ->
    %% If the TTL hasn't expired, re-forward the partition injection
    %% request.
    case TTL > 0 of
        true ->
            [propagate_partition_injection(Reference,
                                           Myself,
                                           TTL - 1,
                                           Peer)
             || Peer <- members(Active)];
        false ->
            ok
    end,

    %% Update partition table marking all immediate neighbors as
    %% partitioned.
    Partitions0 ++ lists:map(fun(Peer) ->
                                     {Reference, Peer}
                             end, members(Active)).

%% @private
handle_partition_resolution(Reference,
                            #state{active=Active,
                                   partitions=Partitions0}) ->
    %% Remove partitions.
    Partitions = lists:foldl(fun({Ref, Peer}, Acc) ->
                        case Reference of
                            Ref ->
                                Acc;
                            _ ->
                                Acc ++ [{Ref, Peer}]
                        end
                end, [], Partitions0),

    %% If the list hasn't changed, then don't further propagate
    %% the message.
    case Partitions of
        Partitions0 ->
            ok;
        _ ->
            [propagate_partition_resolution(Reference, Peer)
             || Peer <- members(Active)]
    end,

    Partitions.

%% @private
do_tree_forward(Node, Message, Options, TTL) ->
    MyNode = partisan:node(),
    ?LOG_TRACE(
        "Attempting to forward message ~p from ~p to ~p.",
        [Message, MyNode, Node]
    ),

    %% Preempt with user-supplied outlinks.
    UserOutLinks = maps:get(out_links, Options, undefined),

    OutLinks = case UserOutLinks of
        undefined ->
            try retrieve_outlinks() of
                Value ->
                    Value
            catch
                _:Reason ->
                    ?LOG_INFO(#{
                        description => "Outlinks retrieval failed",
                        reason => Reason
                    }),
                    []
            end;
        OL ->
            OL -- [MyNode]
    end,

    %% Send messages, but don't attempt to forward again, if we aren't connected.
    _ = lists:foreach(
        fun(N) ->
            ?LOG_TRACE(
                "Forwarding relay message ~p to node ~p for node ~p from node ~p",
                [Message, N, Node, MyNode]
            ),

            RelayMessage = {relay_message, Node, Message, TTL - 1},

            do_send_message(
                N,
                RelayMessage,
                maps:without([transitive], Options)
            )
        end,
        OutLinks
    ),
    ok.

%% @private
retrieve_outlinks() ->
    ?LOG_TRACE(#{description => "About to retrieve outlinks..."}),

    Root = partisan:node(),

    OutLinks = try partisan_plumtree_broadcast:debug_get_peers(partisan:node(), Root, 1000) of
        {EagerPeers, _LazyPeers} ->
            ordsets:to_list(EagerPeers)
    catch
        _:_ ->
            ?LOG_INFO(#{
                description => "Request to get outlinks timed out..."
            }),
            []
    end,

    ?LOG_TRACE("Finished getting outlinks: ~p", [OutLinks]),

    OutLinks -- [partisan:node()].