% @hidden
-module(kafe_consumer_commiter).
-compile([{parse_transform, lager_transform}]).
-behaviour(gen_server).

-include("../include/kafe.hrl").
-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

%% API
-export([start_link/4]).

%% gen_server callbacks
-export([init/1
         , handle_call/3
         , handle_cast/2
         , handle_info/2
         , terminate/2
         , code_change/3]).

-define(SERVER, ?MODULE).

-record(state, {
          topic,
          partition,
          commit_interval,
          commit_messages,
          commit_timer = undefined,
          last_offset = -1,
          group_id,
          commits = []
         }).

start_link(Topic, Partition, GroupID, Commit) ->
  gen_server:start_link(?MODULE, [Topic, Partition, GroupID, Commit], []).

% @hidden
init([Topic, Partition, GroupID, Commit]) ->
  erlang:process_flag(trap_exit, true),
  kafe_consumer_store:insert(GroupID, {commit_pid, {Topic, Partition}}, self()),
  CommitInterval = buclists:keyfind(interval, 1, Commit, undefined),
  {ok, start_commit_timer(#state{
          topic = Topic,
          partition = Partition,
          group_id = GroupID,
          commit_interval = CommitInterval,
          commit_messages = buclists:keyfind(messages, 1, Commit, undefined),
          commits = []
         })}.

% @hidden
handle_call({offset, Offset}, _From, State) ->
  {reply, ok, State#state{last_offset = Offset}};
handle_call({commit, Offset}, _From, #state{group_id = GroupID,
                                            topic = Topic,
                                            partition = Partition,
                                            last_offset = MaxOffset,
                                            commits = Commits} = State) ->
  case (not lists:member(Offset, Commits)) andalso (Offset > MaxOffset) of
    true ->
      Commits0 = lists:sort([Offset|Commits]),
      kafe_metrics:consumer_partition_pending_commits(GroupID, Topic, Partition, length(Commits0)),
      {reply, ok, start_commit_timer(State#state{commits = Commits0}, 5)};
    false ->
      {reply, ok, State}
  end;
handle_call(_Request, _From, State) ->
  Reply = ok,
  {reply, Reply, State}.

% @hidden
handle_cast(_Msg, State) ->
  {noreply, State}.

% @hidden
handle_info(commit, #state{commits = []} = State) ->
  {noreply, start_commit_timer(State)};
handle_info(commit, #state{last_offset = LastOffset, commits = Commits, group_id = GroupID, topic = Topic, partition = Partition} = State) ->
  case lcs(LastOffset, Commits) of
    [] ->
      {noreply, start_commit_timer(State)};
    LIS ->
      CommitOffset = lists:max(LIS),
      GenerationID = kafe_consumer_store:value(GroupID, generation_id),
      MemberID = kafe_consumer_store:value(GroupID, member_id),
      case kafe:offset_commit(GroupID, GenerationID, MemberID, -1,
                              [{Topic, [{Partition, CommitOffset, <<>>}]}]) of
        {ok, [#{name := Topic,
                partitions := [#{error_code := none,
                                 partition := Partition}]}]} ->
          lager:debug("Committed offset ~p for topic ~s, partition ~p", [CommitOffset, Topic, Partition]),
          RemainingCommits = Commits -- LIS,
          kafe_metrics:consumer_partition_pending_commits(GroupID, Topic, Partition, length(RemainingCommits)),
          {noreply, start_commit_timer(State#state{last_offset = CommitOffset,
                                                   commits = RemainingCommits})};
        {ok, [#{name := Topic,
                partitions := [#{error_code := Error,
                                 partition := Partition}]}]} ->
          lager:error("Commit offset ~p for topic ~s, partition ~p error: ~s", [CommitOffset, Topic, Partition, kafe_error:message(Error)]),
          {noreply, start_commit_timer(State)};
        Error ->
          lager:error("Commit offset ~p for topic ~s, partition ~p error: ~p", [CommitOffset, Topic, Partition, Error]),
          {noreply, start_commit_timer(State)}
      end
  end;
