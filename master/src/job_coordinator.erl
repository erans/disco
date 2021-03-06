-module(job_coordinator).
-export([new/1]).

-include("disco.hrl").
-include("config.hrl").

-type input() :: binary() | [binary()].
-type host() :: nonempty_string() | 'false'.
-type task_input() :: {non_neg_integer(), [{input(), host()}]}.

% In theory we could keep the HTTP connection pending until the job
% finishes but in practice long-living HTTP connections are a bad idea.
% Thus, the HTTP request spawns a new process, job_coordinator, that
% takes care of coordinating the whole map-reduce show, including
% fault-tolerance. The HTTP request returns immediately. It may poll
% the job status e.g. by using handle_ctrl's get_results.
-spec new(binary()) -> {'ok', _}.
new(JobPack) ->
    Self = self(),
    process_flag(trap_exit, true),
    Pid =
        spawn_link(fun() ->
                       case jobpack:valid(JobPack) of
                           ok -> ok;
                           {error, E} -> exit(E)
                       end,
                       case catch job_coordinator(Self, JobPack) of
                           ok -> ok;
                           Error -> exit(Error)
                       end
                   end),
    receive
        {job_submitted, JobName} ->
            {ok, JobName};
        {'EXIT', _From, Reason} ->
            exit(Pid, kill),
            throw(Reason)
    after 60000 ->
            exit(Pid, kill),
            throw("timed out after 60s (master busy?)")
    end.

job_event(JobName, {EventFormat, Args, Params}) ->
    event_server:event(JobName, EventFormat, Args, Params);
job_event(JobName, {EventFormat, Args}) ->
    job_event(JobName, {EventFormat, Args, {}});
job_event(JobName, Event) ->
    job_event(JobName, {Event, [], {}}).

