% @hidden
-module(kafe_protocol_heartbeat).

-include("../include/kafe.hrl").

-export([
         run/3,
         request/4,
         response/2
        ]).

run(GroupId, GenerationId, MemberId) ->
  kafe_protocol:run({coordinator, GroupId},
                    {call,
                     fun ?MODULE:request/4, [GroupId, GenerationId, MemberId],
                     fun ?MODULE:response/2}).

% Heartbeat Request (Version: 0) => group_id group_generation_id member_id
%   group_id => STRING
%   group_generation_id => INT32
%   member_id => STRING
request(GroupId, GenerationId, MemberId, State) ->
  kafe_protocol:request(
    ?HEARTBEAT_REQUEST,
    <<(kafe_protocol:encode_string(GroupId))/binary,
      GenerationId:32/signed,
      (kafe_protocol:encode_string(MemberId))/binary>>,
    State,
    ?V0).

% Heartbeat Response (Version: 0) => error_code
%   error_code => INT16
response(<<ErrorCode:16/signed>>,
         _ApiVersion) ->
      {ok, #{error_code => kafe_error:code(ErrorCode)}}.