handle_info(_Info, State) ->
  {noreply, State}.

% @hidden
terminate(_Reason, #state{group_id = GroupID, topic = Topic, partition = Partition}) ->
  kafe_consumer_store:delete(GroupID, {commit_pid, {Topic, Partition}}),
  ok.

% @hidden
code_change(_OldVsn, State, _Extra) ->
  {ok, State}.

start_commit_timer(#state{commit_timer = TimerRef} = State, Interval) when TimerRef =/= undefined ->
  erlang:cancel_timer(TimerRef),
  start_commit_timer(State#state{commit_timer = undefined}, Interval);
start_commit_timer(State, undefined) ->
  State#state{commit_timer = undefined};
start_commit_timer(#state{commit_timer = undefined} = State, Interval) ->
  State#state{commit_timer = erlang:send_after(Interval, self(), commit)}.

start_commit_timer(#state{commit_timer = TimerRef} = State) when TimerRef =/= undefined ->
  erlang:cancel_timer(TimerRef),
  start_commit_timer(State#state{commit_timer = undefined});
start_commit_timer(#state{commit_interval = undefined} = State) ->
  State;
start_commit_timer(#state{commit_interval = Interval, commit_timer = undefined} = State) ->
  State#state{commit_timer = erlang:send_after(Interval, self(), commit)}.

lcs(Last, [First|_] = List) when Last + 1 == First ->
  lcs(List, Last, []);
lcs(_, _) ->
  [].

lcs([], _, Res) ->
  Res;
lcs([E|Rest], Last, Res) when E == Last + 1 ->
  lcs(Rest, E, [E|Res]);
lcs(_, _, Res) ->
  Res.

-ifdef(TEST).
call_commit_test() ->
  meck:new(kafe_metrics),
  meck:expect(kafe_metrics, consumer_partition_pending_commits, 4, ok),
  ?assertMatch({reply, ok, #state{
                              topic = <<"topic">>,
                              partition = 1,
                              commit_interval = 1000,
                              commit_messages = 1000,
                              commit_timer = _,
                              last_offset = -1,
                              group_id = <<"group">>,
                              commits = [0, 1]}},
               handle_call({commit, 1}, from, #state{
                                                 topic = <<"topic">>,
                                                 partition = 1,
                                                 commit_interval = 1000,
                                                 commit_messages = 1000,
                                                 commit_timer = undefined,
                                                 last_offset = -1,
                                                 group_id = <<"group">>,
                                                 commits = [0]})),
  meck:unload(kafe_metrics).

call_commit_already_stored_offset_test() ->
  meck:new(kafe_metrics),
  meck:expect(kafe_metrics, consumer_partition_pending_commits, 4, ok),
  ?assertMatch({reply, ok, #state{
                              topic = <<"topic">>,
                              partition = 1,
                              commit_interval = 1000,
                              commit_messages = 1000,
                              commit_timer = undefined,
                              last_offset = -1,
                              group_id = <<"group">>,
                              commits = [0, 1, 2, 3, 4]}},
               handle_call({commit, 2}, from, #state{
                                                 topic = <<"topic">>,
                                                 partition = 1,
                                                 commit_interval = 1000,
                                                 commit_messages = 1000,
                                                 commit_timer = undefined,
                                                 last_offset = -1,
                                                 group_id = <<"group">>,
                                                 commits = [0, 1, 2, 3, 4]})),
  meck:unload(kafe_metrics).

call_commit_old_offset_test() ->
  meck:new(kafe_metrics),
  meck:expect(kafe_metrics, consumer_partition_pending_commits, 4, ok),
  ?assertMatch({reply, ok, #state{
                              topic = <<"topic">>,
                              partition = 1,
                              commit_interval = 1000,
                              commit_messages = 1000,
                              commit_timer = undefined,
                              last_offset = 10,
                              group_id = <<"group">>,
                              commits = []}},
               handle_call({commit, 2}, from, #state{
                                                 topic = <<"topic">>,
                                                 partition = 1,
                                                 commit_interval = 1000,
                                                 commit_messages = 1000,
                                                 commit_timer = undefined,
                                                 last_offset = 10,
                                                 group_id = <<"group">>,
                                                 commits = []})),
  meck:unload(kafe_metrics).

info_commit_test() ->
  meck:new(kafe_consumer_store),
  meck:expect(kafe_consumer_store, value, fun
                                            (_, generation_id) -> 0;
                                            (_, member_id) -> <<"member">>
                                          end),
  meck:new(kafe),
  meck:expect(kafe, offset_commit,
              fun(_, _, _, _, [{Topic, [{Partition, _, <<>>}]}]) ->
                  {ok, [#{name => Topic,
                          partitions => [#{error_code => none,
                                           partition => Partition}]}]}
              end),
  meck:new(kafe_metrics),
  meck:expect(kafe_metrics, consumer_partition_pending_commits, 4, ok),
  ?assertMatch({noreply, #state{
                            topic = <<"topic">>,
                            partition = 1,
                            commit_interval = 1000,
                            commit_messages = 1000,
                            commit_timer = _,
                            last_offset = 5,
                            group_id = <<"group">>,
                            commits = []}},
               handle_info(commit, #state{
                                      topic = <<"topic">>,
                                      partition = 1,
                                      commit_interval = 1000,
                                      commit_messages = 1000,
                                      commit_timer = undefined,
                                      last_offset = -1,
                                      group_id = <<"group">>,
                                      commits = [0, 1, 2, 3, 4, 5]})),
  meck:unload(kafe_metrics),
  meck:unload(kafe),
  meck:unload(kafe_consumer_store).

