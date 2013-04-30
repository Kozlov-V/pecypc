%%% ----------------------------------------------------------------------------
%%%
%%% @doc Skeleton for a HTTP resource.
%%%
%%% ----------------------------------------------------------------------------

-module(pecypc_api).
-author('Vladimir Dronnikov <dronnikov@gmail.com>').

% -behaviour(cowboy_rest_handler).
-export([
    init/3,
    terminate/3,
    rest_init/2,
    % resource_available/2,
    allowed_methods/2,
    % malformed_request/2,
    is_authorized/2,
    forbidden/2,
    % options/2,
    content_types_accepted/2,
    content_types_provided/2,
    delete_resource/2,
    delete_completed/2
  ]).

% getters
-export([
    get_resource/2
  ]).

% setters
-export([
    put_form/2,
    put_json/2,
    rpc_json/2
  ]).

-type proplist() :: list({term(), term()}).

-record(state, {
    method :: binary(),
    params :: proplist(),
    body :: proplist(),
    query :: proplist(),
    auth :: {Identity :: term(), AllowedScope :: term()},
    completed = false :: boolean(),
    options :: proplist(),
    handler :: module()
  }).

init(_Transport, Req, Opts) ->
  Req2 = case lists:keyfind(patch, 1, Opts) of
    {_, true} ->
      % apply apigen pragmatic REST recommendations
      cowboy_patch:patch_pragmatic_rest(
           cowboy_patch:patch_method(
           cowboy_patch:patch_headers(Req)));
    false ->
      Req
  end,
  % extract request info
  {Params, Req3} = cowboy_req:bindings(Req2),
  {Query, Req4} = cowboy_req:qs_vals(Req3),
  {Method, Req5} = cowboy_req:method(Req4),
  % extract options
  {_, Handler} = lists:keyfind(handler, 1, Opts),
  % go rest
  {upgrade, protocol, cowboy_rest, Req5, #state{
      method = Method,
      % params = Params,
      params = lists:ukeymerge(1,
          lists:ukeysort(1, Params),
          lists:ukeysort(1, Query)),
      query = Query,
      options = Opts,
      handler = Handler
    }}.

terminate(_Reason, _Req, _State) ->
  ok.

rest_init(Req, State) ->
  {ok, Req, State}.

% resource_available(Req, State) ->
%   {true, Req, State}.

allowed_methods(Req, State) ->
  {[<<"GET">>, <<"POST">>, <<"PUT">>, <<"DELETE">>,
    <<"PATCH">>, <<"HEAD">>, <<"OPTIONS">>], Req, State}.

%%
%% Validate GET requests. Body is not yet available and conneg is not yet done.
%%
% malformed_request(Req, State) ->
%   {false, Req, State}.

