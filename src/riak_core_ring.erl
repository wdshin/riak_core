%% -------------------------------------------------------------------
%%
%% riak_core: Core Riak Application
%%
%% Copyright (c) 2007-2010 Basho Technologies, Inc.  All Rights Reserved.
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

%% @doc riak_core_ring manages a riak node's local view of partition ownership.
%%      The functions in this module revolve around use of the chstate record,
%%      which should be treated as opaque by other modules.  Riak nodes exchange
%%      instances of these records via gossip in order to converge on a common
%%      view of node/partition ownership.

-module(riak_core_ring).

-export([all_members/1,
         all_owners/1,
         all_preflists/2,
         diff_nodes/2,
         equal_rings/2,
         fresh/0,
         fresh/1,
         fresh/2,
         get_meta/2, 
         index_owner/2,
         my_indices/1,
         num_partitions/1,
         owner_node/1,
         preflist/2,
         random_node/1,
         random_other_index/1,
         random_other_index/2,
         random_other_node/1,
         reconcile/2,
         rename_node/3,
         responsible_index/2,
         transfer_node/3,
         update_meta/3]).

-export([cluster_name/1,
         member_status/2,
         add_member/3,
         remove_member/3,
         leave_member/3,
         exit_member/3,
         claiming_members/1,
         set_owner/2,
         indices/2,
         next_owner/2,
         next_owner/3,
         handoff_complete/3,
         ring_ready/1,
         ring_changed/2,
         reconcile_members/2]).

-export_type([riak_core_ring/0]).

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

-define(ROUT(S,A),ok).
%%-define(ROUT(S,A),?debugFmt(S,A)).

-record(chstate, {
    nodename :: node(),          % the Node responsible for this chstate
    vclock   :: vclock:vclock(), % for this chstate object, entries are
                                 % {Node, Ctr}
    chring   :: chash:chash(),   % chash ring of {IndexAsInt, Node} mappings
    meta     :: dict(),          % dict of cluster-wide other data (primarily
                                 % bucket N-value, etc)

    clustername :: {node(), term()}, 
    next     :: [{integer(), node(), node(), [module()], awaiting | complete}],
    members  :: [{node(), {member_status(), vclock:vclock()}}],
    claimant :: node(),
    seen     :: [{node(), vclock:vclock()}],
    rvsn     :: vclock:vclock()
}). 

-type member_status() :: valid | invalid | leaving | exiting.

%% type meta_entry(). Record for each entry in #chstate.meta
-record(meta_entry, {
    value,    % The value stored under this entry
    lastmod   % The last modified time of this entry, 
              %  from calendar:datetime_to_gregorian_seconds(
              %                             calendar:universal_time()), 
}).

%% riak_core_ring() is the opaque data type used for partition ownership
-type riak_core_ring() :: #chstate{}.
-type chstate() :: riak_core_ring().

-type pending_change() :: {Owner :: node(),
                           NextOwner :: node(),
                           awaiting | complete}
                        | {undefined, undefined, undefined}.

%% ===================================================================
%% Public API
%% ===================================================================