info_commit_kafka_error_test() ->
  meck:new(kafe_consumer_store),
  meck:expect(kafe_consumer_store, value, fun
                                            (_, generation_id) -> 0;
                                            (_, member_id) -> <<"member">>
                                          end),
  meck:new(kafe),
  meck:expect(kafe, offset_commit,
              fun(_, _, _, _, [{Topic, [{Partition, _, <<>>}]}]) ->
                  {ok, [#{name => Topic,
                          partitions => [#{error_code => unknown_member_id,
                                           partition => Partition}]}]}
              end),
  meck:new(kafe_metrics),
  meck:expect(kafe_metrics, consumer_partition_pending_commits, 4, ok),
  ?assertMatch({noreply, #state{
                            topic = <<"topic">>,
                            partition = 1,
                            commit_interval = 1000,
                            commit_messages = 1000,
                            commit_timer = _,
                            last_offset = -1,
                            group_id = <<"group">>,
                            commits = [0, 1, 2, 3, 4, 5]}},
               handle_info(commit, #state{
                                      topic = <<"topic">>,
                                      partition = 1,
                                      commit_interval = 1000,
                                      commit_messages = 1000,
                                      commit_timer = undefined,
                                      last_offset = -1,
                                      group_id = <<"group">>,
                                      commits = [0, 1, 2, 3, 4, 5]})),
  meck:unload(kafe_metrics),
  meck:unload(kafe),
  meck:unload(kafe_consumer_store).

