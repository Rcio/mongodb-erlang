-module(mongo_sup).
-export([
	start_link/0,
	start_cursor/1,
	start_pool/3,
	stop_pool/1
]).
-export([
	request_id/0,
	object_id/0
]).

-behaviour(supervisor).
-export ([
	init/1
]).

-define(SUPERVISOR(Id, Tag),       {Id, {supervisor, start_link, [?MODULE, Tag]}, permanent, infinity, supervisor, [?MODULE]}).
-define(SUPERVISOR(Id, Name, Tag), {Id, {supervisor, start_link, [{local, Name}, ?MODULE, Tag]}, permanent, infinity, supervisor, [?MODULE]}).
-define(WORKER(M, F, A, R),        {M,  {M, F, A}, R, 5000, worker, [M]}).


-spec start_link() -> {ok, pid()}.
start_link() ->
	supervisor:start_link({local, ?MODULE}, ?MODULE, app).

-spec start_cursor([term()]) -> {ok, pid()}.
start_cursor(Args) ->
	supervisor:start_child(mongo_cursors_sup, [Args]).

-spec start_pool(atom(), pos_integer(), mongo_connection:service()) -> {ok, pid()}.
start_pool(Name, Size, Service) ->
	{ok, Supervisor} = supervisor:start_child(mongo_pools_sup, ?SUPERVISOR(Name, pool)),
	{ok, Connections} = supervisor:start_child(Supervisor, ?SUPERVISOR(mongo_connections_sup, {connections, Service, [{timeout, 5000}]})),
	supervisor:start_child(Supervisor, ?WORKER(mongo_pool, start_link, [Name, Size, Connections], permanent)).

-spec stop_pool(term()) -> ok.
stop_pool(Name) ->
	supervisor:terminate_child(mongo_pools_sup, Name),
	supervisor:delete_child(mongo_pools_sup, Name).

%% @doc Fresh request id
-spec request_id() -> pos_integer().
request_id() ->
	ets:update_counter(?MODULE, requestid_counter, 1).

%% @doc Fresh object id
-spec object_id () -> bson:objectid().
object_id() ->
	Now = bson:unixtime_to_secs(bson:timenow()),
	MPid = ets:lookup_element(?MODULE, oid_machineprocid, 2),
	N = ets:update_counter(?MODULE, oid_counter, 1),
	bson:objectid(Now, MPid, N).

%% @hidden
init(app) ->
	{ok, {
		{one_for_one, 5, 10}, [
			?SUPERVISOR(mongo_cursors_sup, mongo_cursors_sup, cursors),
			?SUPERVISOR(mongo_pools_sup, mongo_pools_sup, pools)
		]
	}};

init(cursors) ->
	{ok, {
		{simple_one_for_one, 5, 10}, [
			?WORKER(mongo_cursor, start_link, [], temporary)
		]
	}};

init(pools) ->
	{ok, {
		{one_for_one, 5, 10}, [
			%% Pool supervisors are dynamically created
		]
	}};

init(pool) ->
	{ok, {
		{one_for_all, 5, 10}, [
			%% Pool Manager dynamically created
			%% Pool Connection supervisor dynamically created
		]
	}};

init({connections, Service, Options}) ->
	{ok, {
		{simple_one_for_one, 5, 10}, [
			?WORKER(mongo_connection, start_link, [Service, Options], temporary)
		]
	}}.

init() ->
	ets:new(?MODULE, [named_table, public, {write_concurrency, true}, {read_concurrency, true}]),
	ets:insert(?MODULE, [
			     {oid_counter, 0},
			     {oid_machineprocid, oid_machineprocid()},
			     {requestid_counter, 0}
			    ]),
	ok.

%% @private
-spec oid_machineprocid() -> <<_:40>>.
oid_machineprocid() ->
	OSPid = list_to_integer(os:getpid()),
	{ok, Hostname} = inet:gethostname(),
	<<MachineId:3/binary, _/binary>> = erlang:md5(Hostname),
	<<MachineId:3/binary, OSPid:16/big>>.