%% @doc Produce a list of all nodes that are members of the cluster
-spec all_members(State :: chstate()) -> [Node :: term()].
all_members(#chstate{members=Members}) ->
    get_members(Members, [valid, leaving, exiting]).

%% @doc Provide all ownership information in the form of {Index,Node} pairs.
-spec all_owners(State :: chstate()) -> [{Index :: integer(), Node :: term()}].
all_owners(State) ->
    chash:nodes(State#chstate.chring).

%% @doc Provide every preflist in the ring, truncated at N.
-spec all_preflists(State :: chstate(), N :: integer()) ->
                               [[{Index :: integer(), Node :: term()}]].
all_preflists(State, N) ->
    [lists:sublist(preflist(Key, State),N) ||
        Key <- [<<(I+1):160/integer>> ||
                   {I,_Owner} <- ?MODULE:all_owners(State)]].

%% @doc For two rings, return the list of owners that have differing ownership.
-spec diff_nodes(chstate(), chstate()) -> [node()].
diff_nodes(State1,State2) ->
    AO = lists:zip(all_owners(State1),all_owners(State2)),
    AllDiff = [[N1,N2] || {{I,N1},{I,N2}} <- AO, N1 =/= N2],
    lists:usort(lists:flatten(AllDiff)).

-spec equal_rings(chstate(), chstate()) -> boolean().
equal_rings(_A=#chstate{chring=RA,meta=MA},_B=#chstate{chring=RB,meta=MB}) ->
    MDA = lists:sort(dict:to_list(MA)),
    MDB = lists:sort(dict:to_list(MB)),
    case MDA =:= MDB of
        false -> false;
        true -> RA =:= RB
    end.

%% @doc This is used only when this node is creating a brand new cluster.
-spec fresh() -> chstate().
fresh() ->
    % use this when starting a new cluster via this node
    fresh(node()).

%% @doc Equivalent to fresh/0 but allows specification of the local node name.
%%      Called by fresh/0, and otherwise only intended for testing purposes.
-spec fresh(NodeName :: term()) -> chstate().
fresh(NodeName) ->
    fresh(app_helper:get_env(riak_core, ring_creation_size), NodeName).

%% @doc Equivalent to fresh/1 but allows specification of the ring size.
%%      Called by fresh/1, and otherwise only intended for testing purposes.
-spec fresh(RingSize :: integer(), NodeName :: term()) -> chstate().
fresh(RingSize, NodeName) ->
    VClock=vclock:increment(NodeName, vclock:fresh()),
    #chstate{nodename=NodeName,
             clustername={NodeName, erlang:now()},
             members=[{NodeName, {valid, VClock}}],
             chring=chash:fresh(RingSize, NodeName),
             next=[],
             claimant=NodeName,
             seen=[{NodeName, VClock}],
             rvsn=VClock,
             vclock=VClock,
             meta=dict:new()}.

% @doc Return a value from the cluster metadata dict
-spec get_meta(Key :: term(), State :: chstate()) -> 
    {ok, term()} | undefined.
get_meta(Key, State) -> 
    case dict:find(Key, State#chstate.meta) of
        error -> undefined;
        {ok, M} -> {ok, M#meta_entry.value}
    end.

%% @doc Return the node that owns the given index.
-spec index_owner(State :: chstate(), Idx :: integer()) -> Node :: term().
index_owner(State, Idx) ->
    hd([Owner || {I, Owner} <- ?MODULE:all_owners(State), I =:= Idx]).

%% @doc Return all partition indices owned by the node executing this function.
-spec my_indices(State :: chstate()) -> [integer()].
my_indices(State) ->
    [I || {I,Owner} <- ?MODULE:all_owners(State), Owner =:= node()].

%% @doc Return the number of partitions in this Riak ring.
-spec num_partitions(State :: chstate()) -> integer().
num_partitions(State) ->
    chash:size(State#chstate.chring).

%% @doc Return the node that is responsible for a given chstate.
-spec owner_node(State :: chstate()) -> Node :: term().
owner_node(State) ->
    State#chstate.nodename.

%% @doc For a given object key, produce the ordered list of
%%      {partition,node} pairs that could be responsible for that object.
-spec preflist(Key :: binary(), State :: chstate()) ->
                               [{Index :: integer(), Node :: term()}].
preflist(Key, State) -> chash:successors(Key, State#chstate.chring).

%% @doc Return a randomly-chosen node from amongst the owners.
-spec random_node(State :: chstate()) -> Node :: term().
random_node(State) ->
    L = all_members(State),
    lists:nth(random:uniform(length(L)), L).

%% @doc Return a partition index not owned by the node executing this function.
%%      If this node owns all partitions, return any index.
-spec random_other_index(State :: chstate()) -> integer().
random_other_index(State) ->
    L = [I || {I,Owner} <- ?MODULE:all_owners(State), Owner =/= node()],
    case L of
        [] -> hd(my_indices(State));
        _ -> lists:nth(random:uniform(length(L)), L)
    end.

-spec random_other_index(State :: chstate(), Exclude :: [term()]) -> integer() | no_indices.
random_other_index(State, Exclude) when is_list(Exclude) ->
    L = [I || {I, Owner} <- ?MODULE:all_owners(State),
              Owner =/= node(),
              not lists:member(I, Exclude)],
    case L of
        [] -> no_indices;
        _ -> lists:nth(random:uniform(length(L)), L)
    end.

%% @doc Return a randomly-chosen node from amongst the owners other than this one.
-spec random_other_node(State :: chstate()) -> Node :: term() | no_node.
random_other_node(State) ->
    case lists:delete(node(), all_members(State)) of
        [] ->
            no_node;
        L ->
            lists:nth(random:uniform(length(L)), L)
    end.

%% @doc Incorporate another node's state into our view of the Riak world.
-spec reconcile(ExternState :: chstate(), MyState :: chstate()) ->
        {no_change, chstate()} | {new_ring, chstate()}.
reconcile(ExternState, MyState) ->
    case internal_reconcile(MyState, ExternState) of
        {false, State} ->
            {no_change, State};
        {true, State} ->
            {new_ring, State}
    end.

%% @doc  Rename OldNode to NewNode in a Riak ring.
-spec rename_node(State :: chstate(), OldNode :: atom(), NewNode :: atom()) ->
            chstate().
rename_node(State=#chstate{chring=Ring, nodename=ThisNode}, OldNode, NewNode) 
  when is_atom(OldNode), is_atom(NewNode)  ->
    State#chstate{
      chring=lists:foldl(
               fun({Idx, Owner}, AccIn) ->
                       case Owner of
                           OldNode -> 
                               chash:update(Idx, NewNode, AccIn);
                           _ -> AccIn
                       end
               end, Ring, riak_core_ring:all_owners(State)),
      nodename=case ThisNode of OldNode -> NewNode; _ -> ThisNode end,
      vclock=vclock:increment(NewNode, State#chstate.vclock)}.

%% @doc Determine the integer ring index responsible
%%      for a chash key.
-spec responsible_index(chash:index(), chstate()) -> integer().
responsible_index(ChashKey, #chstate{chring=Ring}) ->
    <<IndexAsInt:160/integer>> = ChashKey,
    chash:next_index(IndexAsInt, Ring).

-spec transfer_node(Idx :: integer(), Node :: term(), MyState :: chstate()) ->
           chstate().
transfer_node(Idx, Node, MyState) ->
    case chash:lookup(Idx, MyState#chstate.chring) of
        Node ->
            MyState;
        _ ->
            Me = MyState#chstate.nodename,
            VClock = vclock:increment(Me, MyState#chstate.vclock),
            CHRing = chash:update(Idx, Node, MyState#chstate.chring),
            MyState#chstate{vclock=VClock,chring=CHRing}
    end.

% @doc Set a key in the cluster metadata dict
-spec update_meta(Key :: term(), Val :: term(), State :: chstate()) -> chstate().
update_meta(Key, Val, State) ->
    Change = case dict:find(Key, State#chstate.meta) of
                 {ok, OldM} ->
                     Val /= OldM#meta_entry.value;
                 error ->
                     true
             end,
    if Change ->
            M = #meta_entry { 
              lastmod = calendar:datetime_to_gregorian_seconds(
                          calendar:universal_time()),
              value = Val
             },
            VClock = vclock:increment(State#chstate.nodename,
                                      State#chstate.vclock),
            State#chstate{vclock=VClock,
                          meta=dict:store(Key, M, State#chstate.meta)};
       true ->
            State
    end.

%% @doc Returns the unique identifer for this cluster.
-spec cluster_name(State :: chstate()) -> term().
cluster_name(State) ->
    State#chstate.clustername.

%% @doc Returns the current membership status for a node in the cluster.
-spec member_status(State :: chstate(), Node :: node()) -> member_status().
member_status(#chstate{members=Members}, Node) ->
    member_status(Members, Node);
member_status(Members, Node) ->
    case orddict:find(Node, Members) of
        {ok, {Status, _}} ->
            Status;
        _ ->
            invalid
    end.

add_member(PNode, CState, Node) ->
    set_member(PNode, CState, Node, valid).

remove_member(PNode, CState, Node) ->
    set_member(PNode, CState, Node, invalid).

leave_member(PNode, CState, Node) ->
    set_member(PNode, CState, Node, leaving).

exit_member(PNode, CState, Node) ->
    set_member(PNode, CState, Node, exiting).

%% @doc Return a list of all members of the cluster that are eligible to
%%      claim partitions.
-spec claiming_members(State :: chstate()) -> [Node :: node()].
claiming_members(#chstate{members=Members}) ->
    get_members(Members, [valid]).

%% @doc Set the node that is responsible for a given chstate.
-spec set_owner(State :: chstate(), Node :: node()) -> chstate().
set_owner(CState, Node) ->
    CState#chstate{nodename=Node}.

%% @doc Return all partition indices owned by a node.
-spec indices(State :: chstate(), Node :: node()) -> [integer()].
indices(CState, Node) ->
    AllOwners = all_owners(CState),
    [Idx || {Idx, Owner} <- AllOwners, Owner =:= Node].

%% @doc Return details for a pending partition ownership change.
-spec next_owner(State :: chstate(), Idx :: integer()) -> pending_change().
next_owner(CState, Idx) ->
    case lists:keyfind(Idx, 1, CState#chstate.next) of
        false ->
            {undefined, undefined, undefined};
        NInfo ->
            next_owner(NInfo)
    end.

%% @doc Return details for a pending partition ownership change.
-spec next_owner(State :: chstate(), Idx :: integer(),
                 Mod :: module()) -> pending_change().
next_owner(CState, Idx, Mod) ->
    case lists:keyfind(Idx, 1, CState#chstate.next) of
        false ->
            {undefined, undefined, undefined};
        {_, Owner, NextOwner, _Transfers, complete} ->
            {Owner, NextOwner, complete};
        {_, Owner, NextOwner, Transfers, _Status} ->
            case ordsets:is_element(Mod, Transfers) of
                true ->
                    {Owner, NextOwner, complete};
                false ->
                    {Owner, NextOwner, awaiting}
            end
    end.

%% @doc Returns true if all cluster members have seen the current ring.
-spec ring_ready(State :: chstate()) -> boolean().
ring_ready(CState) ->
    Seen = CState#chstate.seen,
    Members = get_members(CState#chstate.members),
    VClock = CState#chstate.vclock,
    R = [begin
             case orddict:find(Node, Seen) of
                 error ->
                     false;
                 {ok, VC} ->
                     vclock:equal(VClock, VC)
             end
         end || Node <- Members],
    Ready = lists:all(fun(X) -> X =:= true end, R),
    Ready.

%% @doc Marks a pending transfer as completed.
-spec handoff_complete(State :: chstate(), Idx :: integer(),
                       Mod :: module()) -> chstate().
handoff_complete(CState, Idx, Mod) ->
    transfer_complete(CState, Idx, Mod).

ring_changed(Node, CState) ->
    internal_ring_changed(Node, CState).

%% =========================================================================
%% Claimant rebalance/reassign logic
%% (TODO: Consider refactoring into riak_core_gossip or riak_core_claimant)
%% =========================================================================

%% @private
internal_ring_changed(Node, CState0) ->
    CState = update_seen(node(), CState0),
    case ring_ready(CState) of
        false ->
            CState;
        true ->
            {C1, CState2} = n_maybe_update_claimant(Node, CState),
            {C2, CState3} = n_maybe_update_ring(Node, CState2),
            {C3, CState4} = n_maybe_remove_exiting(Node, CState3),

            case (C1 or C2 or C3) of
                true ->
                    VClock = vclock:increment(Node, CState4#chstate.vclock),
                    CState4#chstate{vclock=VClock};
                false ->
                    CState4
            end
    end.

%% @private
n_maybe_update_claimant(Node, CState) ->
    Members = get_members(CState#chstate.members, [valid, leaving]),
    Claimant = CState#chstate.claimant,
    RVsn = CState#chstate.rvsn,
    NextClaimant = hd(Members ++ [undefined]),
    ClaimantMissing = not lists:member(Claimant, Members),

    case {ClaimantMissing, NextClaimant} of
        {true, Node} ->
            %% Become claimant
            %%?assert(Node /= Claimant),
            RVsn2 = vclock:increment(Claimant, RVsn),
            CState2 = CState#chstate{claimant=Node, rvsn=RVsn2},
            {true, CState2};
        _ ->
            {false, CState}
    end.

%% @private
n_maybe_update_ring(Node, CState) ->
    Claimant = CState#chstate.claimant,
    case Claimant of
        Node ->
            {Changed, CState2} = update_ring(Node, CState),
            {Changed, CState2};
        _ ->
            {false, CState}
    end.

%% @private
n_maybe_remove_exiting(Node, CState) ->
    Claimant = CState#chstate.claimant,
    case Claimant of
        Node ->
            Exiting = get_members(CState#chstate.members, [exiting]),
            Changed = (Exiting /= []),
            {CState2} = remove_exiting(Node, CState),
            {Changed, CState2};
        _ ->
            {false, CState}
    end.

%% @private
remove_exiting(Node, CState0) ->
    Exiting = get_members(CState0#chstate.members, [exiting]),
    {CState2} =
        lists:foldl(fun(ENode, {CState}) ->
                            %% Tell exiting node to shutdown.
                            riak_core_ring_manager:refresh_ring(ENode),
                            CState2 = set_member(Node, CState, ENode, invalid),
                            {CState2}
                    end, {CState0}, Exiting),
    {CState2}.

%% TODO: Matching on active is bad when all leaving and want to remove indices
%% @private
update_ring(CNode, CState) ->
    Active = get_members(CState#chstate.members, [valid]),
    update_ring(Active, CNode, CState).

%% @private
update_ring([], _CNode, CState) ->
    {false, CState};
update_ring(Active, CNode, CState) ->
    Next0 = CState#chstate.next,

    ?ROUT("Members: ~p~n", [CState#chstate.members]),
    ?ROUT("Updating ring :: next0 : ~p~n", [Next0]),

    %% Remove tuples from next for removed nodes
    InvalidMembers = get_members(CState#chstate.members, [invalid]),
    Next2 = lists:filter(fun(NInfo) ->
                                 {_, NextOwner, Status} = next_owner(NInfo),
                                 (Status =:= complete) or
                                     not lists:member(NextOwner, InvalidMembers)
                         end, Next0),
    CState2 = CState#chstate{next=Next2},

    %% Transfer ownership after completed handoff
    {RingChanged1, CState3} = transfer_ownership(CState2),
    ?ROUT("Updating ring :: next1 : ~p~n", [CState3#chstate.next]),

    %% Ressign leaving/inactive indices
    {RingChanged2, CState4} = reassign_indices(CState3),
    ?ROUT("Updating ring :: next2 : ~p~n", [CState4#chstate.next]),

    Next3 = rebalance_ring(Active, CNode, CState4),
    NextChanged = (Next0 /= Next3),
    Changed = NextChanged or RingChanged1 or RingChanged2,
    case Changed of
        true ->
            RVsn2 = vclock:increment(CNode, CState4#chstate.rvsn),
            ?ROUT("Updating ring :: next3 : ~p~n", [Next3]),
            {true, CState4#chstate{next=Next3, rvsn=RVsn2}};
        false ->
            {false, CState}
    end.

%% @private
transfer_ownership(CState=#chstate{next=Next}) ->
    %% Remove already completed and transfered changes
    Next2 = lists:filter(fun(NInfo={Idx, _, _, _, _}) ->
                                 {_, NewOwner, S} = next_owner(NInfo),
                                 not ((S == complete) and
                                      (index_owner(CState, Idx) =:= NewOwner))
                         end, Next),

    CState2 = lists:foldl(fun(NInfo={Idx, _, _, _, _}, CState0) ->
                                  case next_owner(NInfo) of
                                      {_, Node, complete} ->
                                          riak_core_ring:transfer_node(Idx, Node, CState0);
                                      _ ->
                                          CState0
                                  end
                          end, CState, Next2),

    NextChanged = (Next2 /= Next),
    RingChanged = (all_owners(CState) /= all_owners(CState2)),
    Changed = (NextChanged or RingChanged),
    {Changed, CState2#chstate{next=Next2}}.

%% @private
reassign_indices(CState=#chstate{next=Next}) ->
    Invalid = get_members(CState#chstate.members, [invalid]),
    {CState2} =
        lists:foldl(fun(Node, {Ring0}) ->
                            Ring2 = remove_node(Ring0, Node, invalid),
                            {Ring2}
                    end, {CState}, Invalid),
    CState3 = case Next of
                  [] ->
                      Leaving = get_members(CState#chstate.members, [leaving]),
                      lists:foldl(fun(Node, Ring0) ->
                                          remove_node(Ring0, Node, leaving)
                                  end, CState2, Leaving);
                  _ ->
                      CState2
              end,
    Owners1 = all_owners(CState),
    Owners2 = all_owners(CState3),
    RingChanged = (Owners1 /= Owners2),
    NextChanged = (Next /= CState3#chstate.next),
    {RingChanged or NextChanged, CState3}.

%% @private
rebalance_ring(_Active, _CNode, CState=#chstate{next=[]}) ->
    Members = claiming_members(CState),
    CState2 = lists:foldl(fun(Node, Ring0) ->
                                  riak_core_gossip:claim_until_balanced(Ring0, Node)
                          end, CState, Members),
    Owners1 = all_owners(CState),
    Owners2 = all_owners(CState2),
    Owners3 = lists:zip(Owners1, Owners2),
    Next = [{Idx, PrevOwner, NewOwner, [], awaiting}
            || {{Idx, PrevOwner}, {Idx, NewOwner}} <- Owners3,
               PrevOwner /= NewOwner],
    Next;
rebalance_ring(_Active, _CNode, _CState=#chstate{next=Next}) ->
    Next.

%% @private
remove_node(CState, Node, Status) ->
    Indices = indices(CState, Node),
    remove_node(CState, Node, Status, Indices).

%% @private
next_owners(#chstate{next=Next}) ->
    [{Idx, NextOwner} || {Idx, _, NextOwner, _, _} <- Next].

%% @private
change_owners(CState, Reassign) ->
    lists:foldl(fun({Idx, NewOwner}, CState0) ->
                        riak_core_ring:transfer_node(Idx, NewOwner, CState0)
                end, CState, Reassign).

%% @private
remove_node(CState, _Node, _Status, []) ->
    CState;
remove_node(CState, Node, Status, Indices) ->
    %% ?debugFmt("Reassigning from ~p: ~p~n", [Node, indices(CState, Node)]),
    CStateT1 = change_owners(CState, next_owners(CState)),
    CStateT2 = riak_core_gossip:remove_from_cluster(CStateT1, Node),
    Owners1 = all_owners(CState),
    Owners2 = all_owners(CStateT2),
    Owners3 = lists:zip(Owners1, Owners2),
    RemovedIndices = case Status of
                         invalid ->
                             Indices;
                         leaving ->
                             []
                     end,
    Reassign = [{Idx, NewOwner} || {Idx, NewOwner} <- Owners2,
                                   lists:member(Idx, RemovedIndices)],
    Next = [{Idx, PrevOwner, NewOwner, [], awaiting}
            || {{Idx, PrevOwner}, {Idx, NewOwner}} <- Owners3,
               PrevOwner /= NewOwner,
               not lists:member(Idx, RemovedIndices)],

    CState2 = change_owners(CState, Reassign),
    CState2#chstate{next=Next}.

%% ====================================================================
%% Internal functions
%% ====================================================================

%% @private
merge_meta(M1,M2) ->
    dict:merge(fun(_,D1,D2) -> pick_val(D1,D2) end, M1, M2).

%% @private
pick_val(M1,M2) ->
    case M1#meta_entry.lastmod > M2#meta_entry.lastmod of
        true -> M1;
        false -> M2
    end.                   

%% @private
internal_reconcile(CS01, CS02) ->
    VNode = owner_node(CS01),
    CS03 = update_seen(VNode, CS01),
    CS04 = update_seen(VNode, CS02),
    Seen = reconcile_seen(CS03, CS04),
    CS1 = CS03#chstate{seen=Seen},
    CS2 = CS04#chstate{seen=Seen},
    SeenChanged = not equal_seen(CS01, CS1),

    VC1 = CS1#chstate.vclock,
    VC2 = CS2#chstate.vclock,
    %%io:format("V1: ~p~nV2: ~p~n", [VC1, VC2]),
    Newer = vclock:descends(VC1, VC2),
    Older = vclock:descends(VC2, VC1),
    Equal = equal_cstate(CS1, CS2),
    case {Equal, Newer, Older} of
        {_, true, false} ->
            {SeenChanged, CS1};
        {_, false, true} ->
            {true, CS2#chstate{nodename=VNode}};
        {true, _, _} ->
            {SeenChanged, CS1};
        {_, true, true} ->
            throw("Equal vclocks, but cstate unequal");
        {_, false, false} ->
            CS3 = reconcile_divergent(VNode, CS1, CS2, VC1, VC2),
            {true, CS3#chstate{nodename=VNode}}
    end.

%% @private
reconcile_divergent(VNode, CS1, CS2, VC1, VC2) ->
    VClock2 = vclock:increment(VNode, vclock:merge([VC1, VC2])),
    Members = reconcile_members(CS1, CS2),
    Meta = merge_meta(CS1#chstate.meta, CS2#chstate.meta),
    CS3 = reconcile_ring(CS1, CS2, get_members(Members)),
    CS3#chstate{vclock=VClock2, members=Members, meta=Meta}.

%% @private
reconcile_members(CS1, CS2) ->
    orddict:merge(
      fun(_K, {Valid1, VC1}, {Valid2, VC2}) ->
              New1 = vclock:descends(VC1, VC2),
              New2 = vclock:descends(VC2, VC1),
              MergeVC = vclock:merge([VC1, VC2]),
              case {New1, New2} of
                  {true, false} ->
                      {Valid1, MergeVC};
                  {false, true} ->
                      {Valid2, MergeVC};
                  {_, _} ->
                      {merge_status(Valid1, Valid2), MergeVC}
              end
      end,
      CS1#chstate.members,
      CS2#chstate.members).

%% @private
reconcile_seen(CS1, CS2) ->
    orddict:merge(fun(_, VC1, VC2) ->
                          vclock:merge([VC1, VC2])
                  end, CS1#chstate.seen, CS2#chstate.seen).

%% @private
merge_next_status(complete, _) ->
    complete;
merge_next_status(_, complete) ->
    complete;
merge_next_status(awaiting, awaiting) ->
    awaiting.

%% @private
reconcile_next(Next1, Next2) ->
    lists:zipwith(fun({Idx, Owner, Node, Transfers1, Status1},
                      {Idx, Owner, Node, Transfers2, Status2}) ->
                          {Idx, Owner, Node,
                           ordsets:union(Transfers1, Transfers2),
                           merge_next_status(Status1, Status2)}
                  end, Next1, Next2).

%% @private
reconcile_next2(Next1, Next2) ->
    lists:zipwith(fun({Idx, Owner1, Node1, Transfers1, Status1},
                      {Idx, Owner2, Node2, Transfers2, Status2}) ->
                          Same = ({Owner1, Node1} =:= {Owner2, Node2}),
                          case {Same, Status1, Status2} of
                              {false, _, _} ->
                                  {Idx, Owner1, Node1, Transfers1, Status1};
                              _ ->
                                  {Idx, Owner1, Node1,
                                   ordsets:union(Transfers1, Transfers2),
                                   merge_next_status(Status1, Status2)}
                          end
                  end, Next1, Next2).

%% @private
substitute(Idx, TL1, TL2) ->
    lists:map(fun(T) ->
                      Key = element(Idx, T),
                      case lists:keyfind(Key, Idx, TL2) of
                          false ->
                              T;
                          T2 ->
                              T2
                      end
              end, TL1).

%% @private
reconcile_ring(CS1=#chstate{claimant=Claimant1, rvsn=VC1},
               CS2=#chstate{claimant=Claimant2, rvsn=VC2}, Members) ->
    V1Newer = vclock:descends(VC1, VC2),
    V2Newer = vclock:descends(VC2, VC1),
    EqualVC = (vclock:equal(VC1, VC2) and (Claimant1 =:= Claimant2)),
    Next1 = CS1#chstate.next,
    Next2 = CS2#chstate.next,
    CS3 = case {EqualVC, V1Newer, V2Newer} of
              {true, _, _} ->
                  %%?assertEqual(CS1#chstate.chring, CS2#chstate.chring),
                  Next = reconcile_next(Next1, Next2),
                  CS1#chstate{next=Next};
              {_, true, false} ->
                  MNext = substitute(1, Next1, Next2),
                  Next = reconcile_next2(Next1, MNext),
                  CS1#chstate{next=Next};
              {_, false, true} ->
                  MNext = substitute(1, Next2, Next1),
                  Next = reconcile_next2(Next2, MNext),
                  CS2#chstate{next=Next};
              {_, _, _} ->
                  CValid1 = lists:member(Claimant1, Members),
                  CValid2 = lists:member(Claimant2, Members),
                  case {CValid1, CValid2} of
                      {true, false} ->
                          MNext = substitute(1, Next1, Next2),
                          Next = reconcile_next2(Next1, MNext),
                          CS1#chstate{next=Next};
                      {false, true} ->
                          MNext = substitute(1, Next2, Next1),
                          Next = reconcile_next2(Next2, MNext),
                          CS2#chstate{next=Next};
                      {false, false} ->
                          throw("Neither claimant valid");
                      {true, true} ->
                          %% This should never happen in normal practice.
                          %% But, we need to handle it for exceptional cases.
                          case Claimant1 < Claimant2 of
                              true ->
                                  MNext = substitute(1, Next1, Next2),
                                  Next = reconcile_next2(Next1, MNext),
                                  CS1#chstate{next=Next};
                              false ->
                                  MNext = substitute(1, Next2, Next1),
                                  Next = reconcile_next2(Next2, MNext),
                                  CS2#chstate{next=Next}
                          end
                  end
          end,
    CS3.

%% @private
merge_status(invalid, _) ->
    invalid;
merge_status(_, invalid) ->
    invalid;
merge_status(valid, _) ->
    valid;
merge_status(_, valid) ->
    valid;
merge_status(exiting, _) ->
    exiting;
merge_status(_, exiting) ->
    exiting;
merge_status(leaving, _) ->
    leaving;
merge_status(_, leaving) ->
    leaving;
merge_status(_, _) ->
    invalid.

%% @private
transfer_complete(CState=#chstate{next=Next, vclock=VClock}, Idx, Mod) ->
    {Idx, Owner, NextOwner, Transfers, Status} = lists:keyfind(Idx, 1, Next),
    Transfers2 = ordsets:add_element(Mod, Transfers),
    VNodeMods = ordsets:from_list([VMod || {_, VMod} <- riak_core:vnode_modules()]),
    Status2 = case {Status, Transfers2} of
                  {complete, _} ->
                      complete;
                  {awaiting, VNodeMods} ->
                      complete;
                  _ ->
                      awaiting
              end,
    Next2 = lists:keyreplace(Idx, 1, Next, {Idx, Owner, NextOwner, Transfers2, Status2}),
    VClock2 = vclock:increment(Owner, VClock),
    CState#chstate{next=Next2, vclock=VClock2}.


%% @private
next_owner({_, Owner, NextOwner, _Transfers, Status}) ->
    {Owner, NextOwner, Status}.

%% @private
get_members(Members) ->
    get_members(Members, [valid, leaving, exiting]).

%% @private
get_members(Members, Types) ->
    [Node || {Node, {V, _}} <- Members, lists:member(V, Types)].

%% @private
set_member(Node, CState, Member, Status) ->
    Members2 = orddict:update(Member,
                              fun({_, VC}) ->
                                      {Status, vclock:increment(Node, VC)}
                              end,
                              {Status, vclock:increment(Node,
                                                        vclock:fresh())},
                              CState#chstate.members),
    VClock = vclock:increment(Node, CState#chstate.vclock),
    CState#chstate{members=Members2, vclock=VClock}.

%% @private
update_seen(Node, CState) ->
    Seen2 = orddict:update(Node,
                           fun(SeenVC) ->
                                   vclock:merge([SeenVC, CState#chstate.vclock])
                           end,
                           CState#chstate.vclock,
                           CState#chstate.seen),
    CState#chstate{seen=Seen2}.

%% @private
equal_cstate(CS1, CS2) ->
    T1 = equal_members(CS1#chstate.members, CS2#chstate.members),
    T2 = true, %%equal_vclock(CS1#chstate.vclock, CS2#chstate.vclock),
    T3 = vclock:equal(CS1#chstate.rvsn, CS2#chstate.rvsn),
    T4 = equal_seen(CS1, CS2),
    T5 = equal_rings(CS1, CS2),
    %% Clear fields checked manually and test remaining through equality.
    CS3=CS1#chstate{nodename=ok, members=ok, vclock=ok, rvsn=ok, seen=ok,
                    chring=ok, meta=ok},
    CS4=CS2#chstate{nodename=ok, members=ok, vclock=ok, rvsn=ok, seen=ok,
                    chring=ok, meta=ok},
    T6 = (CS3 =:= CS4),
    T1 and T2 and T3 and T4 and T5 and T6.

%% @private
equal_members(M1, M2) ->
    L = orddict:merge(fun(_, {V1, VC1}, {V2, VC2}) ->
                              V1 =:= V2 andalso vlock:equal(VC1, VC2)
                      end, M1, M2),
    {_, R} = lists:unzip(L),
    lists:all(fun(X) -> X =:= true end, R).

%% @private
filtered_seen(CS) ->
    Members = get_members(CS#chstate.members),
    filtered_seen(Members, CS).

%% @private
filtered_seen([], CS) ->
    CS#chstate.seen;
filtered_seen(Members, CS) ->
    orddict:filter(fun(N, _) -> lists:member(N, Members) end, CS#chstate.seen).

%% @private
equal_seen(CS1, CS2) ->
    Seen1 = filtered_seen(CS1),
    Seen2 = filtered_seen(CS2),
    L = orddict:merge(fun(_, VC1, VC2) ->
                              vclock:equal(VC1, VC2)
                      end, Seen1, Seen2),
    {_, R} = lists:unzip(L),
    lists:all(fun(X) -> X =:= true end, R).

%% ===================================================================
%% EUnit tests
%% ===================================================================
-ifdef(TEST).

sequence_test() ->
    I1 = 365375409332725729550921208179070754913983135744,
    I2 = 730750818665451459101842416358141509827966271488,
    A = fresh(4,a),
    B1 = A#chstate{nodename=b},
    B2 = transfer_node(I1, b, B1),
    ?assertEqual(B2, transfer_node(I1, b, B2)),
    {new_ring, A1} = reconcile(B1,A),
    C1 = A#chstate{nodename=c},
    C2 = transfer_node(I1, c, C1),
    {new_ring, A2} = reconcile(C2,A1),
    {new_ring, A3} = reconcile(B2,A2),
    C3 = transfer_node(I2,c,C2),
    {new_ring, C4} = reconcile(A3,C3),
    {new_ring, A4} = reconcile(C4,A3),
    {new_ring, B3} = reconcile(A4,B2),
    ?assertEqual(A4#chstate.chring, B3#chstate.chring),
    ?assertEqual(B3#chstate.chring, C4#chstate.chring).

param_fresh_test() ->
    application:set_env(riak_core,ring_creation_size,4),
    ?assertEqual(fresh(), fresh(4,node())),
    ?assertEqual(owner_node(fresh()),node()).

index_test() ->
    Ring0 = fresh(2,node()),
    Ring1 = transfer_node(0,x,Ring0),
    ?assertEqual(0,random_other_index(Ring0)),
    ?assertEqual(0,random_other_index(Ring1)),
    ?assertEqual(node(),index_owner(Ring0,0)),
    ?assertEqual(x,index_owner(Ring1,0)),
    ?assertEqual(lists:sort([x,node()]),lists:sort(diff_nodes(Ring0,Ring1))).

reconcile_test() ->
    Ring0 = fresh(2,node()),
    Ring1 = transfer_node(0,x,Ring0),
    ?assertEqual({no_change,Ring1},reconcile(fresh(2,someone_else),Ring1)),
    RingB0 = fresh(2,node()),
    RingB1 = transfer_node(0,x,RingB0),
    RingB2 = RingB1#chstate{nodename=b},
    ?assertEqual({no_change,RingB2},reconcile(Ring1,RingB2)).

metadata_inequality_test() ->
    Ring0 = fresh(2,node()),
    Ring1 = update_meta(key,val,Ring0),
    ?assertNot(equal_rings(Ring0,Ring1)),
    ?assertEqual(Ring1#chstate.meta,
                 merge_meta(Ring0#chstate.meta,Ring1#chstate.meta)),
    timer:sleep(1001), % ensure that lastmod is at least a second later
    Ring2 = update_meta(key,val2,Ring1),
    ?assertEqual(get_meta(key,Ring2),
                 get_meta(key,#chstate{meta=
                            merge_meta(Ring1#chstate.meta,
                                       Ring2#chstate.meta)})),
    ?assertEqual(get_meta(key,Ring2),
                 get_meta(key,#chstate{meta=
                            merge_meta(Ring2#chstate.meta,
                                       Ring1#chstate.meta)})).
rename_test() ->
    Ring0 = fresh(2, node()),
    Ring = rename_node(Ring0, node(), 'new@new'),
    ?assertEqual('new@new', owner_node(Ring)),
    ?assertEqual(['new@new'], all_members(Ring)).

exclusion_test() ->    
    Ring0 = fresh(2, node()),
    Ring1 = transfer_node(0,x,Ring0),
    ?assertEqual(0, random_other_index(Ring1,[730750818665451459101842416358141509827966271488])),
    ?assertEqual(no_indices, random_other_index(Ring1, [0])),
    ?assertEqual([{730750818665451459101842416358141509827966271488,node()},{0,x}],
                 preflist(<<1:160/integer>>, Ring1)).

random_other_node_test() ->
    Ring0 = fresh(2, node()),
    ?assertEqual(no_node, random_other_node(Ring0)),
    Ring1 = transfer_node(0, 'new@new', Ring0),
    ?assertEqual('new@new', random_other_node(Ring1)).

-endif.