%%
%% Verify that authentication credentials provided and not forged.
%% Bearer or basic authorization, or session required.
%%
is_authorized(Req, State = #state{options = Opts}) ->
  case cowboy_req:parse_header(<<"authorization">>, Req) of
    {ok, {<<"bearer">>, Token}, Req2} ->
      {_, Secret} = lists:keyfind(token_secret, 1, Opts),
      try_authorize(Req2, State, token, {Token, Secret});
    {ok, {<<"basic">>, Credentials}, Req2} ->
      try_authorize(Req2, State, password, Credentials);
    _ ->
      {Session, Req2} = cowboy_session:get(Req),
      try_authorize(Req2, State, session, Session)
  end.

try_authorize(Req, State = #state{params = Params, handler = Handler},
    Type, Credentials) ->
  case erlang:function_exported(Handler, authorize, 3) of
    true ->
      case Handler:authorize(Type, Credentials, Params) of
        {ok, Auth} ->
          {true, Req, State#state{auth = Auth}};
        {error, _} ->
          {{false, <<"Bearer, Basic, Cookie">>}, Req, State}
      end;
    false ->
      {true, Req, State#state{auth = none}}
  end.

%%
%% Checks user is authorized to access the resource.
%% NB: POST carries batch RPC and access will be checked later on
%%   for each request in the batch.
%%
% forbidden(Req, State = #state{method = <<"POST">>}) ->
%   {false, Req, State};
%%
%% Other methods mean single action and access can be checked at once.
%%
forbidden(Req, State = #state{method = Method,
    auth = Auth, handler = Handler}) ->
  {not call_allowed(handler_for(Method), Auth, Handler), Req, State}.

handler_for(<<"GET">>) -> get;
handler_for(<<"POST">>) -> create;
handler_for(<<"PUT">>) -> put;
handler_for(<<"PATCH">>) -> update;
handler_for(<<"DELETE">>) -> delete;
handler_for(<<"OPTIONS">>) -> info;
handler_for(<<"HEAD">>) -> get.

call_allowed(Method, Auth, Handler) ->
  case erlang:function_exported(Handler, allowed, 2) of
    true ->
      Handler:allowed(Method, Auth);
    false ->
      true
  end.

%%
%% Called on OPTIONS. Use to set custom headers. Note returned tag is 'ok'.
%%
%% @todo Allow-Origin-* here?
%%
% options(Req, State) ->
%   {ok, Req, State}.

%%
%% Enumerate content types resource may process.
%%
content_types_accepted(Req, State) ->
  {[
    {{<<"application">>, <<"json">>, []}, put_json},
    {{<<"application">>, <<"x-www-form-urlencoded">>, []}, put_form},
    % application/rpc+json accepts batch of requests
    {{<<"application">>, <<"rpc+json">>, []}, rpc_json}
  ], Req, State}.

%%
%% Enumerate content types resource may return.
%%
content_types_provided(Req, State) ->
  {[
    {{<<"application">>, <<"json">>, []}, get_resource},
    % @todo disable if application/rpc+json data was provided
    {{<<"application">>, <<"x-www-form-urlencoded">>, []}, get_resource}
  ], Req, State}.

%%
%% -----------------------------------------------------------------------------
%% Resource operations.
%% -----------------------------------------------------------------------------
%%

%%
%% Delegates actual processing to application's get/2 handler.
%% Encodes response entity.
%%
%%
%% - {Body, Req, State} --> 200 OK
%% - {halt, Req, State} --> no further processing
%%
get_resource(Req, State = #state{
    params = Params, handler = Handler, options = Opts, auth = Auth}) ->
  try Handler:get(Params, [{auth, Auth} | Opts]) of
    {ok, Result} ->
      % @todo CORS
      {serialize(Result, Req), Req, State};
    {error, Reason} ->
      {halt, respond(400, Reason, Req), State};
    error ->
      {halt, respond(400, undefined, Req), State};
    {goto, Location} ->
      {halt, cowboy_req:set_resp_header(<<"location">>, Location, Req), State}
  catch Class:Reason ->
    error_logger:error_msg(
      "** API handler ~p terminating in get/3~n"
      "   for the reason ~p:~p~n** State was ~p~n"
      "** Stacktrace: ~p~n~n",
      [Handler, Class, Reason, State, erlang:get_stacktrace()]),
    {halt, respond(500, Reason, Req), State}
  end.

%%
%% Handle PUT/POST/PATCH requests.
%%
%% - {false, Req, State} --> 422 Unprocessable Entity
%% - {true, Req, State} --> 204 No Content
%% - {halt, Req, State} --> no further processing
%%
%% The following applies only on PUT
%% - set response location: and {true, Req, State} --> 201 Created
%% - set response body and {true, Req, State} --> 200 OK
%%
%% The following applies only on POST
%% - {Location, Req, State} --> 303 See Other
%%
put_json(Req, State) ->
  % @todo make it streaming
  {ok, Body, Req2} = cowboy_req:body(Req),
  case jsx:decode(Body, [{error_handler, fun(_, _, _) -> {error, badarg} end}])
  of
    {error, _} ->
      {false, Req2, State};
    {incomplete, _} ->
      {false, Req2, State};
    Data ->
      put_resource(Req2, State#state{body = Data})
  end.

put_form(Req, State) ->
  {ok, Result, Req2} = cowboy_req:body_qs(Req),
  put_resource(Req2, State#state{body = Result}).

%%
%% Take batch of requests from body, return batch of responses.
%% Requests processing delegated to application's handle(Method, [Args]).
%%
%% Request is triplet array: [Method, Params, Id].
%% Response is triplet array: [null, Result, Id] | [Error, null, Id].
%%
rpc_json(Req, State) ->
  % @todo make it streaming
  {ok, Body, Req2} = cowboy_req:body(Req),
  case jsx:decode(Body, [{error_handler, fun(_, _, _) -> {error, badarg} end}])
  of
    {error, _} ->
      {false, Req2, State};
    {incomplete, _} ->
      {false, Req2, State};
    Data ->
      State2 = State#state{body = Data},
      {halt, respond(200, batch_rpc(State2), Req2), State2}
  end.

%%
%% @todo add more body decoders here. multipart is welcome.
%%

%%
%% Bodyful methods delegate actual processing to application's handlers.
%% Response entity is encoded according to Accept: header.
%%
put_resource(Req, State = #state{method = <<"POST">>, body = Data,
    params = Params, handler = Handler, options = Opts, auth = Auth}) ->
  % {halt, respond(200, batch_rpc(State), Req), State};
  try Handler:create(Data, Params, [{auth, Auth} | Opts]) of
    {ok, Body} ->
      {true, set_resp_body(Body, Req), State};
    ok ->
      {true, Req, State};
    {error, Reason} ->
      {halt, respond(400, Reason, Req), State};
    error ->
      {halt, respond(400, undefined, Req), State};
    {goto, Location} ->
      % {true, cowboy_req:set_resp_header(<<"location">>, Location, Req), State}
      {Location, Req, State}
  catch Class:Reason ->
    error_logger:error_msg(
      "** API handler ~p terminating in create/3~n"
      "   for the reason ~p:~p~n** State was ~p~n"
      "** Stacktrace: ~p~n~n",
      [Handler, Class, Reason, State, erlang:get_stacktrace()]),
    {halt, respond(500, Reason, Req), State}
  end;

put_resource(Req, State = #state{method = <<"PUT">>, body = Data,
    params = Params, handler = Handler, options = Opts, auth = Auth}) ->
  try Handler:put(Data, Params, [{auth, Auth} | Opts]) of
    ok ->
      {true, Req, State};
    {ok, Body} ->
      {true, set_resp_body(Body, Req), State};
    {error, Reason} ->
      {halt, respond(400, Reason, Req), State};
    error ->
      {halt, respond(400, undefined, Req), State}
  catch Class:Reason ->
    error_logger:error_msg(
      "** API handler ~p terminating in put/3~n"
      "   for the reason ~p:~p~n** State was ~p~n"
      "** Stacktrace: ~p~n~n",
      [Handler, Class, Reason, State, erlang:get_stacktrace()]),
    {halt, respond(500, Reason, Req), State}
  end;

put_resource(Req, State = #state{method = <<"PATCH">>, body = Data,
    params = Params, handler = Handler, options = Opts, auth = Auth}) ->
  try Handler:update(Data, Params, [{auth, Auth} | Opts]) of
    ok ->
      {true, Req, State};
    {ok, Body} ->
      {true, set_resp_body(Body, Req), State};
    {error, Reason} ->
      {halt, respond(400, Reason, Req), State};
    error ->
      {halt, respond(400, undefined, Req), State}
  catch Class:Reason ->
    error_logger:error_msg(
      "** API handler ~p terminating in update/3~n"
      "   for the reason ~p:~p~n** State was ~p~n"
      "** Stacktrace: ~p~n~n",
      [Handler, Class, Reason, State, erlang:get_stacktrace()]),
    {halt, respond(500, Reason, Req), State}
  end.

%%
%% Delegates actual processing to application's delete/2 handler.
%%
%% It should start deleting the resource and return.
%% - {true, Req, State} --> 204 No Content, unless delete_completed/2 defined
%% - {X =/= true, Req, State} --> 500 Internal Server Error
%% - {halt, Req, State} --> no further processing
%%
delete_resource(Req, State = #state{
    params = Params, handler = Handler, options = Opts, auth = Auth}) ->
  try Handler:delete(Params, [{auth, Auth} | Opts]) of
    ok ->
      {true, Req, State#state{completed = true}};
    accepted ->
      {true, Req, State#state{completed = false}};
    error ->
      {halt, respond(400, undefined, Req), State};
    {error, Reason} ->
      {halt, respond(400, Reason, Req), State}
  catch Class:Reason ->
    error_logger:error_msg(
      "** API handler ~p terminating in delete/3~n"
      "   for the reason ~p:~p~n** State was ~p~n"
      "** Stacktrace: ~p~n~n",
      [Handler, Class, Reason, State, erlang:get_stacktrace()]),
    {halt, respond(500, Reason, Req), State}
  end.

%%
%% Indicates whether the resource has been deleted yet.
%% - {true, Req, State} --> go ahead with 200/204
%% - {false, Req, State} --> 202 Accepted
%% - {halt, Req, State} --> no further processing
%%
delete_completed(Req, State = #state{completed = Completed}) ->
  {Completed, Req, State}.

%%
%%------------------------------------------------------------------------------
%% RPC functions
%%------------------------------------------------------------------------------
%%

batch_rpc(#state{body = Batch,
    handler = Handler, auth = Auth, options = Opts}) ->
  [case call_allowed(Method, Auth, Handler) of
    true ->
      try Handler:call(Method, Args, Opts) of
        {ok, Result} ->
          [null, Result, Id];
        ok ->
          [null, null, Id];
        % {error, Reason} when is_atom(Reason) ->
        %   [atom_to_binary(Reason, latin1), null, Id];
        {error, Reason} ->
          [Reason, null, Id];
        error ->
          [reason(undefined), null, Id];
        accepted ->
          [null, null, Id];
        {goto, Location} ->
          [null, Location, Id]
      catch
        _:function_clause ->
          [<<"enoent">>, null, Id];
        _:badarg ->
          [<<"einval">>, null, Id];
        _:badarith ->
          [<<"einval">>, null, Id];
        Class:Reason ->
          error_logger:error_msg(
            "** API RPC handler ~p terminating in handle/3~n"
            "   for the reason ~p:~p~n** Method was ~p~n"
            "** Arguments were ~p~n** Stacktrace: ~p~n~n",
            [Handler, Class, Reason, Method, Args, erlang:get_stacktrace()]),
          [<<"einval">>, null, Id]
      end;
    false ->
      [<<"eperm">>, null, Id]
  end || [Method, Args, Id] <- Batch].

%%
%% -----------------------------------------------------------------------------
%% Helpers
%% -----------------------------------------------------------------------------
%%

%%
%% Error reporting.
%%
reason(undefined) ->
  reason(<<"unknown">>);
reason(Reason) when is_list(Reason) ->
  Reason;
reason(Reason) when is_binary(Reason); is_number(Reason) ->
  reason([{error, Reason}]);
reason(Reason) when is_atom(Reason) ->
  reason(atom_to_binary(Reason, latin1)).

%%
%% Response helpers
%%
respond(Status, Reason, Req) ->
  {ok, Req2} = cowboy_req:reply(Status, set_resp_body(reason(Reason), Req)),
  Req2.

set_resp_body(Body, Req) ->
  cowboy_req:set_resp_body(serialize(Body, Req), Req).

%%
%% -----------------------------------------------------------------------------
%% Serialization
%% -----------------------------------------------------------------------------
%%

serialize(Body, Req) ->
  % NB: we choose encoder from media_type meta, honoring Accept: header.
  % One may choose to always encode to one fixed format as well.
  {CType, _} = cowboy_req:meta(media_type, Req),
  encode(CType, Body, Req).

%% NB: first argument should match those of content_types_*/2
encode({<<"application">>, <<"x-www-form-urlencoded">>, []}, Body, _Req) ->
  build_qs(Body);
encode({<<"application">>, <<"json">>, []}, Body, _Req) ->
  jsx:encode(Body).

%% NB: Cowboy issue #479
urlencode(Bin) when is_binary(Bin) ->
  cowboy_http:urlencode(Bin);
urlencode(Atom) when is_atom(Atom) ->
  urlencode(atom_to_binary(Atom, latin1));
urlencode(Int) when is_integer(Int) ->
  % NB: nothing unsafe in integers
  list_to_binary(integer_to_list(Int)).

build_qs_pair({K, undefined}) ->
  << (urlencode(K))/binary, $= >>;
build_qs_pair({K, V}) ->
  << (urlencode(K))/binary, $=, (urlencode(V))/binary >>.

-spec build_qs(Params :: proplist()) -> binary().
build_qs([]) ->
  <<>>;
build_qs(List) when is_list(List) ->
  << "&", R/binary >> = << << "&", (build_qs_pair(X))/binary >> || X <- List >>,
  R.