info_commit_error_test() ->
  meck:new(kafe_consumer_store),
  meck:expect(kafe_consumer_store, value, fun
                                            (_, generation_id) -> 0;
                                            (_, member_id) -> <<"member">>
                                          end),
  meck:new(kafe),
  meck:expect(kafe, offset_commit,
              fun(_, _, _, _, _) ->
                  {error, test_error}
              end),
  meck:new(kafe_metrics),
  meck:expect(kafe_metrics, consumer_partition_pending_commits, 4, ok),
  ?assertMatch({noreply, #state{
                            topic = <<"topic">>,
                            partition = 1,
                            commit_interval = 1000,
                            commit_messages = 1000,
                            commit_timer = _,
                            last_offset = -1,
                            group_id = <<"group">>,
                            commits = [0, 1, 2, 3, 4, 5]}},
               handle_info(commit, #state{
                                      topic = <<"topic">>,
                                      partition = 1,
                                      commit_interval = 1000,
                                      commit_messages = 1000,
                                      commit_timer = undefined,
                                      last_offset = -1,
                                      group_id = <<"group">>,
                                      commits = [0, 1, 2, 3, 4, 5]})),
  meck:unload(kafe_metrics),
  meck:unload(kafe),
  meck:unload(kafe_consumer_store).

info_commit_hole_test() ->
  meck:new(kafe_consumer_store),
  meck:expect(kafe_consumer_store, value, fun
                                            (_, generation_id) -> 0;
                                            (_, member_id) -> <<"member">>
                                          end),
  meck:new(kafe),
  meck:expect(kafe, offset_commit,
              fun(_, _, _, _, [{Topic, [{Partition, _, <<>>}]}]) ->
                  {ok, [#{name => Topic,
                          partitions => [#{error_code => unknown_member_id,
                                           partition => Partition}]}]}
              end),
  meck:new(kafe_metrics),
  meck:expect(kafe_metrics, consumer_partition_pending_commits, 4, ok),
  ?assertMatch({noreply, #state{
                            topic = <<"topic">>,
                            partition = 1,
                            commit_interval = 1000,
                            commit_messages = 1000,
                            commit_timer = _,
                            last_offset = -1,
                            group_id = <<"group">>,
                            commits = [1, 2, 3, 4, 5]}},
               handle_info(commit, #state{
                                      topic = <<"topic">>,
                                      partition = 1,
                                      commit_interval = 1000,
                                      commit_messages = 1000,
                                      commit_timer = undefined,
                                      last_offset = -1,
                                      group_id = <<"group">>,
                                      commits = [1, 2, 3, 4, 5]})),
  meck:unload(kafe_metrics),
  meck:unload(kafe),
  meck:unload(kafe_consumer_store).

info_commit_hole_commit_test() ->
  meck:new(kafe_consumer_store),
  meck:expect(kafe_consumer_store, value, fun
                                            (_, generation_id) -> 0;
                                            (_, member_id) -> <<"member">>
                                          end),
  meck:new(kafe),
  meck:expect(kafe, offset_commit,
              fun(_, _, _, _, [{Topic, [{Partition, _, <<>>}]}]) ->
                  {ok, [#{name => Topic,
                          partitions => [#{error_code => none,
                                           partition => Partition}]}]}
              end),
  meck:new(kafe_metrics),
  meck:expect(kafe_metrics, consumer_partition_pending_commits, 4, ok),
  ?assertMatch({noreply, #state{
                            topic = <<"topic">>,
                            partition = 1,
                            commit_interval = 1000,
                            commit_messages = 1000,
                            commit_timer = _,
                            last_offset = 3,
                            group_id = <<"group">>,
                            commits = [5, 6, 7]}},
               handle_info(commit, #state{
                                      topic = <<"topic">>,
                                      partition = 1,
                                      commit_interval = 1000,
                                      commit_messages = 1000,
                                      commit_timer = undefined,
                                      last_offset = -1,
                                      group_id = <<"group">>,
                                      commits = [0, 1, 2, 3, 5, 6, 7]})),
  meck:unload(kafe_metrics),
  meck:unload(kafe),
  meck:unload(kafe_consumer_store).

lcs_test() ->
  ?assertMatch([2, 1, 0], lcs(-1, [0, 1, 2])),
  ?assertMatch([], lcs(-1, [1, 2, 3])),
  ?assertMatch([2, 1, 0], lcs(-1, [0, 1, 2, 4, 5])).
-endif.