-spec job_coordinator(pid(), binary()) -> 'ok'.
job_coordinator(Parent, JobPack) ->
    {Prefix, JobInfo} = jobpack:jobinfo(JobPack),
    {ok, JobName} = event_server:new_job(Prefix, self()),
    JobFile = jobpack:save(JobPack, disco:jobhome(JobName)),
    ok = disco_server:new_job(JobName, self(), 30000),
    Parent ! {job_submitted, JobName},
    job_coordinator(JobInfo#jobinfo{jobname = JobName, jobfile = JobFile}).

-spec job_coordinator(jobinfo()) -> 'ok'.
job_coordinator(#jobinfo{jobname = JobName} = Job) ->
    job_event(JobName, {"Starting job", [], {job_data, Job}}),
    Started = now(),
    case catch map_reduce(Job) of
        {ok, Results} ->
            job_event(JobName, {"READY: Job finished in ~s",
                                [disco:format_time_since(Started)],
                                {ready, Results}}),
            event_server:end_job(JobName);
        {error, Error} ->
            kill_job(JobName, {"Job failed: ~s", [Error]});
        {error, Error, Params} ->
            kill_job(JobName, {"Job failed: ~s", [Error], Params});
        Error ->
            kill_job(JobName, {"Job coordinator failed unexpectedly: ~p", [Error]})
    end.

-spec kill_job(nonempty_string(), tuple()) -> no_return().
kill_job(JobName, {EventFormat, Args, Params} = Error) ->
    job_event(JobName, {"ERROR: " ++ EventFormat, Args, Params}),
    disco_server:kill_job(JobName, 30000),
    gen_server:cast(event_server, {job_done, JobName}),
    exit(Error);
kill_job(JobName, {EventFormat, Args}) ->
    kill_job(JobName, {EventFormat, Args, {}}).

% work() is the heart of the map/reduce show. First it distributes tasks
% to nodes. After that, it starts to wait for the results and finally
% returns when it has gathered all the results.
-spec work([{non_neg_integer(), [{input(), host()}]}],
           nonempty_string(),
           non_neg_integer(),
           jobinfo(),
           gb_tree()) ->
    {'ok', gb_tree()}.

%. 1. Basic case: Tasks to distribute, maximum number of concurrent tasks (N)
%  not reached.
work([{TaskID, Input}|Inputs], Mode, N, Job, Res) when N < Job#jobinfo.max_cores ->
    Task = #task{from = self(),
                 taskblack = [],
                 fail_count = 0,
                 force_local = Job#jobinfo.force_local,
                 force_remote = Job#jobinfo.force_remote,
                 jobname = Job#jobinfo.jobname,
                 jobenvs = Job#jobinfo.jobenvs,
                 taskid = TaskID,
                 mode = Mode,
                 input = Input,
                 worker = Job#jobinfo.worker},
    submit_task(Task),
    work(Inputs, Mode, N + 1, Job, Res);

% 2. Tasks to distribute but the maximum number of tasks are already running.
% Wait for tasks to return. Note that wait_workers() may return with the same
% number of tasks still running, i.e. N = M.
work([_|_] = IArg, Mode, N, Job, Res) when N >= Job#jobinfo.max_cores ->
    {M, NRes} = wait_workers(N, Res, Mode),
    work(IArg, Mode, M, Job, NRes);

% 3. No more tasks to distribute. Wait for tasks to return.
work([], Mode, N, Job, Res) when N > 0 ->
    {M, NRes} = wait_workers(N, Res, Mode),
    work([], Mode, M, Job, NRes);

% 4. No more tasks to distribute, no more tasks running. Done.
work([], _Mode, 0, _Job, Res) ->
    {ok, Res}.

% wait_workers receives messages from disco_server:clean_worker() that is
% called when a worker exits.
-spec wait_workers(non_neg_integer(), gb_tree(), nonempty_string()) ->
    {non_neg_integer(), gb_tree()}.

% Error condition: should not happen.
wait_workers(0, _Res, _Mode) ->
    throw({error, "Nothing to wait"});
wait_workers(N, Results, Mode) ->
    receive
        {{done, TaskResults}, Task, Host} ->
            event_server:task_event(Task,
                                    disco:format("Received results from ~s", [Host]),
                                    {task_ready, Mode}),
            {N - 1, gb_trees:enter(Task#task.taskid,
                                   {disco:slave_node(Host), TaskResults},
                                   Results)};
        {{error, Error}, Task, Host} ->
            event_server:task_event(Task,
                                    {<<"WARNING">>, Error},
                                    {task_failed, Task#task.mode},
                                    Host),
            handle_data_error(Task, Host),
            {N, Results};
        {{fatal, Error}, Task, Host} ->
            throw({error, disco:format("Worker at '~s' died: ~s", [Host, Error]),
                   {task_failed, Task#task.mode}})
    end.

-spec submit_task(task()) -> 'ok'.
submit_task(Task) ->
    case catch disco_server:new_task(Task, 30000) of
        ok ->
            ok;
        _ ->
            throw({error, disco:format("~s:~B scheduling failed. Try again later.",
                                       [Task#task.mode, Task#task.taskid])})
    end.

% data_error signals that a task failed on an error that is not likely
% to repeat when the task is ran on another node. The function
% handle_data_error() schedules the failed task for a retry, with the
% failing node in its blacklist. If a task fails too many times, as
% determined by check_failure_rate(), the whole job will be terminated.
-spec handle_data_error(task(), node()) -> pid().
handle_data_error(Task, Host) ->
    {ok, MaxFail} = application:get_env(max_failure_rate),
    check_failure_rate(Task, MaxFail),
    spawn_link(fun() ->
                       {A1, A2, A3} = now(),
                       _ = random:seed(A1, A2, A3),
                       T = Task#task.taskblack,
                       C = Task#task.fail_count + 1,
                       S = lists:min([C * ?FAILED_MIN_PAUSE, ?FAILED_MAX_PAUSE]) +
                           random:uniform(?FAILED_PAUSE_RANDOMIZE),
                       event_server:event(
                         Task#task.jobname,
                         "~s:~B Task failed for the ~Bth time. "
                         "Sleeping ~B seconds before retrying.",
                         [Task#task.mode, Task#task.taskid, C, round(S / 1000)],
                         []),
                       timer:sleep(S),
                       submit_task(Task#task{taskblack = [Host|T], fail_count = C})
               end).

-spec check_failure_rate(task(), non_neg_integer()) -> 'ok'.
check_failure_rate(Task, MaxFail) when Task#task.fail_count + 1 < MaxFail ->
    ok;
check_failure_rate(Task, MaxFail) ->
    Message = disco:format("Task failed ~B times. At most ~B failures are allowed.",
                           [Task#task.fail_count + 1, MaxFail]),
    event_server:task_event(Task, {<<"ERROR">>, Message}),
    throw({error, Message}).

map_reduce(#jobinfo{inputs = Inputs} = Job) ->
    {ok, reduce(map(Inputs, Job), Job)}.

-spec map_input([input()]) -> [task_input()].
map_input(Inputs) ->
    disco:enum([case Input of
                    List when is_list(List) ->
                        [{I, preferred_host(I)} || I <- List];
                    I ->
                        [{I, preferred_host(I)}]
                end || Input <- Inputs]).

map(Inputs, #jobinfo{map = false}) ->
    Inputs;
map(Inputs, Job) ->
    run_phase(map_input(Inputs), "map", Job).

-spec shuffle(nonempty_string(), nonempty_string(), [{node(), binary()}]) -> {'ok', [binary()]}.
shuffle(_JobName, _Mode, []) ->
    {ok, []};
shuffle(JobName, Mode, DirUrls) ->
    job_event(JobName, "Starting shuffle phase"),
    Started = now(),
    Ret = shuffle:combine_tasks(JobName, Mode, DirUrls),
    job_event(JobName, {"Finished shuffle phase in ~s",
                        [disco:format_time_since(Started)]}),
    Ret.

-spec reduce_input([input()], non_neg_integer()) -> [task_input()].
reduce_input(Inputs, NRed) ->
    Hosts = lists:usort([case Input of
                             List when is_list(List) andalso length(List) > 1 ->
                                 throw({error, "Redundant inputs in reduce"});
                             Input ->
                                 preferred_host(Input)
                         end || Input <- Inputs]),
    NHosts = length(Hosts),
    case NHosts of
        0 ->
            [];
        _ ->
            HostsD = dict:from_list(disco:enum(Hosts)),
            [{TaskID, [{Inputs, dict:find(TaskID rem NHosts, HostsD)}]}
             || TaskID <- lists:seq(0, NRed - 1)]
    end.

reduce(Inputs, #jobinfo{reduce = false}) ->
    Inputs;
reduce(Inputs, Job) ->
    run_phase(reduce_input(Inputs, Job#jobinfo.nr_reduce),
              "reduce",
              Job#jobinfo{force_local = false,
                          force_remote = false}).

-spec run_phase([task_input()], nonempty_string(), jobinfo()) -> [input()].
run_phase(Inputs, Mode, #jobinfo{jobname = JobName} = Job) ->
    job_event(JobName, {"Starting ~s phase", [Mode]}),
    Started = now(),
    {ok, TaskResults} = work(Inputs, Mode, 0, Job, gb_trees:empty()),
    Fun = fun ({_Node, {none, GResults}}, {Local, Global}) ->
                  {Local, GResults ++ Global};
              ({Node, {LResult, GResults}}, {Local, Global}) ->
                  {[{Node, LResult} | Local], GResults ++ Global}
          end,
    {LResults, GResults} = lists:foldl(Fun, {[], []}, gb_trees:values(TaskResults)),
    % Only local results need to be shuffled.
    {ok, Combined} = shuffle(JobName, Mode, LResults),
    Results = lists:usort(GResults ++ Combined),
    job_event(JobName, {"Finished ~s phase in ~s",
                        [Mode, disco:format_time_since(Started)],
                        {list_to_atom(Mode ++ "_ready"), Results}}),
    Results.

-spec preferred_host(binary()) -> host().
preferred_host(Url) ->
    case re:run(Url, "^[a-zA-Z0-9]+://([^/:]*)",
                [{capture, all_but_first, binary}]) of
        {match, [Match]} ->
            binary_to_list(Match);
        nomatch ->
            false
    end.
