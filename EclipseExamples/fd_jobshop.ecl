%
% Scheduling with ECLiPSe
%
% Author: Joachim Schimpf, IC-Parc
%

/*
:- module(ic_jobshop).
:- lib(ic).
:- lib(ic_edge_finder3).
%:- lib(ic_edge_finder).
*/

:- module(fd_jobshop).
:- lib(fd).
:- lib(fd_search).
:- lib(edge_finder3).
%:- lib(edge_finder).

get_bounds(X, Min, Max) :-
	dvar_range(X, Min, Max).

get_min(X, Min) :-
	mindomain(X, Min).


:- lib(viewable).


:- export struct(task(
	name,		% atom
	start,		% integer variable
	duration,	% integer
	need,		% list of tasks
	use,		% resource id (1..NRes, 0 if no resource needed)
	use_index	% index of this task within its resource (integer > 0)
    )).


:- export struct(resource(
    	name,		% atom
    	index,		% resource id 1..NRes
	tasks,		% list of tasks requiring this resource
	order,		% lower triangular matrix of ordering booleans
	amount		% sum of task durations - needed?
    )).


:- export struct(task_interval(
	est,		% earliest start time for any task in this interval
	lct,		% latest completion time for any task in this interval
	demand,		% sum of all task durations in this interval
	slack,		% = lct-est-demand (redundant, for sorting)
	tasks		% list of tasks in this task interval
    )).

:- export
	get_bench/4,

	make_viewable/2,

	init_start_times/1,
	init_start_times/2,
	precedence_setup/1,
	assign_min/1,
	assign_min_starts/1,

	order_tasks_est_lst/3,
	order_tasks_lct_ect/3,
	order_tasks_edd_est/3,
	order_tasks_lrd_lct/3,
	current_task_intervals/3,

	make_resource_descriptors/3,
	setup_disjunctive/1,
	ordering_bool_array/2,

	possible_firsts_and_lasts/4,
	possible_firsts_list/4,
	possible_lasts_list/4,
	order_tasks/4,
	can_schedule_task/4,
	schedule_task/4.


%----------------------------------------------------------------------
% Statistics, visualisation, debugging
%----------------------------------------------------------------------

%expect(_).
expect(Goal) :- ( Goal -> true ; printf(error, "Unexpected failure: %w%n", [Goal]), abort ).


make_viewable(Name, Tasks) :-
	(
	  foreach(task{name:Name,start:S,duration:D,use:R},Tasks),
	  fromto(Ss,Ss1,Ss0,[]), fromto(Ds,Ds1,Ds0,[]), fromto(Rs,Rs1,Rs0,[]),
	  fromto(Names,Ns1,Ns0,[])
	do
	    ( R == 0 ->
	    	Ss1=Ss0, Ds1=Ds0, Rs1=Rs0, Ns1=Ns0
	    ;
		atom_string(Name, N),
	    	Ss1=[S|Ss0], Ds1=[D|Ds0], Rs1=[R|Rs0], Ns1=[N|Ns0]
	    )
	),

	viewable_create(Name, [Ss,Ds,Rs],
		array([fixed,fixed], numeric_bounds),
		[["Start","Duration","Resource"], Names]).


%----------------------------------------------------------------------
% Tasks, start/end times and precedence constraints
%----------------------------------------------------------------------

init_start_times(Tasks) :-
	init_start_times(Tasks, _Starts).

init_start_times(Tasks, Starts) :-
	(
	    foreach(task{start:S,duration:D},Tasks),
	    fromto(0, D0, D1, Demand),
	    fromto(0, MinD0, MinD1, MinD),
	    foreach(S,Starts)
	do
	    D1 is D0+D,
	    MinD1 is min(D,MinD0)
	),
	Starts :: 0..Demand-MinD.


precedence_setup(Tasks) :-
	( foreach(task{start:Start,need:NeededTasks},Tasks) do
	    ( foreach(task{start:S,duration:D},NeededTasks), param(Start) do
		Start #>= S+D
	    )
	).


% Order a list of tasks according to ascending EST-LST.
% Also return the EST-LST difference between the first two tasks.
order_tasks_est_lst(Tasks, OrderedTasks, Diff) :-
	( foreach(T, Tasks), foreach(t(EST,LST,T), TTasks0) do
	    T = task{start:S},
	    get_bounds(S,EST,LST)
	),
	sort(2, =<, TTasks0, TTasks1),
	sort(1, =<, TTasks1, TTasks2),
	( foreach(T, OrderedTasks), foreach(t(_,_,T), TTasks2) do
	    true
	),
	( TTasks2 = [t(EST1,LST1,_),t(EST2,LST2,_)|_] ->
	    D1 is EST2-EST1, D2 is LST2-LST1, Diff = D1-D2
	;
	    Diff = 0-0
	).

order_tasks_edd_est(Tasks, OrderedTasks, Diff) :-
	( foreach(T, Tasks), foreach(t(EDD,EST,T), TTasks0) do
	    T = task{start:S,duration:D},
	    get_bounds(S,EST,LST),
	    EDD is LST+D
	),
	sort(2, =<, TTasks0, TTasks1),
	sort(1, =<, TTasks1, TTasks2),
	( foreach(T, OrderedTasks), foreach(t(_,_,T), TTasks2) do
	    true
	),
	( TTasks2 = [t(EDD1,EST1,_),t(EDD2,EST2,_)|_] ->
	    D1 is EDD2-EDD1, D2 is EST2-EST1, Diff = D1-D2
	;
	    Diff = 0-0
	).

order_tasks_lct_ect(Tasks, OrderedTasks, Diff) :-
	( foreach(T, Tasks), foreach(t(LCT,ECT,T), TTasks0) do
	    T = task{start:S,duration:D},
	    get_bounds(S,EST,LST),
	    LCT is LST+D,
	    ECT is EST+D
	),
	sort(2, >=, TTasks0, TTasks1),
	sort(1, >=, TTasks1, TTasks2),
	( foreach(T, OrderedTasks), foreach(t(_,_,T), TTasks2) do
	    true
	),
	( TTasks2 = [t(LCT1,ECT1,_),t(LCT2,ECT2,_)|_] ->
	    D1 is LCT1-LCT2, D2 is ECT1-ECT2, Diff = D1-D2
	;
	    Diff = 0-0
	).

order_tasks_lrd_lct(Tasks, OrderedTasks, Diff) :-
	( foreach(T, Tasks), foreach(t(LRD,LCT,T), TTasks0) do
	    T = task{start:S,duration:D},
	    get_bounds(S,LRD,LST),
	    LCT is LST+D
	),
	sort(2, >=, TTasks0, TTasks1),
	sort(1, >=, TTasks1, TTasks2),
	( foreach(T, OrderedTasks), foreach(t(_,_,T), TTasks2) do
	    true
	),
	( TTasks2 = [t(LRD1,LCT1,_),t(LRD2,LCT2,_)|_] ->
	    D1 is LRD1-LRD2, D2 is LCT1-LCT2, Diff = D1-D2
	;
	    Diff = 0-0
	).


% Deterministically assign minimum start times to a set of
% fully ordered tasks. This will succeed if there are only
% precedence constraints between the tasks and the constraints
% are bounds-consistent.

assign_min(Ss) :-
	( assign_min(Ss, 0) ->
	    true
	;
	    writeln(error, "Unexpected failure of assing_min/1!"),
	    abort
	).
	
assign_min([],_).
assign_min(SSs, Indent) :-
	delete(S, SSs, Ss, 0, smallest),
	get_min(S, Min),
%	printf("%*c%w%n%b", [Indent,0' ,Min]),
	S = Min,
	Indent1 is Indent+1,
	assign_min(Ss, Indent1).

assign_min_starts(Tasks) :-
	( assign_min_starts1(Tasks) ->
	    true
	;
	    writeln(error, "Unexpected failure of assing_min_starts/1!"),
	    abort
	).
	
    assign_min_starts1([]).
    assign_min_starts1(Tasks) :-
	Tasks = [_|_],
	delete(Task, Tasks, Tasks1, start of task, smallest),
	Task = task{start:S},
	get_min(S, Min),
	S = Min,
	true,
	assign_min_starts1(Tasks1).


%----------------------------------------------------------------------
% Task interval handling
%----------------------------------------------------------------------


% This computes the (nonredundant) set of task intervals of the
% tasks Tasks, based on the current domains of their start times.

current_task_intervals(Tasks, TIs, LargestTI) :-
	% annotate tasks with earliest start and latest completion time
	( foreach(T,Tasks), foreach(current_task(EST,LCT,T),CTasks) do
	    T = task{start:S,duration:D},
	    get_bounds(S,EST,LST),
	    LCT is LST+D
	),
	sort(1, =<, CTasks, CTasksAscEST),
	sort(2, =<, CTasksAscEST, CTasksAscLCT),
	(
	    fromto(CTasksAscLCT,CTasksAscLCT1,CTasksAscLCT2,[]),
	    fromto([],AscEST1,AscEST2,_AscEST),
	    fromto(0,Demand1,Demand2,_Demand),
	    fromto(TIs,TIs1,TIs4,[]),
	    fromto(none,_,LargestTI0,LargestTI)
	do
	    % pick next bunch of tasks with common LCT (and ascending EST)
	    tasks_with_lct(CTasksAscLCT1, LCT, TasksLCT, CTasksAscLCT2, 0, DemandLCT),
	    Demand2 is Demand1 + DemandLCT,

	    % merge new tasks with previous ones, ascending EST
	    merge(1, =<, TasksLCT, AscEST1, AscEST2),

	    % The merge result AscEST2 is the largest task interval for LCT.
	    % All tails that still contain a task ending in LCT are also
	    % task intervals for LCT.
	    (
		fromto(TasksLCT, TasksLCT1, TasksLCT2, []),
	    	fromto(AscEST2, AscEST3, AscEST4, _),
		fromto(none, EST0, EST, _),
		fromto(Demand2,Demand3,Demand4,_DemandRest),
		fromto(TIs1,TIs2,TIs3,TIs4),
		param(LCT)
	    do
		AscEST3 = [current_task(EST,TaskLCT,task{duration:D})|AscEST4],
		Demand4 is Demand3 - D,
		( TaskLCT = LCT ->
		    TasksLCT1 = [_|TasksLCT2]	% lost one task with LCT
		;
		    TasksLCT1 = TasksLCT2
		),
		( EST = EST0 ->
		    TIs2 = TIs3			% same EST as before (redundant)
		;
		    TIs2 = [TI|TIs3],		% new task interval EST..LCT
		    TI = task_interval{est:EST,lct:LCT,demand:Demand3,slack:Slack,tasks:AscEST3},
		    Slack is (LCT-EST)-Demand3
%		    ,print_ti(TI)
%		    ,check_ti(TI)
		)
	    ),
	    TIs1 = [LargestTI0|_]	% first of last group is min(EST)..max(LCT)
	).

    tasks_with_lct([], _, [], [], D, D).
    tasks_with_lct(CTasksAscLCT, LCT, TasksLCT, CTasksAscLCT2, D0, D) :-
	CTasksAscLCT = [CT|CTs],
	( CT = current_task(_,LCT,task{duration:TD}) ->
	    D1 is D0 + TD,
	    TasksLCT = [CT|TasksLCT0],
	    tasks_with_lct(CTs, LCT, TasksLCT0, CTasksAscLCT2, D1, D)
	;
	    D = D0,
	    TasksLCT = [],
	    CTasksAscLCT2 = CTasksAscLCT
	).


% Check that a task interval is valid

check_ti(task_interval{est:EST,lct:LCT,demand:Demand,slack:Slack,tasks:TasksInInterval}) :-
	expect(TasksInInterval = [_|_]),
	expect(LCT > EST),
	expect(Slack =:= LCT-EST-Demand),
	expect(Slack >= 0),
	(
	    foreach(current_task(A,C,task{duration:D}),TasksInInterval),
	    fromto(10000000, Min1, Min2, Min),
	    fromto(0, Max1, Max2, Max),
	    fromto(0, Demand1, Demand2, Demand),
	    param(EST,LCT)
	do
	    expect(A>=EST),
	    expect(C=<LCT),
	    Min2 is min(Min1,A),
	    Max2 is max(Max1,C),
	    Demand2 is Demand1 + D
	),
	expect(EST==Min),
	expect(LCT==Max).

print_ti(task_interval{est:EST,lct:LCT,demand:Demand,slack:Slack,tasks:TasksInInterval}) :-
	printf("TI %4d..%4d, d=%4d, s=%4d:", [EST,LCT,Demand,Slack]),
	(
	    foreach(current_task(A,C,task{name:Name}),TasksInInterval)
	do
	    printf(" %w(%w,%w)", [Name,A,C])
	),
	nl.


%----------------------------------------------------------------------
% Resources with disjunctive tasks
%----------------------------------------------------------------------

% make resource descriptors
% and fill in the use_index field in the task descriptors

make_resource_descriptors(Tasks, NRes, Resources) :-
	dim(Resources, [NRes]),
	(
	    foreacharg(resource{name:Name,index:RId,tasks:TasksUsingR,order:Order,amount:Amount},Resources,RId),
	    param(Tasks)
	do
	    concat_atom([res,RId], Name),
	    % find all tasks using resource RId
	    (
		foreach(T,Tasks),
		fromto(TasksUsingR, RTs, RTs0, []),
		fromto(0, N0, N1, NTasks),
		fromto(0, Amount0, Amount1, Amount),
		param(RId)
	    do
		( T = task{use:RId,duration:D,use_index:N1} ->
		    RTs = [T|RTs0],
		    N1 is N0 + 1,
		    Amount1 is Amount0 + D
		;
		    RTs = RTs0,
		    N1 = N0,
		    Amount1 = Amount0
		)
	    ),

	    % Construct a diagonal matrix of ordering-booleans.
	    % When flattened row-wise, this gives the same order
	    % as in the disjunctive_bools/3 constraint.
	    %
	    %	  J=1 2 3 4 5
	    %   I
	    %	1   . . . . .
	    %	2   0 . . . .
	    %	3   1 2 . . .
	    %	4   3 4 5 . .
	    %	5   6 7 8 9 .
	    %
	    % if (J < I)
	    %	Order[I,J] = 1 <=> TaskI before TaskJ
	    % else
	    %	Order[J,I] = 0 <=> TaskI before TaskJ
	    %
	    dim(Order, [NTasks]),
	    (
		for(M,0,NTasks-1),
	    	foreacharg(OrderI,Order)
	    do
		dim(OrderI, [M])
	    )
	).



% Setup the disjunctive constraint for the tasks on each resource

setup_disjunctive(Resources) :-
	(
	    foreacharg(Resource, Resources)
	do
	    Resource = resource{tasks:Tasks},
	    % make Starts and Durations lists
	    (
		foreach(task{start:S,duration:D},Tasks),
		foreach(S,Starts),
		foreach(D,Durations)
	    do
		true
	    ),
	    ordering_booleans(Resource, Bools, []),
	    Bools :: 0..1,
	    disjunctive_bools(Starts, Durations, Bools)
	).


ordering_bool_array(Resource, BoolArr) :-
	Resource = resource{}, !,
	ordering_booleans(Resource, Bools, []),
	BoolArr =.. [[]|Bools].
ordering_bool_array(Resources, BoolArr) :-
	( foreacharg(Resource, Resources), fromto(Bools,Bs1,Bs2,[]) do
	    ordering_booleans(Resource, Bs1, Bs2)
	),
	BoolArr =.. [[]|Bools].

    ordering_booleans(resource{order:Order}, Bools, Bools0) :-
	% flatten ordering matrix into a list
	( foreacharg(OrderJ,Order), fromto(Bools,Bs1,Bs3,Bools0) do
	    ( foreacharg(B,OrderJ), fromto(Bs1,[B|Bs2],Bs2,Bs3) do
		true
	    )
	).


% Before = 1: I before J
% Before = 0: J before I

order_tasks(resource{order:Order}, I, J, Before) :-
	    ( J < I ->
		Order[I,J] #= Before
	    ; J > I ->
		Order[J,I] #= 1-Before
	    ;
		expect(false)
	    ).


% schedule_task(Resource, Task, RemainingTasks, First)
% First = 1: schedule Task before RemainingTasks
% First = 0: schedule Task after RemainingTasks

schedule_task(resource{order:Order}, task{use_index:I}, RemainingTasks, First) :-
	(
	    foreach(TJ, RemainingTasks),
	    foreach(Bool,Bools),
	    foreach(Val,Vals),
	    param(Order,I,First)
	do
	    TJ = task{use_index:J},
	    ( J < I ->
%		Order[I,J] #= First,
		Bool is Order[I,J],
		Val = First
	    ; J > I ->
%		Order[J,I] #= 1-First,
		Bool is Order[J,I],
		Val is 1-First
	    ;
		expect(false)
	    )
	),
	Bools = Vals.		% unify all Bools atomically


% can_schedule_task(Resource, Task, RemainingTasks, First)
% First = 1: schedule Task before RemainingTasks
% First = 0: schedule Task after RemainingTasks
% Check if a task can still be scheduled first/last wrt RemainingTasks

can_schedule_task(resource{order:Order}, task{use_index:I}, RemainingTasks, First) :-
	(
	    foreach(TJ, RemainingTasks),
	    param(Order,I,First)
	do
	    TJ = task{use_index:J},
	    ( J < I ->
		Bool is Order[I,J],
		( var(Bool) -> true ; Bool =:= First )
	    ; J > I ->
		Bool is Order[J,I],
		( var(Bool) -> true ; Bool =:= 1-First )
	    ;
		expect(false)
	    )
	).

possible_firsts_and_lasts(Resource, UTasks, NFirsts, NLasts) :-
	Resource = resource{order:Order},
	(
	    foreach(task{use_index:I}, UTasks),
	    fromto(0,NFirst1,NFirst2,NFirsts),
	    fromto(0,NLast1,NLast2,NLasts),
	    param(Order,UTasks)
	do
	    % Check if task I can be first/last among the others
	    % Using the booleans computed by the edge_finder
	    (
		foreach(task{use_index:J}, UTasks),
		param(Order,I,First,Last)
	    do
		( J < I ->
		    Bool is Order[I,J],
		    ( Bool == 0 -> First = false
		    ; Bool == 1 -> Last = false
		    ; true
		    )
		; J > I ->
		    Bool is Order[J,I],
		    ( Bool == 0 -> Last = false
		    ; Bool == 1 -> First = false
		    ; true
		    )
		;
		    true
		)
	    ),
	    ( var(First) -> NFirst2 is NFirst1 + 1 ; NFirst2 = NFirst1 ),
	    ( var(Last) -> NLast2 is NLast1 + 1 ; NLast2 = NLast1 )
	).


possible_firsts_list(Resource, UTasks, Firsts, Rests) :-
	Resource = resource{order:Order},
	(
	    foreach(Task, UTasks),
	    fromto(Firsts,Firsts1,Firsts2,[]),
	    fromto(Rests,Rests1,Rests2,[]),
	    param(Order,UTasks)
	do
	    Task = task{use_index:I},
	    % Check if task I can be first/last among the others
	    % Using the booleans computed by the edge_finder
	    (
		foreach(task{use_index:J}, UTasks),
		param(Order,I,First)
	    do
		( J < I ->
		    Bool is Order[I,J],
		    ( Bool == 0 -> First = false
		    ; true
		    )
		; J > I ->
		    Bool is Order[J,I],
		    ( Bool == 1 -> First = false
		    ; true
		    )
		;
		    true
		)
	    ),
	    ( var(First) -> Firsts1 = [Task|Firsts2], Rests1 = Rests2
	    ; Firsts1 = Firsts2, Rests1 = [Task|Rests2] )
	).

possible_lasts_list(Resource, UTasks, Lasts, Rests) :-
	Resource = resource{order:Order},
	(
	    foreach(Task, UTasks),
	    fromto(Lasts,Lasts1,Lasts2,[]),
	    fromto(Rests,Rests1,Rests2,[]),
	    param(Order,UTasks)
	do
	    Task = task{use_index:I},
	    % Check if task I can be first/last among the others
	    % Using the booleans computed by the edge_finder
	    (
		foreach(task{use_index:J}, UTasks),
		param(Order,I,Last)
	    do
		( J < I ->
		    Bool is Order[I,J],
		    ( Bool == 1 -> Last = false
		    ; true
		    )
		; J > I ->
		    Bool is Order[J,I],
		    ( Bool == 0 -> Last = false
		    ; true
		    )
		;
		    true
		)
	    ),
	    ( var(Last) -> Lasts1 = [Task|Lasts2], Rests1 = Rests2
	    ; Lasts1 = Lasts2, Rests1 = [Task|Rests2] )
	).

%----------------------------------------------------------------------
% The benchmarks from ORLIB
%----------------------------------------------------------------------

% jobshop(Name, Comment, M, N, <Matrix of JobNr-Duration pairs>)

jobshop(abz5, "Adams, Balas, and Zawack 10x10 instance (Table 1, instance 5)", 10, 10, []([](4-88, 8-68, 6-94, 5-99, 1-67, 2-89, 9-77, 7-99, 0-86, 3-92), [](5-72, 3-50, 6-69, 4-75, 2-94, 8-66, 0-92, 1-82, 7-94, 9-63), [](9-83, 8-61, 0-83, 1-65, 6-64, 5-85, 7-78, 4-85, 2-55, 3-77), [](7-94, 2-68, 1-61, 4-99, 3-54, 6-75, 5-66, 0-76, 9-63, 8-67), [](3-69, 4-88, 9-82, 8-95, 0-99, 2-67, 6-95, 5-68, 7-67, 1-86), [](1-99, 4-81, 5-64, 6-66, 8-80, 2-80, 7-69, 9-62, 3-79, 0-88), [](7-50, 1-86, 4-97, 3-96, 0-95, 8-97, 2-66, 5-99, 6-52, 9-71), [](4-98, 6-73, 3-82, 2-51, 1-71, 5-94, 7-85, 0-62, 8-95, 9-79), [](0-94, 6-71, 3-81, 7-85, 1-66, 2-90, 4-76, 5-58, 8-93, 9-97), [](3-50, 0-59, 1-82, 8-67, 7-56, 9-96, 6-58, 4-81, 5-59, 2-96))).
jobshop(abz6, "Adams, and Zawack 10x10 instance (Table 1, instance 6)", 10, 10, []([](7-62, 8-24, 5-25, 3-84, 4-47, 6-38, 2-82, 0-93, 9-24, 1-66), [](5-47, 2-97, 8-92, 9-22, 1-93, 4-29, 7-56, 3-80, 0-78, 6-67), [](1-45, 7-46, 6-22, 2-26, 9-38, 0-69, 4-40, 3-33, 8-75, 5-96), [](4-85, 8-76, 5-68, 9-88, 3-36, 6-75, 2-56, 1-35, 0-77, 7-85), [](8-60, 9-20, 7-25, 3-63, 4-81, 0-52, 1-30, 5-98, 6-54, 2-86), [](3-87, 9-73, 5-51, 2-95, 4-65, 1-86, 6-22, 8-58, 0-80, 7-65), [](5-81, 2-53, 7-57, 6-71, 9-81, 0-43, 4-26, 8-54, 3-58, 1-69), [](4-20, 6-86, 5-21, 8-79, 9-62, 2-34, 0-27, 1-81, 7-30, 3-46), [](9-68, 6-66, 5-98, 8-86, 7-66, 0-56, 3-82, 1-95, 4-47, 2-78), [](0-30, 3-50, 7-34, 2-58, 1-77, 5-34, 8-84, 4-40, 9-46, 6-44))).
jobshop(abz7, "Adams, Balas, and Zawack 15 x 20 instance (Table 1, instance 7)", 20, 15, []([](2-24, 3-12, 9-17, 4-27, 0-21, 6-25, 8-27, 7-26, 1-30, 5-31, 11-18, 14-16, 13-39, 10-19, 12-26), [](6-30, 3-15, 12-20, 11-19, 1-24, 13-15, 10-28, 2-36, 5-26, 7-15, 0-11, 8-23, 14-20, 9-26, 4-28), [](6-35, 0-22, 13-23, 7-32, 2-20, 3-12, 12-19, 10-23, 9-17, 1-14, 5-16, 11-29, 8-16, 4-22, 14-22), [](9-20, 6-29, 1-19, 7-14, 12-33, 4-30, 0-32, 5-21, 11-29, 10-24, 14-25, 2-29, 3-13, 8-20, 13-18), [](11-23, 13-20, 1-28, 6-32, 7-16, 5-18, 8-24, 9-23, 3-24, 10-34, 2-24, 0-24, 14-28, 12-15, 4-18), [](8-24, 11-19, 14-21, 1-33, 7-34, 6-35, 5-40, 10-36, 3-23, 2-26, 4-15, 9-28, 13-38, 12-13, 0-25), [](13-27, 3-30, 6-21, 8-19, 12-12, 4-27, 2-39, 9-13, 14-12, 5-36, 10-21, 11-17, 1-29, 0-17, 7-33), [](5-27, 4-19, 6-29, 9-20, 3-21, 10-40, 8-14, 14-39, 13-39, 2-27, 1-36, 12-12, 11-37, 7-22, 0-13), [](13-32, 11-29, 8-24, 3-27, 5-40, 4-21, 9-26, 0-27, 14-27, 6-16, 2-21, 10-13, 7-28, 12-28, 1-32), [](12-35, 1-11, 5-39, 14-18, 7-23, 0-34, 3-24, 13-11, 8-30, 11-31, 4-15, 10-15, 2-28, 9-26, 6-33), [](10-28, 5-37, 12-29, 1-31, 7-25, 8-13, 14-14, 4-20, 3-27, 9-25, 13-31, 11-14, 6-25, 2-39, 0-36), [](0-22, 11-25, 5-28, 13-35, 4-31, 8-21, 9-20, 14-19, 2-29, 7-32, 10-18, 1-18, 3-11, 12-17, 6-15), [](12-39, 5-32, 2-36, 8-14, 3-28, 13-37, 0-38, 6-20, 7-19, 11-12, 14-22, 1-36, 4-15, 9-32, 10-16), [](8-28, 1-29, 14-40, 12-23, 4-34, 5-33, 6-27, 10-17, 0-20, 7-28, 11-21, 2-21, 13-20, 9-33, 3-27), [](9-21, 14-34, 3-30, 12-38, 0-11, 11-16, 2-14, 5-14, 1-34, 8-33, 4-23, 13-40, 10-12, 6-23, 7-27), [](9-13, 14-40, 7-36, 4-17, 0-13, 5-33, 8-25, 13-24, 10-23, 3-36, 2-29, 1-18, 11-13, 6-33, 12-13), [](3-25, 5-15, 2-28, 12-40, 7-39, 1-31, 8-35, 6-31, 11-36, 4-12, 10-33, 14-19, 9-16, 13-27, 0-21), [](12-22, 10-14, 0-12, 2-20, 5-12, 1-18, 11-17, 8-39, 14-31, 3-31, 7-32, 9-20, 13-29, 4-13, 6-26), [](5-18, 10-30, 7-38, 14-22, 13-15, 11-20, 9-16, 3-17, 1-12, 2-13, 12-40, 6-17, 8-30, 4-38, 0-13), [](9-31, 8-39, 12-27, 1-14, 5-33, 3-31, 11-22, 13-36, 0-16, 7-11, 14-14, 4-29, 6-28, 2-22, 10-17))).
jobshop(abz8, "Adams, Balas, and Zawack 15 x 20 instance (Table 1, instance 8)", 20, 15, []([](0-19, 9-33, 2-32, 13-18, 10-39, 8-34, 6-25, 4-36, 11-40, 12-33, 1-31, 14-30, 3-34, 5-26, 7-13), [](9-11, 10-22, 14-19, 5-12, 4-25, 6-38, 0-29, 7-39, 13-19, 11-22, 1-23, 3-20, 2-40, 12-19, 8-26), [](3-25, 8-17, 11-24, 13-40, 10-32, 14-16, 5-39, 9-19, 0-24, 1-39, 4-17, 2-35, 7-38, 6-20, 12-31), [](14-22, 3-36, 2-34, 12-17, 4-30, 13-12, 1-13, 6-25, 9-12, 7-18, 10-31, 0-39, 5-40, 8-26, 11-37), [](12-32, 14-15, 1-35, 7-13, 8-32, 11-23, 6-22, 4-21, 0-38, 2-38, 3-40, 10-31, 5-11, 13-37, 9-16), [](10-23, 12-38, 8-11, 14-27, 9-11, 6-25, 5-14, 4-12, 2-27, 11-26, 7-29, 3-28, 13-21, 0-20, 1-30), [](6-39, 8-38, 0-15, 12-27, 10-22, 9-27, 2-32, 4-40, 3-12, 13-20, 14-21, 11-22, 5-17, 7-38, 1-27), [](11-11, 13-24, 10-38, 8-15, 9-19, 14-13, 5-30, 0-26, 2-29, 6-33, 12-21, 1-15, 3-21, 4-28, 7-33), [](8-20, 6-17, 5-26, 3-34, 9-23, 0-16, 2-18, 4-35, 12-24, 10-16, 11-26, 7-12, 14-13, 13-27, 1-19), [](1-18, 7-37, 14-27, 9-40, 5-40, 6-17, 8-22, 3-17, 10-30, 0-38, 4-21, 12-32, 11-24, 13-24, 2-30), [](11-19, 0-22, 13-36, 6-18, 5-22, 3-17, 14-35, 10-34, 7-23, 8-19, 2-29, 1-22, 12-17, 4-33, 9-39), [](6-32, 3-22, 12-24, 5-13, 4-13, 1-11, 0-11, 13-25, 8-13, 2-15, 10-33, 11-17, 14-16, 9-38, 7-24), [](14-16, 13-16, 1-37, 8-25, 2-26, 3-11, 9-34, 4-14, 0-20, 6-36, 12-12, 5-29, 10-25, 7-32, 11-12), [](8-20, 10-24, 11-27, 9-38, 5-34, 12-39, 7-33, 4-37, 2-31, 13-15, 14-34, 3-33, 6-26, 1-36, 0-14), [](8-31, 0-17, 9-13, 1-21, 10-17, 7-19, 13-14, 3-40, 5-32, 11-25, 2-34, 14-23, 6-13, 12-40, 4-26), [](8-38, 12-17, 3-14, 13-17, 4-12, 1-35, 6-35, 0-19, 10-36, 7-19, 9-29, 2-31, 5-26, 11-35, 14-37), [](14-20, 3-16, 0-33, 10-14, 5-27, 7-31, 8-16, 6-31, 12-28, 9-37, 4-37, 2-29, 11-38, 1-30, 13-36), [](11-18, 3-37, 14-16, 6-15, 8-14, 12-11, 13-32, 5-12, 1-11, 10-29, 7-19, 4-12, 9-18, 2-26, 0-39), [](11-11, 2-11, 12-22, 9-35, 14-20, 7-31, 4-19, 3-39, 5-28, 6-33, 10-34, 1-38, 0-20, 13-17, 8-28), [](2-12, 12-25, 5-23, 8-21, 6-27, 9-30, 14-23, 11-39, 3-26, 13-34, 7-17, 1-24, 4-12, 0-19, 10-36))).
jobshop(abz9, "Adams, Balas, and Zawack 15 x 20 instance (Table 1, instance 9)", 20, 15, []([](6-14, 5-21, 8-13, 4-11, 1-11, 14-35, 13-20, 11-17, 10-18, 12-11, 2-23, 3-13, 0-15, 7-11, 9-35), [](1-35, 5-31, 0-13, 3-26, 6-14, 9-17, 7-38, 12-20, 10-19, 13-12, 8-16, 4-34, 11-15, 14-12, 2-14), [](0-30, 4-35, 2-40, 10-35, 6-30, 14-23, 8-29, 13-37, 7-38, 3-40, 9-26, 12-11, 1-40, 11-36, 5-17), [](7-40, 5-18, 4-12, 8-23, 0-23, 9-14, 13-16, 12-14, 10-23, 3-12, 6-16, 14-32, 1-40, 11-25, 2-29), [](2-35, 3-15, 12-31, 11-28, 6-32, 4-30, 10-27, 7-29, 0-38, 13-11, 1-23, 14-17, 5-27, 9-37, 8-29), [](5-33, 3-33, 6-19, 12-40, 10-19, 0-33, 13-26, 2-31, 11-28, 7-36, 4-38, 1-21, 14-25, 9-40, 8-35), [](13-25, 0-32, 11-33, 12-18, 4-32, 6-28, 5-15, 3-35, 9-14, 2-34, 7-23, 10-32, 1-17, 14-26, 8-19), [](2-16, 12-33, 9-34, 11-30, 13-40, 8-12, 14-26, 5-26, 6-15, 3-21, 1-40, 4-32, 0-14, 7-30, 10-35), [](2-17, 10-16, 14-20, 6-24, 8-26, 3-36, 12-22, 0-14, 13-11, 9-20, 7-23, 1-29, 11-23, 4-15, 5-40), [](4-27, 9-37, 3-40, 11-14, 13-25, 7-30, 0-34, 2-11, 5-15, 12-32, 1-36, 10-12, 14-28, 8-31, 6-23), [](13-25, 0-22, 3-27, 8-14, 5-25, 6-20, 14-18, 7-14, 1-19, 2-17, 4-27, 9-22, 12-22, 11-27, 10-21), [](14-34, 10-15, 0-22, 3-29, 13-34, 6-40, 7-17, 2-32, 12-20, 5-39, 4-31, 11-16, 1-37, 8-33, 9-13), [](6-12, 12-27, 4-17, 2-24, 8-11, 5-19, 14-11, 3-17, 9-25, 1-11, 11-31, 13-33, 7-31, 10-12, 0-22), [](5-22, 14-15, 0-16, 8-32, 7-20, 4-22, 9-11, 13-19, 1-30, 12-33, 6-29, 11-18, 3-34, 10-32, 2-18), [](5-27, 3-26, 10-28, 6-37, 4-18, 12-12, 11-11, 13-26, 7-27, 9-40, 14-19, 1-24, 2-18, 0-12, 8-34), [](8-15, 5-28, 9-25, 6-32, 1-13, 7-38, 11-11, 2-34, 4-25, 0-20, 10-32, 3-23, 12-14, 14-16, 13-20), [](1-15, 4-13, 8-37, 3-14, 10-22, 5-24, 12-26, 7-22, 9-34, 14-22, 11-19, 13-32, 0-29, 2-13, 6-35), [](7-36, 5-33, 13-28, 9-20, 10-30, 4-33, 14-29, 0-34, 3-22, 11-12, 6-30, 8-12, 1-35, 2-13, 12-35), [](14-26, 11-31, 5-35, 2-38, 13-19, 10-35, 4-27, 8-29, 3-39, 9-13, 6-14, 7-26, 0-17, 1-22, 12-15), [](1-36, 7-34, 11-33, 8-17, 14-38, 6-39, 5-16, 3-27, 13-29, 2-16, 0-16, 4-19, 9-40, 12-35, 10-39))).
jobshop(ft06, "Fisher and Thompson 6x6 instance, alternate name (mt06)", 6, 6, []([](2-1, 0-3, 1-6, 3-7, 5-3, 4-6), [](1-8, 2-5, 4-10, 5-10, 0-10, 3-4), [](2-5, 3-4, 5-8, 0-9, 1-1, 4-7), [](1-5, 0-5, 2-5, 3-3, 4-8, 5-9), [](2-9, 1-3, 4-5, 5-4, 0-3, 3-1), [](1-3, 3-3, 5-9, 0-10, 4-4, 2-1))).
jobshop(ft10, "Fisher and Thompson 10x10 instance, alternate name (mt10)", 10, 10, []([](0-29, 1-78, 2-9, 3-36, 4-49, 5-11, 6-62, 7-56, 8-44, 9-21), [](0-43, 2-90, 4-75, 9-11, 3-69, 1-28, 6-46, 5-46, 7-72, 8-30), [](1-91, 0-85, 3-39, 2-74, 8-90, 5-10, 7-12, 6-89, 9-45, 4-33), [](1-81, 2-95, 0-71, 4-99, 6-9, 8-52, 7-85, 3-98, 9-22, 5-43), [](2-14, 0-6, 1-22, 5-61, 3-26, 4-69, 8-21, 7-49, 9-72, 6-53), [](2-84, 1-2, 5-52, 3-95, 8-48, 9-72, 0-47, 6-65, 4-6, 7-25), [](1-46, 0-37, 3-61, 2-13, 6-32, 5-21, 9-32, 8-89, 7-30, 4-55), [](2-31, 0-86, 1-46, 5-74, 4-32, 6-88, 8-19, 9-48, 7-36, 3-79), [](0-76, 1-69, 3-76, 5-51, 2-85, 9-11, 6-40, 7-89, 4-26, 8-74), [](1-85, 0-13, 2-61, 6-7, 8-64, 9-76, 5-47, 3-52, 4-90, 7-45))).
jobshop(ft20, "Fisher and Thompson 20x5 instance, alternate name (mt20)", 20, 5, []([](0-29, 1-9, 2-49, 3-62, 4-44), [](0-43, 1-75, 3-69, 2-46, 4-72), [](1-91, 0-39, 2-90, 4-12, 3-45), [](1-81, 0-71, 4-9, 2-85, 3-22), [](2-14, 1-22, 0-26, 3-21, 4-72), [](2-84, 1-52, 4-48, 0-47, 3-6), [](1-46, 0-61, 2-32, 3-32, 4-30), [](2-31, 1-46, 0-32, 3-19, 4-36), [](0-76, 3-76, 2-85, 1-40, 4-26), [](1-85, 2-61, 0-64, 3-47, 4-90), [](1-78, 3-36, 0-11, 4-56, 2-21), [](2-90, 0-11, 1-28, 3-46, 4-30), [](0-85, 2-74, 1-10, 3-89, 4-33), [](2-95, 0-99, 1-52, 3-98, 4-43), [](0-6, 1-61, 4-69, 2-49, 3-53), [](1-2, 0-95, 3-72, 4-65, 2-25), [](0-37, 2-13, 1-21, 3-89, 4-55), [](0-86, 1-74, 4-88, 2-48, 3-79), [](1-69, 2-51, 0-11, 3-89, 4-74), [](0-13, 1-7, 2-76, 3-52, 4-45))).
jobshop(la01, "Lawrence 10x5 instance (Table 3, instance 1); also called (setf1) or (F1)", 10, 5, []([](1-21, 0-53, 4-95, 3-55, 2-34), [](0-21, 3-52, 4-16, 2-26, 1-71), [](3-39, 4-98, 1-42, 2-31, 0-12), [](1-77, 0-55, 4-79, 2-66, 3-77), [](0-83, 3-34, 2-64, 1-19, 4-37), [](1-54, 2-43, 4-79, 0-92, 3-62), [](3-69, 4-77, 1-87, 2-87, 0-93), [](2-38, 0-60, 1-41, 3-24, 4-83), [](3-17, 1-49, 4-25, 0-44, 2-98), [](4-77, 3-79, 2-43, 1-75, 0-96))).
jobshop(la02, "Lawrence 10x5 instance (Table 3, instance 2); also called (setf2) or (F2)", 10, 5, []([](0-20, 3-87, 1-31, 4-76, 2-17), [](4-25, 2-32, 0-24, 1-18, 3-81), [](1-72, 2-23, 4-28, 0-58, 3-99), [](2-86, 1-76, 4-97, 0-45, 3-90), [](4-27, 0-42, 3-48, 2-17, 1-46), [](1-67, 0-98, 4-48, 3-27, 2-62), [](4-28, 1-12, 3-19, 0-80, 2-50), [](1-63, 0-94, 2-98, 3-50, 4-80), [](4-14, 0-75, 2-50, 1-41, 3-55), [](4-72, 2-18, 1-37, 3-79, 0-61))).
jobshop(la03, "Lawrence 10x5 instance (Table 3, instance 3); also called (setf3) or (F3)", 10, 5, []([](1-23, 2-45, 0-82, 4-84, 3-38), [](2-21, 1-29, 0-18, 4-41, 3-50), [](2-38, 3-54, 4-16, 0-52, 1-52), [](4-37, 0-54, 2-74, 1-62, 3-57), [](4-57, 0-81, 1-61, 3-68, 2-30), [](4-81, 0-79, 1-89, 2-89, 3-11), [](3-33, 2-20, 0-91, 4-20, 1-66), [](4-24, 1-84, 0-32, 2-55, 3-8), [](4-56, 0-7, 3-54, 2-64, 1-39), [](4-40, 1-83, 0-19, 2-8, 3-7))).
jobshop(la04, "Lawrence 10x5 instance (Table 3, instance 4); also called (setf4) or (F4)", 10, 5, []([](0-12, 2-94, 3-92, 4-91, 1-7), [](1-19, 3-11, 4-66, 2-21, 0-87), [](1-14, 0-75, 3-13, 4-16, 2-20), [](2-95, 4-66, 0-7, 3-7, 1-77), [](1-45, 3-6, 4-89, 0-15, 2-34), [](3-77, 2-20, 0-76, 4-88, 1-53), [](2-74, 1-88, 0-52, 3-27, 4-9), [](1-88, 3-69, 0-62, 4-98, 2-52), [](2-61, 4-9, 0-62, 1-52, 3-90), [](2-54, 4-5, 3-59, 1-15, 0-88))).
jobshop(la05, "Lawrence 10x5 instance (Table 3, instance 5); also called (setf5) or (F5)", 10, 5, []([](1-72, 0-87, 4-95, 2-66, 3-60), [](4-5, 3-35, 0-48, 2-39, 1-54), [](1-46, 3-20, 2-21, 0-97, 4-55), [](0-59, 3-19, 4-46, 1-34, 2-37), [](4-23, 2-73, 3-25, 1-24, 0-28), [](3-28, 0-45, 4-5, 1-78, 2-83), [](0-53, 3-71, 1-37, 4-29, 2-12), [](4-12, 2-87, 3-33, 1-55, 0-38), [](2-49, 3-83, 1-40, 0-48, 4-7), [](2-65, 3-17, 0-90, 4-27, 1-23))).
jobshop(la06, "Lawrence 15x5 instance (Table 4, instance 1); also called (setg1) or (G1)", 15, 5, []([](1-21, 2-34, 4-95, 0-53, 3-55), [](3-52, 4-16, 1-71, 2-26, 0-21), [](2-31, 0-12, 1-42, 3-39, 4-98), [](3-77, 1-77, 4-79, 0-55, 2-66), [](4-37, 3-34, 2-64, 1-19, 0-83), [](2-43, 1-54, 0-92, 3-62, 4-79), [](0-93, 3-69, 1-87, 4-77, 2-87), [](0-60, 1-41, 2-38, 4-83, 3-24), [](2-98, 3-17, 4-25, 0-44, 1-49), [](0-96, 4-77, 3-79, 1-75, 2-43), [](4-28, 2-35, 0-95, 3-76, 1-7), [](0-61, 4-10, 2-95, 1-9, 3-35), [](4-59, 3-16, 1-91, 2-59, 0-46), [](4-43, 1-52, 0-28, 2-27, 3-50), [](0-87, 1-45, 2-39, 4-9, 3-41))).
jobshop(la07, "Lawrence 15x5 instance (Table 4, instance 2); also called (setg2) or (G2)", 15, 5, []([](0-47, 4-57, 1-71, 3-96, 2-14), [](0-75, 1-60, 4-22, 3-79, 2-65), [](3-32, 0-33, 2-69, 1-31, 4-58), [](0-44, 1-34, 4-51, 3-58, 2-47), [](3-29, 1-44, 0-62, 2-17, 4-8), [](1-15, 2-40, 0-97, 4-38, 3-66), [](2-58, 1-39, 0-57, 4-20, 3-50), [](2-57, 3-32, 4-87, 0-63, 1-21), [](4-56, 0-84, 2-90, 1-85, 3-61), [](4-15, 0-20, 1-67, 3-30, 2-70), [](4-84, 0-82, 1-23, 2-45, 3-38), [](3-50, 2-21, 0-18, 4-41, 1-29), [](4-16, 1-52, 0-52, 2-38, 3-54), [](4-37, 0-54, 3-57, 2-74, 1-62), [](4-57, 1-61, 0-81, 2-30, 3-68))).
jobshop(la08, "Lawrence 15x5 instance (Table 4, instance 3); also called (setg3) or (G3)", 15, 5, []([](3-92, 2-94, 0-12, 4-91, 1-7), [](2-21, 1-19, 0-87, 3-11, 4-66), [](1-14, 3-13, 0-75, 4-16, 2-20), [](2-95, 4-66, 0-7, 1-77, 3-7), [](2-34, 4-89, 3-6, 1-45, 0-15), [](4-88, 3-77, 2-20, 1-53, 0-76), [](4-9, 3-27, 0-52, 1-88, 2-74), [](3-69, 2-52, 0-62, 1-88, 4-98), [](3-90, 0-62, 4-9, 2-61, 1-52), [](4-5, 2-54, 3-59, 0-88, 1-15), [](0-41, 1-50, 4-78, 3-53, 2-23), [](0-38, 4-72, 2-91, 3-68, 1-71), [](0-45, 3-95, 4-52, 2-25, 1-6), [](3-30, 1-66, 0-23, 4-36, 2-17), [](2-95, 0-71, 3-76, 1-8, 4-88))).
jobshop(la09, "Lawrence 15x5 instance (Table 4, instance 4); also called (setg4) or (G4)", 15, 5, []([](1-66, 3-85, 2-84, 0-62, 4-19), [](3-59, 1-64, 2-46, 4-13, 0-25), [](4-88, 3-80, 1-73, 2-53, 0-41), [](0-14, 1-67, 2-57, 3-74, 4-47), [](0-84, 4-64, 2-41, 3-84, 1-78), [](0-63, 3-28, 1-46, 2-26, 4-52), [](3-10, 2-17, 4-73, 1-11, 0-64), [](2-67, 1-97, 3-95, 4-38, 0-85), [](2-95, 4-46, 0-59, 1-65, 3-93), [](2-43, 4-85, 3-32, 1-85, 0-60), [](4-49, 3-41, 2-61, 0-66, 1-90), [](1-17, 0-23, 3-70, 4-99, 2-49), [](4-40, 3-73, 0-73, 1-98, 2-68), [](3-57, 1-9, 2-7, 0-13, 4-98), [](0-37, 1-85, 2-17, 4-79, 3-41))).
jobshop(la10, "Lawrence 15x5 instance (Table 4, instance 5); also called (setg5) or (G5)", 15, 5, []([](1-58, 2-44, 3-5, 0-9, 4-58), [](1-89, 0-97, 4-96, 3-77, 2-84), [](0-77, 1-87, 2-81, 4-39, 3-85), [](3-57, 1-21, 2-31, 0-15, 4-73), [](2-48, 0-40, 1-49, 3-70, 4-71), [](3-34, 4-82, 2-80, 0-10, 1-22), [](1-91, 4-75, 0-55, 2-17, 3-7), [](2-62, 3-47, 1-72, 4-35, 0-11), [](0-64, 3-75, 4-50, 1-90, 2-94), [](2-67, 4-20, 3-15, 0-12, 1-71), [](0-52, 4-93, 3-68, 2-29, 1-57), [](2-70, 0-58, 1-93, 4-7, 3-77), [](3-27, 2-82, 1-63, 4-6, 0-95), [](1-87, 2-56, 4-36, 0-26, 3-48), [](3-76, 2-36, 0-36, 4-15, 1-8))).
jobshop(la11, "Lawrence 20x5 instance (Table 5, instance 1); also called (seth1) or H1", 20, 5, []([](2-34, 1-21, 0-53, 3-55, 4-95), [](0-21, 3-52, 1-71, 4-16, 2-26), [](0-12, 1-42, 2-31, 4-98, 3-39), [](2-66, 3-77, 4-79, 0-55, 1-77), [](0-83, 4-37, 3-34, 1-19, 2-64), [](4-79, 2-43, 0-92, 3-62, 1-54), [](0-93, 4-77, 2-87, 1-87, 3-69), [](4-83, 3-24, 1-41, 2-38, 0-60), [](4-25, 1-49, 0-44, 2-98, 3-17), [](0-96, 1-75, 2-43, 4-77, 3-79), [](0-95, 3-76, 1-7, 4-28, 2-35), [](4-10, 2-95, 0-61, 1-9, 3-35), [](1-91, 2-59, 4-59, 0-46, 3-16), [](2-27, 1-52, 4-43, 0-28, 3-50), [](4-9, 0-87, 3-41, 2-39, 1-45), [](1-54, 0-20, 4-43, 3-14, 2-71), [](4-33, 1-28, 3-26, 0-78, 2-37), [](1-89, 0-33, 2-8, 3-66, 4-42), [](4-84, 0-69, 2-94, 1-74, 3-27), [](4-81, 2-45, 1-78, 3-69, 0-96))).
jobshop(la12, "Lawrence 20x5 instance (Table 5, instance 2); also called (seth2) or H2", 20, 5, []([](1-23, 0-82, 4-84, 2-45, 3-38), [](3-50, 4-41, 1-29, 0-18, 2-21), [](4-16, 3-54, 1-52, 2-38, 0-52), [](1-62, 3-57, 4-37, 2-74, 0-54), [](3-68, 1-61, 2-30, 0-81, 4-57), [](1-89, 2-89, 3-11, 0-79, 4-81), [](1-66, 0-91, 3-33, 4-20, 2-20), [](3-8, 4-24, 2-55, 0-32, 1-84), [](0-7, 2-64, 1-39, 4-56, 3-54), [](0-19, 4-40, 3-7, 2-8, 1-83), [](0-63, 2-64, 3-91, 4-40, 1-6), [](1-42, 3-61, 4-15, 2-98, 0-74), [](1-80, 0-26, 3-75, 4-6, 2-87), [](2-39, 4-22, 0-75, 3-24, 1-44), [](1-15, 3-79, 4-8, 0-12, 2-20), [](3-26, 2-43, 0-80, 4-22, 1-61), [](2-62, 1-36, 0-63, 3-96, 4-40), [](1-33, 3-18, 0-22, 4-5, 2-10), [](2-64, 4-64, 0-89, 1-96, 3-95), [](2-18, 4-23, 3-15, 1-38, 0-8))).
jobshop(la13, "Lawrence 20x5 instance (Table 5, instance 3); also called (seth3) or (H3)", 20, 5, []([](3-60, 0-87, 1-72, 4-95, 2-66), [](1-54, 0-48, 2-39, 3-35, 4-5), [](3-20, 1-46, 0-97, 2-21, 4-55), [](2-37, 0-59, 3-19, 1-34, 4-46), [](2-73, 3-25, 1-24, 0-28, 4-23), [](1-78, 3-28, 2-83, 0-45, 4-5), [](3-71, 1-37, 2-12, 4-29, 0-53), [](4-12, 3-33, 1-55, 2-87, 0-38), [](0-48, 1-40, 2-49, 3-83, 4-7), [](0-90, 4-27, 2-65, 3-17, 1-23), [](0-62, 3-85, 1-66, 2-84, 4-19), [](3-59, 2-46, 4-13, 1-64, 0-25), [](2-53, 1-73, 3-80, 4-88, 0-41), [](2-57, 4-47, 0-14, 1-67, 3-74), [](2-41, 4-64, 3-84, 1-78, 0-84), [](4-52, 3-28, 2-26, 0-63, 1-46), [](1-11, 0-64, 3-10, 4-73, 2-17), [](4-38, 3-95, 0-85, 1-97, 2-67), [](3-93, 1-65, 2-95, 0-59, 4-46), [](0-60, 1-85, 2-43, 4-85, 3-32))).
jobshop(la14, "Lawrence 20x5 instance (Table 5, instance 4); also called (seth4) or (H4)", 20, 5, []([](3-5, 4-58, 2-44, 0-9, 1-58), [](1-89, 4-96, 0-97, 2-84, 3-77), [](2-81, 3-85, 1-87, 4-39, 0-77), [](0-15, 3-57, 4-73, 1-21, 2-31), [](2-48, 4-71, 3-70, 0-40, 1-49), [](0-10, 4-82, 3-34, 2-80, 1-22), [](2-17, 0-55, 1-91, 4-75, 3-7), [](3-47, 2-62, 1-72, 4-35, 0-11), [](1-90, 2-94, 4-50, 0-64, 3-75), [](3-15, 2-67, 0-12, 4-20, 1-71), [](4-93, 2-29, 0-52, 1-57, 3-68), [](3-77, 1-93, 0-58, 2-70, 4-7), [](1-63, 3-27, 0-95, 4-6, 2-82), [](4-36, 0-26, 3-48, 2-56, 1-87), [](2-36, 1-8, 4-15, 3-76, 0-36), [](4-78, 1-84, 3-41, 0-30, 2-76), [](1-78, 0-75, 4-88, 3-13, 2-81), [](0-54, 4-40, 2-13, 1-82, 3-29), [](1-26, 4-82, 0-52, 3-6, 2-6), [](3-54, 1-64, 0-54, 2-32, 4-88))).
jobshop(la15, "Lawrence 20x5 instance (Table 5, instance 5); also called (seth5) or (H5)", 20, 5, []([](0-6, 2-40, 1-81, 3-37, 4-19), [](2-40, 3-32, 0-55, 4-81, 1-9), [](1-46, 4-65, 2-70, 3-55, 0-77), [](2-21, 4-65, 0-64, 3-25, 1-15), [](2-85, 0-40, 1-44, 3-24, 4-37), [](0-89, 4-29, 1-83, 3-31, 2-84), [](4-59, 3-38, 1-80, 2-30, 0-8), [](0-80, 2-56, 1-77, 4-41, 3-97), [](4-56, 0-91, 3-50, 2-71, 1-17), [](1-40, 0-88, 4-59, 2-7, 3-80), [](0-45, 1-29, 2-8, 4-77, 3-58), [](2-36, 0-54, 3-96, 1-9, 4-10), [](0-28, 2-73, 1-98, 3-92, 4-87), [](0-70, 3-86, 2-27, 1-99, 4-96), [](1-95, 0-59, 4-56, 3-85, 2-41), [](1-81, 2-92, 4-32, 0-52, 3-39), [](1-7, 4-22, 2-12, 0-88, 3-60), [](3-45, 0-93, 2-69, 4-49, 1-27), [](0-21, 1-84, 2-61, 3-68, 4-26), [](1-82, 2-33, 4-71, 0-99, 3-44))).
jobshop(la16, "Lawrence 10x10 instance (Table 6, instance 1); also called (seta1) or (A1)", 10, 10, []([](1-21, 6-71, 9-16, 8-52, 7-26, 2-34, 0-53, 4-21, 3-55, 5-95), [](4-55, 2-31, 5-98, 9-79, 0-12, 7-66, 1-42, 8-77, 6-77, 3-39), [](3-34, 2-64, 8-62, 1-19, 4-92, 9-79, 7-43, 6-54, 0-83, 5-37), [](1-87, 3-69, 2-87, 7-38, 8-24, 9-83, 6-41, 0-93, 5-77, 4-60), [](2-98, 0-44, 5-25, 6-75, 7-43, 1-49, 4-96, 9-77, 3-17, 8-79), [](2-35, 3-76, 5-28, 9-10, 4-61, 6-9, 0-95, 8-35, 1-7, 7-95), [](3-16, 2-59, 0-46, 1-91, 9-43, 8-50, 6-52, 5-59, 4-28, 7-27), [](1-45, 0-87, 3-41, 4-20, 6-54, 9-43, 8-14, 5-9, 2-39, 7-71), [](4-33, 2-37, 8-66, 5-33, 3-26, 7-8, 1-28, 6-89, 9-42, 0-78), [](8-69, 9-81, 2-94, 4-96, 3-27, 0-69, 7-45, 6-78, 1-74, 5-84))).
jobshop(la17, "Lawrence 10x10 instance (Table 6, instance 2); also called (seta2) or (A2)", 10, 10, []([](4-18, 7-21, 9-41, 2-45, 3-38, 8-50, 5-84, 6-29, 1-23, 0-82), [](8-57, 5-16, 1-52, 7-74, 2-38, 3-54, 6-62, 9-37, 4-54, 0-52), [](2-30, 4-79, 3-68, 1-61, 8-11, 6-89, 7-89, 0-81, 9-81, 5-57), [](0-91, 8-8, 3-33, 7-55, 5-20, 2-20, 4-32, 6-84, 1-66, 9-24), [](9-40, 0-7, 4-19, 8-7, 6-83, 2-64, 5-56, 3-54, 7-8, 1-39), [](3-91, 2-64, 5-40, 0-63, 7-98, 4-74, 8-61, 1-6, 6-42, 9-15), [](1-80, 7-39, 8-24, 3-75, 4-75, 5-6, 6-44, 0-26, 2-87, 9-22), [](1-15, 7-43, 2-20, 0-12, 8-26, 6-61, 3-79, 9-22, 5-8, 4-80), [](2-62, 3-96, 4-22, 9-5, 0-63, 6-33, 7-10, 8-18, 1-36, 5-40), [](1-96, 0-89, 5-64, 3-95, 9-23, 7-18, 8-15, 2-64, 6-38, 4-8))).
jobshop(la18, "Lawrence 10x10 instance (Table 6, instance 3); also called (seta3) or (A3)", 10, 10, []([](6-54, 0-87, 4-48, 3-60, 7-39, 8-35, 1-72, 5-95, 2-66, 9-5), [](3-20, 9-46, 6-34, 5-55, 0-97, 8-19, 4-59, 2-21, 7-37, 1-46), [](4-45, 1-24, 8-28, 0-28, 7-83, 6-78, 5-23, 3-25, 9-5, 2-73), [](9-12, 1-37, 4-38, 3-71, 8-33, 2-12, 6-55, 0-53, 7-87, 5-29), [](3-83, 2-49, 6-23, 9-27, 7-65, 0-48, 4-90, 5-7, 1-40, 8-17), [](1-66, 4-25, 0-62, 2-84, 9-13, 6-64, 7-46, 8-59, 5-19, 3-85), [](1-73, 3-80, 0-41, 2-53, 9-47, 7-57, 8-74, 4-14, 6-67, 5-88), [](5-64, 3-84, 6-46, 1-78, 0-84, 7-26, 8-28, 9-52, 2-41, 4-63), [](1-11, 0-64, 7-67, 4-85, 3-10, 5-73, 9-38, 8-95, 6-97, 2-17), [](4-60, 8-32, 2-95, 3-93, 1-65, 6-85, 7-43, 9-85, 5-46, 0-59))).
jobshop(la19, "Lawrence 10x10 instance (Table 6, instance 4); also called (seta4) or (A4)", 10, 10, []([](2-44, 3-5, 5-58, 4-97, 0-9, 7-84, 8-77, 9-96, 1-58, 6-89), [](4-15, 7-31, 1-87, 8-57, 0-77, 3-85, 2-81, 5-39, 9-73, 6-21), [](9-82, 6-22, 4-10, 3-70, 1-49, 0-40, 8-34, 2-48, 7-80, 5-71), [](1-91, 2-17, 7-62, 5-75, 8-47, 4-11, 3-7, 6-72, 9-35, 0-55), [](6-71, 1-90, 3-75, 0-64, 2-94, 8-15, 4-12, 7-67, 9-20, 5-50), [](7-70, 5-93, 8-77, 2-29, 4-58, 6-93, 3-68, 1-57, 9-7, 0-52), [](6-87, 1-63, 4-26, 5-6, 2-82, 3-27, 7-56, 8-48, 9-36, 0-95), [](0-36, 5-15, 8-41, 9-78, 3-76, 6-84, 4-30, 7-76, 2-36, 1-8), [](5-88, 2-81, 3-13, 6-82, 4-54, 7-13, 8-29, 9-40, 1-78, 0-75), [](9-88, 4-54, 6-64, 7-32, 0-52, 2-6, 8-54, 5-82, 3-6, 1-26))).
jobshop(la20, "Lawrence 10x10 instance (Table 6, instance 5); also called (seta5) or (A5)", 10, 10, []([](6-9, 1-81, 4-55, 2-40, 8-32, 3-37, 0-6, 5-19, 9-81, 7-40), [](7-21, 2-70, 9-65, 4-64, 1-46, 5-65, 8-25, 0-77, 3-55, 6-15), [](2-85, 5-37, 0-40, 3-24, 1-44, 6-83, 4-89, 8-31, 7-84, 9-29), [](4-80, 6-77, 7-56, 0-8, 2-30, 5-59, 3-38, 1-80, 9-41, 8-97), [](0-91, 6-40, 4-88, 1-17, 2-71, 3-50, 9-59, 8-80, 5-56, 7-7), [](2-8, 6-9, 3-58, 5-77, 1-29, 8-96, 0-45, 9-10, 4-54, 7-36), [](4-70, 3-92, 1-98, 5-87, 6-99, 7-27, 8-86, 9-96, 0-28, 2-73), [](1-95, 7-92, 3-85, 4-52, 6-81, 9-32, 8-39, 0-59, 2-41, 5-56), [](3-60, 8-45, 0-88, 2-12, 1-7, 5-22, 4-93, 9-49, 7-69, 6-27), [](0-21, 2-61, 3-68, 5-26, 6-82, 9-71, 8-44, 4-99, 7-33, 1-84))).
jobshop(la21, "Lawrence 15x10 instance (Table 7, instance 1); also called (setb1) or (B1)", 15, 10, []([](2-34, 3-55, 5-95, 9-16, 4-21, 6-71, 0-53, 8-52, 1-21, 7-26), [](3-39, 2-31, 0-12, 1-42, 9-79, 8-77, 6-77, 5-98, 4-55, 7-66), [](1-19, 0-83, 3-34, 4-92, 6-54, 9-79, 8-62, 5-37, 2-64, 7-43), [](4-60, 2-87, 8-24, 5-77, 3-69, 7-38, 1-87, 6-41, 9-83, 0-93), [](8-79, 9-77, 2-98, 4-96, 3-17, 0-44, 7-43, 6-75, 1-49, 5-25), [](8-35, 7-95, 6-9, 9-10, 2-35, 1-7, 5-28, 4-61, 0-95, 3-76), [](4-28, 5-59, 3-16, 9-43, 0-46, 8-50, 6-52, 7-27, 2-59, 1-91), [](5-9, 4-20, 2-39, 6-54, 1-45, 7-71, 0-87, 3-41, 9-43, 8-14), [](1-28, 5-33, 0-78, 3-26, 2-37, 7-8, 8-66, 6-89, 9-42, 4-33), [](2-94, 5-84, 6-78, 9-81, 1-74, 3-27, 8-69, 0-69, 7-45, 4-96), [](1-31, 4-24, 0-20, 2-17, 9-25, 8-81, 5-76, 3-87, 7-32, 6-18), [](5-28, 9-97, 0-58, 4-45, 6-76, 3-99, 2-23, 1-72, 8-90, 7-86), [](5-27, 9-48, 8-27, 7-62, 4-98, 6-67, 3-48, 0-42, 1-46, 2-17), [](1-12, 8-50, 0-80, 2-50, 9-80, 3-19, 5-28, 6-63, 4-94, 7-98), [](4-61, 3-55, 6-37, 5-14, 2-50, 8-79, 1-41, 9-72, 7-18, 0-75))).
jobshop(la22, "Lawrence 15x10 instance (Table 7, instance 2); also called (setb2) or (B2)", 15, 10, []([](9-66, 5-91, 4-87, 2-94, 7-21, 3-92, 1-7, 0-12, 8-11, 6-19), [](3-13, 2-20, 4-7, 1-14, 9-66, 0-75, 6-77, 5-16, 7-95, 8-7), [](8-77, 7-20, 2-34, 0-15, 9-88, 5-89, 6-53, 3-6, 1-45, 4-76), [](3-27, 2-74, 6-88, 4-62, 7-52, 8-69, 5-9, 9-98, 0-52, 1-88), [](4-88, 6-15, 1-52, 2-61, 7-54, 0-62, 8-59, 5-9, 3-90, 9-5), [](6-71, 0-41, 4-38, 3-53, 7-91, 8-68, 1-50, 5-78, 2-23, 9-72), [](3-95, 9-36, 6-66, 5-52, 0-45, 8-30, 4-23, 2-25, 7-17, 1-6), [](4-65, 1-8, 8-85, 0-71, 7-65, 6-28, 5-88, 3-76, 9-27, 2-95), [](9-37, 1-37, 4-28, 3-51, 8-86, 2-9, 6-55, 0-73, 7-51, 5-90), [](3-39, 2-15, 6-83, 9-44, 7-53, 0-16, 4-46, 5-24, 1-25, 8-82), [](1-72, 4-48, 0-87, 2-66, 9-5, 6-54, 7-39, 8-35, 5-95, 3-60), [](1-46, 3-20, 0-97, 2-21, 9-46, 7-37, 8-19, 4-59, 6-34, 5-55), [](5-23, 3-25, 6-78, 1-24, 0-28, 7-83, 8-28, 9-5, 2-73, 4-45), [](1-37, 0-53, 7-87, 4-38, 3-71, 5-29, 9-12, 8-33, 6-55, 2-12), [](4-90, 8-17, 2-49, 3-83, 1-40, 6-23, 7-65, 9-27, 5-7, 0-48))).
jobshop(la23, "Lawrence 15x10 instance (Table 7, instance 3); also called (setb3) or (B3)", 15, 10, []([](7-84, 5-58, 8-77, 2-44, 4-97, 6-89, 3-5, 1-58, 9-96, 0-9), [](6-21, 1-87, 4-15, 5-39, 2-81, 3-85, 7-31, 8-57, 9-73, 0-77), [](0-40, 5-71, 8-34, 9-82, 3-70, 6-22, 4-10, 7-80, 2-48, 1-49), [](5-75, 2-17, 3-7, 6-72, 4-11, 7-62, 8-47, 9-35, 1-91, 0-55), [](9-20, 4-12, 6-71, 7-67, 0-64, 2-94, 8-15, 5-50, 3-75, 1-90), [](6-93, 5-93, 1-57, 7-70, 8-77, 4-58, 0-52, 2-29, 9-7, 3-68), [](7-56, 0-95, 8-48, 4-26, 2-82, 1-63, 9-36, 3-27, 6-87, 5-6), [](3-76, 5-15, 9-78, 1-8, 8-41, 2-36, 4-30, 6-84, 0-36, 7-76), [](0-75, 7-13, 2-81, 8-29, 4-54, 6-82, 5-88, 1-78, 9-40, 3-13), [](2-6, 1-26, 7-32, 6-64, 4-54, 0-52, 5-82, 3-6, 9-88, 8-54), [](8-62, 2-67, 5-32, 0-62, 7-69, 3-61, 1-35, 4-72, 9-5, 6-93), [](2-78, 9-90, 0-85, 1-72, 8-64, 6-63, 3-11, 7-82, 5-88, 4-7), [](4-28, 9-11, 7-50, 6-88, 0-44, 5-31, 2-27, 1-66, 8-49, 3-35), [](2-14, 5-39, 6-56, 4-62, 3-97, 9-66, 7-69, 1-7, 8-47, 0-76), [](1-18, 8-93, 7-58, 6-47, 3-69, 9-57, 2-41, 5-53, 4-79, 0-64))).
jobshop(la24, "Lawrence 15x10 instance (Table 7, instance 4); also called (setb4) or (B4)", 15, 10, []([](7-8, 9-75, 0-72, 6-74, 4-30, 8-43, 2-38, 5-98, 1-26, 3-19), [](6-19, 8-73, 3-43, 0-23, 1-85, 4-39, 5-13, 9-26, 2-67, 7-9), [](1-50, 3-93, 5-80, 4-7, 0-55, 2-61, 6-57, 8-72, 9-42, 7-46), [](1-68, 7-43, 4-99, 6-60, 5-68, 0-91, 8-11, 3-96, 9-11, 2-72), [](7-84, 2-34, 8-40, 5-7, 1-70, 6-74, 3-12, 0-43, 9-69, 4-30), [](8-60, 0-49, 4-59, 5-72, 9-63, 1-69, 7-99, 6-45, 3-27, 2-9), [](6-71, 2-91, 8-65, 1-90, 9-98, 4-8, 7-50, 0-75, 5-37, 3-17), [](8-62, 7-90, 5-98, 3-31, 2-91, 4-38, 9-72, 1-9, 0-72, 6-49), [](4-35, 0-39, 9-74, 5-25, 7-47, 3-52, 2-63, 8-21, 6-35, 1-80), [](9-58, 0-5, 3-50, 8-52, 1-88, 6-20, 2-68, 5-24, 4-53, 7-57), [](7-99, 3-91, 4-33, 5-19, 2-18, 6-38, 0-24, 9-35, 1-49, 8-9), [](0-68, 3-60, 2-77, 7-10, 8-60, 5-15, 9-72, 1-18, 6-90, 4-18), [](9-79, 1-60, 3-56, 6-91, 2-40, 8-86, 7-72, 0-80, 5-89, 4-51), [](4-10, 2-92, 5-23, 6-46, 8-40, 7-72, 3-6, 1-23, 0-95, 9-34), [](2-24, 5-29, 9-49, 8-55, 0-47, 6-77, 3-77, 7-8, 1-28, 4-48))).
jobshop(la25, "Lawrence 15x10 instance (Table 7, instance 5); also called (setb5) or (B5)", 15, 10, []([](8-14, 4-75, 3-12, 2-38, 0-76, 5-97, 9-12, 1-29, 7-44, 6-66), [](5-38, 3-82, 2-85, 4-58, 6-87, 9-89, 0-43, 1-80, 7-69, 8-92), [](9-5, 1-84, 0-43, 6-48, 4-8, 7-7, 3-41, 5-61, 8-66, 2-14), [](2-42, 1-8, 0-96, 5-19, 4-59, 7-97, 9-73, 8-43, 3-74, 6-41), [](6-55, 2-70, 3-75, 8-42, 4-37, 7-23, 1-48, 5-5, 9-38, 0-7), [](8-9, 2-72, 7-31, 0-79, 5-73, 3-95, 4-25, 6-43, 9-60, 1-56), [](0-97, 2-64, 3-78, 5-21, 4-94, 9-31, 8-53, 6-16, 7-86, 1-7), [](3-86, 7-85, 9-63, 0-61, 2-65, 4-30, 5-32, 1-33, 8-44, 6-59), [](2-44, 3-16, 4-11, 6-45, 1-30, 9-84, 8-93, 0-60, 5-61, 7-90), [](7-36, 8-31, 4-47, 6-52, 0-32, 5-11, 2-28, 9-35, 3-20, 1-49), [](8-20, 6-49, 7-74, 4-10, 5-17, 3-34, 0-85, 2-77, 9-68, 1-84), [](1-85, 5-7, 8-71, 6-59, 4-76, 0-17, 3-29, 2-17, 7-48, 9-13), [](2-15, 6-87, 7-11, 1-39, 4-39, 8-43, 0-19, 3-32, 9-16, 5-64), [](6-32, 2-92, 5-33, 8-82, 1-83, 7-57, 9-99, 4-91, 3-99, 0-8), [](4-88, 7-7, 8-27, 1-38, 3-91, 2-69, 6-21, 9-62, 5-39, 0-48))).
jobshop(la26, "Lawrence 20x10 instance (Table 8, instance 1); also called (setc1) or (C1)", 20, 10, []([](8-52, 7-26, 6-71, 9-16, 2-34, 1-21, 5-95, 4-21, 0-53, 3-55), [](4-55, 5-98, 3-39, 9-79, 0-12, 8-77, 6-77, 7-66, 2-31, 1-42), [](5-37, 4-92, 2-64, 6-54, 1-19, 7-43, 0-83, 3-34, 9-79, 8-62), [](1-87, 5-77, 0-93, 3-69, 2-87, 7-38, 8-24, 6-41, 9-83, 4-60), [](2-98, 5-25, 6-75, 9-77, 1-49, 3-17, 8-79, 0-44, 7-43, 4-96), [](1-7, 4-61, 0-95, 2-35, 9-10, 8-35, 5-28, 3-76, 7-95, 6-9), [](5-59, 9-43, 0-46, 4-28, 6-52, 3-16, 2-59, 1-91, 8-50, 7-27), [](5-9, 9-43, 8-14, 7-71, 4-20, 6-54, 3-41, 0-87, 1-45, 2-39), [](1-28, 8-66, 0-78, 2-37, 9-42, 3-26, 5-33, 6-89, 4-33, 7-8), [](4-96, 3-27, 6-78, 5-84, 2-94, 8-69, 1-74, 9-81, 7-45, 0-69), [](4-24, 7-32, 9-25, 2-17, 3-87, 8-81, 5-76, 6-18, 1-31, 0-20), [](8-90, 5-28, 1-72, 7-86, 2-23, 3-99, 6-76, 9-97, 4-45, 0-58), [](2-17, 4-98, 3-48, 1-46, 8-27, 6-67, 7-62, 0-42, 9-48, 5-27), [](0-80, 8-50, 3-19, 7-98, 5-28, 2-50, 4-94, 6-63, 1-12, 9-80), [](9-72, 0-75, 4-61, 8-79, 6-37, 2-50, 5-14, 3-55, 7-18, 1-41), [](3-96, 2-14, 5-57, 0-47, 7-65, 4-75, 8-79, 1-71, 6-60, 9-22), [](1-31, 7-47, 8-58, 3-32, 4-44, 5-58, 6-34, 0-33, 2-69, 9-51), [](1-44, 7-40, 2-17, 0-62, 8-66, 6-15, 3-29, 9-38, 5-8, 4-97), [](2-58, 3-50, 4-63, 9-87, 0-57, 6-21, 7-57, 8-32, 1-39, 5-20), [](1-85, 0-84, 5-56, 3-61, 9-15, 7-70, 8-30, 2-90, 6-67, 4-20))).
jobshop(la27, "Lawrence 20x10 instance (Table 8, instance 2); also called (setc2) or (C2)", 20, 10, []([](3-60, 4-48, 5-95, 0-87, 1-72, 9-5, 8-35, 7-39, 6-54, 2-66), [](7-37, 6-34, 0-97, 5-55, 2-21, 3-20, 4-59, 9-46, 8-19, 1-46), [](4-45, 2-73, 1-24, 8-28, 0-28, 3-25, 5-23, 7-83, 9-5, 6-78), [](0-53, 2-12, 9-12, 1-37, 8-33, 3-71, 6-55, 5-29, 7-87, 4-38), [](4-90, 2-49, 9-27, 7-65, 5-7, 6-23, 0-48, 3-83, 8-17, 1-40), [](3-85, 4-25, 2-84, 6-64, 9-13, 1-66, 7-46, 8-59, 0-62, 5-19), [](5-88, 6-67, 4-14, 0-41, 1-73, 7-57, 2-53, 3-80, 9-47, 8-74), [](1-78, 5-64, 4-63, 6-46, 3-84, 0-84, 8-28, 9-52, 7-26, 2-41), [](1-11, 0-64, 6-97, 9-38, 2-17, 4-85, 5-73, 3-10, 8-95, 7-67), [](3-93, 2-95, 7-43, 1-65, 8-32, 0-59, 6-85, 5-46, 9-85, 4-60), [](2-61, 3-41, 5-49, 4-23, 0-66, 7-49, 8-70, 9-99, 1-90, 6-17), [](4-13, 7-7, 1-98, 8-57, 0-73, 3-73, 2-68, 5-40, 9-98, 6-9), [](9-86, 6-76, 4-14, 3-41, 1-85, 0-37, 8-19, 2-17, 7-54, 5-79), [](1-40, 2-53, 7-97, 5-87, 8-96, 4-84, 3-16, 6-66, 9-52, 0-95), [](6-33, 1-33, 3-87, 0-18, 2-55, 8-13, 4-77, 7-60, 9-42, 5-74), [](7-92, 5-91, 8-79, 2-54, 4-69, 6-79, 3-33, 1-61, 9-39, 0-16), [](6-82, 1-41, 4-28, 5-64, 2-78, 3-76, 7-6, 8-49, 9-47, 0-58), [](0-52, 5-42, 8-24, 9-91, 3-47, 6-88, 4-91, 7-52, 2-28, 1-35), [](5-82, 2-76, 3-86, 6-93, 4-84, 7-38, 8-95, 9-37, 1-21, 0-23), [](9-77, 4-8, 6-42, 7-64, 0-70, 2-45, 8-45, 5-28, 3-67, 1-86))).
jobshop(la28, "Lawrence 20x10 instance (Table 8, instance 3); also called (setc3) or (C3)", 20, 10, []([](8-32, 1-81, 4-55, 7-40, 0-6, 5-19, 9-81, 3-37, 2-40, 6-9), [](2-70, 3-55, 7-21, 4-64, 1-46, 8-25, 9-65, 0-77, 5-65, 6-15), [](7-84, 4-89, 3-24, 1-44, 2-85, 8-31, 9-29, 6-83, 5-37, 0-40), [](4-80, 5-59, 0-8, 2-30, 6-77, 3-38, 1-80, 7-56, 9-41, 8-97), [](6-40, 2-71, 0-91, 7-7, 9-59, 8-80, 3-50, 5-56, 1-17, 4-88), [](7-36, 9-10, 0-45, 6-9, 4-54, 8-96, 2-8, 5-77, 1-29, 3-58), [](6-99, 8-86, 3-92, 0-28, 1-98, 4-70, 5-87, 9-96, 2-73, 7-27), [](1-95, 3-85, 5-56, 4-52, 0-59, 2-41, 6-81, 8-39, 9-32, 7-92), [](1-7, 7-69, 4-93, 6-27, 5-22, 0-88, 8-45, 3-60, 9-49, 2-12), [](7-33, 2-61, 8-44, 5-26, 1-84, 6-82, 3-68, 0-21, 9-71, 4-99), [](8-43, 0-72, 4-30, 5-98, 9-75, 1-26, 7-8, 6-74, 3-19, 2-38), [](6-19, 2-67, 8-73, 1-85, 9-26, 4-39, 7-9, 0-23, 5-13, 3-43), [](8-72, 7-46, 5-80, 3-93, 2-61, 4-7, 9-42, 1-50, 0-55, 6-57), [](4-99, 0-91, 9-11, 5-68, 7-43, 3-96, 2-72, 8-11, 6-60, 1-68), [](9-69, 0-43, 3-12, 8-40, 1-70, 6-74, 2-34, 5-7, 4-30, 7-84), [](7-99, 3-27, 4-59, 5-72, 2-9, 6-45, 0-49, 9-63, 1-69, 8-60), [](0-75, 3-17, 2-91, 7-50, 8-65, 5-37, 9-98, 1-90, 6-71, 4-8), [](9-72, 1-9, 3-31, 6-49, 2-91, 8-62, 7-90, 0-72, 5-98, 4-38), [](4-35, 2-63, 5-25, 6-35, 8-21, 7-47, 3-52, 1-80, 0-39, 9-74), [](2-68, 5-24, 9-58, 8-52, 0-5, 6-20, 3-50, 7-57, 1-88, 4-53))).
jobshop(la29, "Lawrence 20x10 instance (Table 8, instance 4); also called (setc4) or (C4)", 20, 10, []([](8-14, 2-38, 7-44, 0-76, 5-97, 3-12, 4-75, 6-66, 9-12, 1-29), [](0-43, 2-85, 3-82, 5-38, 4-58, 9-89, 8-92, 6-87, 7-69, 1-80), [](3-41, 7-7, 9-5, 0-43, 2-14, 4-8, 5-61, 1-84, 8-66, 6-48), [](2-42, 3-74, 4-59, 6-41, 1-8, 9-73, 8-43, 0-96, 5-19, 7-97), [](7-23, 8-42, 4-37, 6-55, 0-7, 5-5, 2-70, 9-38, 3-75, 1-48), [](8-9, 6-43, 7-31, 4-25, 5-73, 3-95, 0-79, 2-72, 9-60, 1-56), [](1-7, 5-21, 8-53, 6-16, 4-94, 0-97, 3-78, 2-64, 7-86, 9-31), [](2-65, 6-59, 7-85, 1-33, 4-30, 8-44, 0-61, 3-86, 9-63, 5-32), [](6-45, 2-44, 5-61, 8-93, 1-30, 7-90, 9-84, 4-11, 3-16, 0-60), [](4-47, 7-36, 8-31, 1-49, 3-20, 2-28, 6-52, 9-35, 5-11, 0-32), [](2-77, 4-10, 9-68, 5-17, 0-85, 1-84, 8-20, 6-49, 7-74, 3-34), [](0-17, 5-7, 1-85, 3-29, 2-17, 4-76, 6-59, 8-71, 9-13, 7-48), [](6-87, 4-39, 8-43, 7-11, 2-15, 3-32, 5-64, 0-19, 1-39, 9-16), [](5-33, 3-99, 6-32, 4-91, 8-82, 2-92, 9-99, 7-57, 1-83, 0-8), [](3-91, 5-39, 2-69, 8-27, 7-7, 6-21, 1-38, 9-62, 4-88, 0-48), [](2-67, 7-80, 3-24, 0-88, 4-18, 1-44, 8-45, 9-64, 5-80, 6-38), [](9-59, 3-72, 6-47, 4-40, 7-21, 5-43, 0-51, 8-52, 1-24, 2-15), [](3-70, 2-31, 6-20, 8-76, 1-40, 7-43, 0-32, 5-88, 9-5, 4-77), [](4-47, 5-64, 9-85, 3-49, 7-58, 1-26, 0-32, 8-80, 2-14, 6-94), [](5-59, 2-96, 0-5, 7-79, 8-34, 4-75, 3-26, 6-9, 9-23, 1-11))).
jobshop(la30, "Lawrence 20x10 instance (Table 8, instance 5); also called (setc5) or (C5)", 20, 10, []([](6-32, 3-16, 1-33, 8-12, 7-70, 4-10, 9-75, 0-82, 5-88, 2-20), [](8-39, 4-81, 3-91, 5-56, 9-69, 1-45, 6-59, 0-86, 2-36, 7-68), [](3-84, 2-57, 7-41, 5-73, 4-81, 0-88, 8-38, 9-17, 6-83, 1-5), [](4-20, 5-6, 2-15, 8-19, 1-30, 0-94, 6-45, 7-17, 3-18, 9-88), [](9-24, 6-49, 5-16, 4-11, 3-60, 7-5, 8-63, 1-25, 2-15, 0-45), [](1-86, 8-50, 2-77, 6-54, 9-48, 0-93, 3-32, 7-92, 5-45, 4-71), [](5-86, 6-90, 3-78, 9-88, 2-57, 0-32, 7-57, 8-86, 4-71, 1-39), [](2-59, 3-18, 9-31, 4-41, 7-20, 5-83, 8-65, 0-54, 6-94, 1-69), [](3-47, 4-79, 6-76, 0-59, 1-72, 2-8, 9-30, 5-73, 7-57, 8-84), [](0-59, 2-89, 4-10, 7-45, 3-8, 5-54, 6-88, 8-20, 9-7, 1-62), [](5-63, 6-9, 4-77, 3-37, 2-5, 8-13, 9-79, 1-24, 7-10, 0-82), [](0-74, 1-32, 2-61, 7-53, 4-92, 9-20, 8-10, 3-5, 6-45, 5-23), [](2-85, 9-51, 0-61, 5-99, 4-37, 6-94, 1-98, 8-65, 3-33, 7-75), [](0-51, 3-24, 5-8, 6-30, 7-12, 8-23, 2-7, 4-17, 9-35, 1-81), [](1-71, 5-42, 8-68, 2-31, 6-29, 3-63, 4-65, 9-70, 7-27, 0-93), [](1-28, 5-38, 4-51, 7-70, 2-33, 8-78, 9-45, 3-90, 6-54, 0-72), [](0-18, 2-90, 4-25, 6-92, 8-85, 5-35, 7-29, 1-81, 9-80, 3-59), [](5-67, 2-96, 1-38, 4-86, 0-97, 3-94, 7-86, 6-35, 9-82, 8-45), [](2-92, 8-51, 4-59, 6-52, 5-8, 9-70, 1-75, 3-54, 7-60, 0-33), [](3-98, 7-80, 5-78, 0-82, 2-7, 9-89, 1-69, 4-51, 8-79, 6-62))).
jobshop(la31, "Lawrence 30x10 instance (Table 9, instance 1); also called (setd1) or (D1)", 30, 10, []([](4-21, 7-26, 9-16, 2-34, 3-55, 8-52, 5-95, 6-71, 1-21, 0-53), [](8-77, 5-98, 1-42, 7-66, 2-31, 3-39, 6-77, 9-79, 4-55, 0-12), [](2-64, 4-92, 3-34, 1-19, 8-62, 6-54, 7-43, 0-83, 9-79, 5-37), [](0-93, 8-24, 3-69, 7-38, 5-77, 2-87, 4-60, 6-41, 1-87, 9-83), [](9-77, 0-44, 4-96, 8-79, 6-75, 2-98, 5-25, 3-17, 7-43, 1-49), [](3-76, 2-35, 5-28, 0-95, 7-95, 4-61, 8-35, 1-7, 6-9, 9-10), [](1-91, 7-27, 8-50, 3-16, 4-28, 5-59, 6-52, 0-46, 2-59, 9-43), [](1-45, 7-71, 2-39, 0-87, 8-14, 6-54, 3-41, 9-43, 5-9, 4-20), [](2-37, 3-26, 4-33, 9-42, 0-78, 6-89, 7-8, 8-66, 1-28, 5-33), [](1-74, 0-69, 5-84, 3-27, 9-81, 7-45, 8-69, 2-94, 6-78, 4-96), [](5-76, 7-32, 6-18, 0-20, 3-87, 2-17, 9-25, 4-24, 1-31, 8-81), [](9-97, 8-90, 5-28, 7-86, 0-58, 1-72, 2-23, 6-76, 3-99, 4-45), [](9-48, 5-27, 6-67, 7-62, 4-98, 0-42, 1-46, 8-27, 3-48, 2-17), [](9-80, 3-19, 5-28, 1-12, 4-94, 6-63, 7-98, 8-50, 0-80, 2-50), [](2-50, 1-41, 4-61, 8-79, 5-14, 9-72, 7-18, 3-55, 6-37, 0-75), [](9-22, 5-57, 4-75, 2-14, 7-65, 3-96, 1-71, 0-47, 8-79, 6-60), [](3-32, 2-69, 4-44, 1-31, 9-51, 0-33, 6-34, 5-58, 7-47, 8-58), [](8-66, 7-40, 2-17, 0-62, 9-38, 5-8, 6-15, 3-29, 1-44, 4-97), [](3-50, 2-58, 6-21, 4-63, 7-57, 8-32, 5-20, 9-87, 0-57, 1-39), [](4-20, 6-67, 1-85, 2-90, 7-70, 0-84, 8-30, 5-56, 3-61, 9-15), [](6-29, 0-82, 4-18, 3-38, 7-21, 8-50, 1-23, 5-84, 2-45, 9-41), [](3-54, 9-37, 6-62, 5-16, 0-52, 8-57, 4-54, 2-38, 7-74, 1-52), [](4-79, 1-61, 8-11, 0-81, 7-89, 6-89, 5-57, 3-68, 9-81, 2-30), [](9-24, 1-66, 4-32, 3-33, 8-8, 2-20, 6-84, 0-91, 7-55, 5-20), [](3-54, 2-64, 6-83, 9-40, 7-8, 0-7, 4-19, 5-56, 1-39, 8-7), [](1-6, 4-74, 0-63, 2-64, 9-15, 6-42, 7-98, 8-61, 5-40, 3-91), [](1-80, 3-75, 0-26, 2-87, 9-22, 7-39, 8-24, 4-75, 6-44, 5-6), [](5-8, 3-79, 6-61, 1-15, 0-12, 7-43, 8-26, 9-22, 2-20, 4-80), [](1-36, 0-63, 7-10, 4-22, 3-96, 5-40, 9-5, 8-18, 6-33, 2-62), [](4-8, 8-15, 2-64, 3-95, 1-96, 6-38, 7-18, 9-23, 5-64, 0-89))).
jobshop(la32, "Lawrence 30x10 instance (Table 9, instance 2); also called (setd2) or (D2)", 30, 10, []([](6-89, 1-58, 4-97, 2-44, 8-77, 3-5, 0-9, 5-58, 9-96, 7-84), [](7-31, 2-81, 9-73, 4-15, 1-87, 5-39, 8-57, 0-77, 3-85, 6-21), [](2-48, 5-71, 0-40, 3-70, 1-49, 6-22, 4-10, 8-34, 7-80, 9-82), [](4-11, 6-72, 7-62, 0-55, 2-17, 5-75, 3-7, 1-91, 9-35, 8-47), [](0-64, 6-71, 4-12, 1-90, 2-94, 3-75, 9-20, 8-15, 5-50, 7-67), [](2-29, 6-93, 3-68, 5-93, 1-57, 8-77, 0-52, 9-7, 4-58, 7-70), [](4-26, 3-27, 1-63, 5-6, 6-87, 7-56, 8-48, 9-36, 0-95, 2-82), [](1-8, 7-76, 3-76, 4-30, 6-84, 9-78, 8-41, 0-36, 2-36, 5-15), [](3-13, 8-29, 0-75, 2-81, 1-78, 5-88, 4-54, 9-40, 7-13, 6-82), [](0-52, 2-6, 3-6, 5-82, 6-64, 9-88, 8-54, 4-54, 7-32, 1-26), [](8-62, 1-35, 4-72, 7-69, 0-62, 5-32, 9-5, 3-61, 2-67, 6-93), [](2-78, 3-11, 7-82, 4-7, 1-72, 8-64, 9-90, 0-85, 5-88, 6-63), [](7-50, 4-28, 3-35, 1-66, 2-27, 8-49, 9-11, 6-88, 5-31, 0-44), [](4-62, 5-39, 0-76, 2-14, 6-56, 3-97, 1-7, 7-69, 9-66, 8-47), [](6-47, 2-41, 0-64, 7-58, 9-57, 8-93, 3-69, 5-53, 1-18, 4-79), [](7-76, 9-81, 0-76, 6-61, 4-77, 8-26, 2-74, 5-22, 1-58, 3-78), [](6-30, 8-72, 3-43, 0-65, 1-16, 4-92, 5-95, 9-29, 2-99, 7-64), [](1-35, 3-74, 5-16, 4-85, 0-7, 2-81, 6-86, 8-61, 9-35, 7-34), [](1-97, 7-43, 4-72, 6-88, 5-17, 0-43, 8-94, 3-64, 9-22, 2-42), [](7-99, 2-84, 8-99, 5-98, 1-20, 6-31, 3-74, 0-92, 9-23, 4-89), [](8-32, 0-6, 4-55, 5-19, 9-81, 1-81, 7-40, 6-9, 3-37, 2-40), [](6-15, 2-70, 8-25, 1-46, 9-65, 4-64, 7-21, 0-77, 5-65, 3-55), [](8-31, 7-84, 5-37, 3-24, 2-85, 4-89, 9-29, 1-44, 0-40, 6-83), [](4-80, 0-8, 9-41, 5-59, 7-56, 3-38, 2-30, 8-97, 6-77, 1-80), [](9-59, 0-91, 3-50, 8-80, 1-17, 6-40, 2-71, 5-56, 4-88, 7-7), [](7-36, 3-58, 4-54, 5-77, 2-8, 6-9, 0-45, 9-10, 1-29, 8-96), [](0-28, 3-92, 2-73, 7-27, 8-86, 5-87, 9-96, 1-98, 6-99, 4-70), [](9-32, 1-95, 3-85, 6-81, 2-41, 8-39, 7-92, 0-59, 5-56, 4-52), [](4-93, 2-12, 5-22, 6-27, 8-45, 7-69, 3-60, 1-7, 0-88, 9-49), [](2-61, 5-26, 9-71, 8-44, 0-21, 6-82, 3-68, 7-33, 1-84, 4-99))).
jobshop(la33, "Lawrence 30x10 instance (Table 9, instance 3); also called (setd3) or (D3)", 30, 10, []([](2-38, 4-75, 9-12, 5-97, 0-76, 1-29, 8-14, 6-66, 7-44, 3-12), [](0-43, 5-38, 1-80, 3-82, 2-85, 4-58, 6-87, 8-92, 9-89, 7-69), [](6-48, 4-8, 8-66, 7-7, 2-14, 3-41, 5-61, 0-43, 1-84, 9-5), [](5-19, 3-74, 6-41, 4-59, 8-43, 2-42, 9-73, 7-97, 1-8, 0-96), [](3-75, 5-5, 2-70, 8-42, 7-23, 6-55, 1-48, 9-38, 4-37, 0-7), [](2-72, 7-31, 3-95, 0-79, 4-25, 1-56, 8-9, 9-60, 5-73, 6-43), [](9-31, 3-78, 6-16, 4-94, 7-86, 5-21, 0-97, 8-53, 1-7, 2-64), [](3-86, 2-65, 6-59, 8-44, 1-33, 7-85, 0-61, 5-32, 9-63, 4-30), [](4-11, 5-61, 9-84, 3-16, 7-90, 1-30, 0-60, 8-93, 2-44, 6-45), [](5-11, 2-28, 0-32, 7-36, 8-31, 4-47, 3-20, 6-52, 9-35, 1-49), [](5-17, 3-34, 6-49, 1-84, 0-85, 8-20, 7-74, 9-68, 4-10, 2-77), [](8-71, 5-7, 3-29, 1-85, 4-76, 6-59, 2-17, 0-17, 9-13, 7-48), [](1-39, 9-16, 4-39, 6-87, 7-11, 3-32, 2-15, 0-19, 5-64, 8-43), [](5-33, 8-82, 2-92, 1-83, 6-32, 3-99, 9-99, 4-91, 0-8, 7-57), [](7-7, 0-48, 9-62, 4-88, 6-21, 5-39, 8-27, 3-91, 1-38, 2-69), [](9-64, 8-45, 3-24, 7-80, 2-67, 4-18, 6-38, 0-88, 5-80, 1-44), [](2-15, 3-72, 4-40, 7-21, 8-52, 0-51, 9-59, 1-24, 6-47, 5-43), [](4-77, 7-43, 1-40, 2-31, 8-76, 6-20, 5-88, 3-70, 9-5, 0-32), [](2-14, 7-58, 9-85, 5-64, 1-26, 6-94, 0-32, 3-49, 8-80, 4-47), [](9-23, 1-11, 8-34, 4-75, 7-79, 3-26, 2-96, 0-5, 6-9, 5-59), [](0-75, 2-20, 8-10, 3-66, 6-43, 7-37, 1-9, 9-83, 4-68, 5-52), [](8-54, 1-26, 4-79, 7-88, 6-84, 0-6, 2-54, 9-59, 3-28, 5-42), [](4-56, 9-29, 3-36, 0-40, 6-86, 8-68, 2-69, 7-23, 5-62, 1-16), [](7-53, 1-5, 6-17, 9-59, 2-59, 8-78, 3-64, 0-82, 4-13, 5-12), [](9-7, 6-62, 7-90, 5-83, 1-85, 3-69, 0-16, 4-81, 2-58, 8-66), [](7-24, 2-65, 1-69, 5-42, 9-82, 6-82, 0-83, 3-46, 8-72, 4-33), [](1-10, 8-27, 7-43, 5-20, 4-71, 9-65, 2-73, 6-99, 0-24, 3-64), [](9-35, 3-92, 0-38, 5-35, 7-30, 8-45, 2-8, 4-82, 1-34, 6-21), [](5-23, 7-84, 9-7, 4-85, 8-60, 1-15, 2-52, 6-94, 3-83, 0-6), [](2-70, 6-29, 8-27, 9-80, 4-6, 7-39, 1-79, 0-28, 3-66, 5-66))).
jobshop(la34, "Lawrence 30x10 instance (Table 9, instance 4); also called (setd4) or (D4)", 30, 10, []([](2-51, 7-59, 1-35, 5-73, 9-65, 0-27, 6-13, 3-81, 8-32, 4-74), [](4-64, 7-33, 5-75, 2-33, 8-10, 0-28, 3-38, 6-53, 9-49, 1-55), [](6-83, 1-23, 2-72, 3-7, 9-72, 0-6, 4-39, 5-52, 8-90, 7-21), [](3-82, 1-23, 2-93, 4-78, 6-88, 7-53, 9-28, 8-65, 5-21, 0-61), [](4-41, 6-12, 9-12, 3-77, 1-70, 7-24, 0-81, 5-73, 2-62, 8-6), [](4-98, 3-28, 6-42, 9-72, 0-15, 8-15, 5-94, 2-33, 1-51, 7-99), [](0-32, 8-22, 9-96, 4-15, 6-78, 3-31, 5-7, 1-94, 2-23, 7-86), [](7-93, 2-97, 3-43, 5-73, 0-24, 8-68, 9-88, 1-42, 4-35, 6-72), [](2-14, 0-44, 8-13, 5-67, 1-63, 3-49, 7-5, 4-17, 6-85, 9-66), [](7-82, 9-15, 3-72, 4-26, 0-8, 1-68, 6-21, 8-45, 2-99, 5-27), [](4-93, 6-23, 0-51, 8-54, 3-49, 1-96, 2-56, 9-36, 5-53, 7-52), [](8-60, 0-14, 4-70, 9-55, 1-23, 5-83, 3-38, 2-24, 7-37, 6-48), [](0-62, 7-15, 8-69, 9-23, 1-82, 6-26, 4-45, 5-33, 3-12, 2-37), [](6-72, 1-9, 7-15, 5-28, 8-92, 9-12, 0-59, 3-64, 4-87, 2-73), [](0-50, 1-14, 7-90, 5-46, 3-71, 4-48, 2-80, 9-61, 8-24, 6-44), [](0-22, 9-94, 5-16, 3-73, 2-54, 8-54, 4-46, 1-97, 6-61, 7-75), [](9-55, 3-67, 6-77, 4-30, 7-6, 1-32, 8-47, 5-93, 2-6, 0-40), [](1-30, 3-98, 7-79, 0-22, 6-79, 2-7, 8-36, 9-36, 5-9, 4-92), [](8-37, 7-72, 2-52, 4-31, 1-82, 9-54, 5-7, 6-82, 3-73, 0-49), [](1-73, 3-83, 7-45, 2-76, 4-43, 9-29, 0-35, 5-92, 8-39, 6-28), [](2-58, 0-26, 1-48, 8-52, 7-34, 6-96, 5-70, 4-98, 3-80, 9-94), [](1-70, 8-23, 5-26, 4-14, 6-90, 2-93, 3-21, 0-42, 7-18, 9-36), [](4-28, 6-76, 7-25, 0-17, 1-84, 2-67, 8-87, 3-43, 9-88, 5-84), [](7-30, 3-91, 8-52, 4-80, 0-21, 5-8, 9-37, 2-15, 6-12, 1-92), [](1-28, 4-7, 7-46, 6-92, 2-77, 3-15, 9-69, 8-54, 0-47, 5-39), [](9-50, 5-44, 2-64, 8-38, 4-93, 6-33, 7-75, 0-41, 1-24, 3-5), [](7-94, 0-17, 6-87, 2-21, 8-92, 9-28, 1-61, 4-63, 3-34, 5-77), [](3-72, 8-98, 9-5, 4-28, 2-9, 5-95, 6-64, 1-43, 0-50, 7-96), [](0-85, 2-85, 8-39, 1-98, 7-24, 3-71, 5-60, 4-55, 9-22, 6-35), [](3-78, 6-49, 2-46, 1-11, 0-90, 5-20, 9-34, 7-6, 4-70, 8-74))).
jobshop(la35, "Lawrence 30x10 instance (Table 9, instance 5); also called (setd5) or (D5)", 30, 10, []([](0-66, 2-84, 3-26, 7-29, 9-94, 6-98, 8-7, 5-98, 1-45, 4-43), [](3-32, 0-97, 6-55, 2-88, 8-93, 9-88, 1-20, 4-50, 7-17, 5-5), [](4-43, 3-68, 8-47, 9-68, 1-57, 6-20, 5-81, 2-60, 7-94, 0-62), [](1-57, 5-40, 0-78, 6-9, 2-49, 9-17, 3-32, 4-30, 8-87, 7-77), [](0-52, 4-30, 3-48, 5-48, 1-26, 9-17, 6-93, 8-97, 7-49, 2-89), [](7-95, 0-33, 1-5, 6-17, 5-70, 3-57, 4-34, 2-61, 8-62, 9-39), [](7-97, 5-92, 1-31, 8-5, 2-79, 4-5, 3-67, 0-5, 9-78, 6-60), [](2-79, 4-6, 7-20, 8-45, 6-34, 3-24, 9-26, 5-68, 1-16, 0-46), [](7-58, 9-50, 2-19, 8-93, 6-49, 3-25, 5-85, 4-50, 0-93, 1-26), [](9-81, 6-71, 5-7, 1-39, 2-16, 8-42, 0-71, 4-84, 3-56, 7-99), [](8-9, 0-86, 9-6, 3-71, 6-97, 5-85, 4-16, 2-42, 7-81, 1-81), [](4-72, 3-24, 0-30, 8-56, 2-43, 1-61, 7-82, 6-40, 5-59, 9-43), [](9-43, 1-13, 6-70, 7-93, 0-95, 8-12, 4-15, 2-78, 5-97, 3-14), [](0-14, 6-26, 1-71, 3-46, 8-80, 5-31, 4-37, 9-27, 7-92, 2-67), [](2-12, 0-43, 5-96, 6-7, 3-45, 7-20, 1-13, 9-29, 4-60, 8-33), [](1-78, 5-50, 6-84, 0-42, 8-84, 4-30, 9-76, 2-57, 7-87, 3-59), [](4-49, 7-50, 1-15, 8-13, 0-93, 6-50, 9-32, 5-59, 3-10, 2-35), [](1-25, 0-47, 7-60, 8-33, 4-53, 5-37, 9-73, 2-22, 3-87, 6-79), [](0-84, 6-83, 1-71, 5-68, 9-89, 8-11, 3-60, 4-50, 2-33, 7-97), [](1-14, 0-38, 6-88, 5-5, 4-77, 7-92, 8-24, 2-73, 9-52, 3-71), [](7-62, 9-19, 6-38, 3-15, 8-64, 2-64, 4-8, 1-61, 0-19, 5-33), [](2-33, 5-46, 4-74, 0-56, 6-84, 9-83, 8-19, 7-8, 3-32, 1-97), [](4-50, 3-71, 6-50, 2-97, 9-8, 0-17, 7-19, 8-92, 5-54, 1-52), [](8-32, 1-79, 3-97, 5-38, 9-49, 4-76, 6-76, 0-56, 2-78, 7-54), [](5-13, 3-5, 2-25, 0-86, 1-95, 9-28, 6-78, 8-24, 7-10, 4-39), [](7-48, 2-59, 0-20, 9-7, 5-31, 6-97, 1-89, 4-32, 3-25, 8-41), [](5-87, 0-18, 9-48, 2-43, 1-30, 6-97, 7-47, 8-65, 3-69, 4-27), [](6-71, 5-20, 8-20, 1-78, 3-39, 0-17, 7-50, 2-44, 9-42, 4-38), [](0-50, 9-42, 3-72, 5-7, 1-77, 7-58, 4-78, 2-89, 6-70, 8-36), [](3-32, 9-95, 2-13, 0-73, 6-97, 8-24, 4-49, 5-57, 1-68, 7-94))).
jobshop(la36, "Lawrence 15x15 instance (Table 10, instance 1); also called (seti1) or (I1)", 15, 15, []([](4-21, 3-55, 6-71, 14-98, 10-12, 2-34, 9-16, 1-21, 0-53, 7-26, 8-52, 5-95, 12-31, 11-42, 13-39), [](11-54, 4-83, 1-77, 7-64, 8-34, 14-79, 12-43, 0-55, 3-77, 6-19, 9-37, 5-79, 10-92, 13-62, 2-66), [](9-83, 5-77, 2-87, 7-38, 4-60, 12-98, 0-93, 13-17, 6-41, 10-44, 3-69, 11-49, 8-24, 1-87, 14-25), [](5-77, 0-96, 9-28, 6-7, 4-95, 13-35, 7-35, 8-76, 11-9, 12-95, 2-43, 1-75, 10-61, 14-10, 3-79), [](10-87, 4-28, 8-50, 2-59, 0-46, 11-45, 14-9, 9-43, 6-52, 7-27, 1-91, 13-41, 3-16, 5-59, 12-39), [](0-20, 2-71, 4-78, 13-66, 3-14, 12-8, 14-42, 6-28, 1-54, 9-33, 11-89, 8-26, 7-37, 10-33, 5-43), [](8-69, 4-96, 12-17, 0-69, 7-45, 11-31, 6-78, 10-20, 3-27, 13-87, 1-74, 5-84, 14-76, 2-94, 9-81), [](4-58, 13-90, 11-76, 3-81, 7-23, 9-28, 1-18, 2-32, 12-86, 8-99, 14-97, 0-24, 10-45, 6-72, 5-25), [](5-27, 1-46, 6-67, 8-27, 13-19, 10-80, 2-17, 3-48, 7-62, 11-12, 14-28, 4-98, 0-42, 9-48, 12-50), [](11-37, 5-80, 4-75, 8-55, 7-50, 0-94, 9-14, 6-41, 14-72, 3-50, 10-61, 13-79, 2-98, 12-18, 1-63), [](7-65, 3-96, 0-47, 4-75, 12-69, 14-58, 10-33, 1-71, 9-22, 13-32, 5-57, 8-79, 2-14, 11-31, 6-60), [](1-34, 2-47, 3-58, 5-51, 4-62, 6-44, 9-8, 7-17, 10-97, 8-29, 11-15, 13-66, 12-40, 0-44, 14-38), [](3-50, 7-57, 13-61, 5-20, 11-85, 12-90, 2-58, 4-63, 10-84, 1-39, 9-87, 6-21, 14-56, 8-32, 0-57), [](9-84, 7-45, 5-15, 14-41, 10-18, 4-82, 11-29, 2-70, 1-67, 3-30, 13-50, 6-23, 0-20, 12-21, 8-38), [](9-37, 10-81, 11-61, 14-57, 8-57, 0-52, 7-74, 6-62, 12-30, 1-52, 2-38, 13-68, 4-54, 3-54, 5-16))).
jobshop(la37, "Lawrence 15x15 instance (Table 10, instance 2); also called (seti2) or (I2)", 15, 15, []([](5-19, 6-64, 11-73, 9-13, 2-84, 14-88, 3-85, 10-41, 12-53, 13-80, 1-66, 7-46, 8-59, 4-25, 0-62), [](1-67, 3-74, 7-41, 2-57, 14-52, 0-14, 9-64, 8-84, 6-78, 5-47, 13-28, 4-84, 10-63, 12-26, 11-46), [](6-97, 8-95, 0-64, 9-38, 10-59, 12-95, 2-17, 11-65, 13-93, 3-10, 5-73, 1-11, 4-85, 14-46, 7-67), [](10-23, 12-49, 3-32, 4-66, 2-43, 0-60, 8-41, 7-61, 13-70, 9-49, 11-17, 6-90, 1-85, 14-99, 5-85), [](9-98, 8-57, 3-73, 6-9, 0-73, 7-7, 1-98, 4-13, 13-41, 5-40, 11-85, 10-37, 2-68, 14-79, 12-17), [](11-66, 7-53, 5-86, 6-40, 0-14, 3-19, 13-96, 4-95, 2-54, 10-84, 12-97, 8-16, 14-52, 1-76, 9-87), [](4-77, 2-55, 9-42, 5-74, 14-91, 13-33, 10-16, 12-54, 0-18, 3-87, 7-60, 8-13, 6-33, 1-33, 11-61), [](6-41, 5-39, 11-82, 9-64, 14-47, 10-28, 7-78, 13-49, 1-79, 4-58, 2-92, 3-79, 12-6, 0-69, 8-76), [](11-21, 5-42, 9-91, 2-28, 0-52, 6-88, 12-76, 13-86, 10-23, 1-35, 7-52, 4-91, 3-47, 14-82, 8-24), [](11-42, 1-93, 3-95, 13-45, 9-28, 14-77, 0-84, 10-8, 7-45, 4-70, 5-37, 6-86, 12-64, 8-67, 2-38), [](4-97, 12-81, 1-58, 7-84, 5-58, 0-9, 11-87, 3-5, 2-44, 13-85, 6-89, 10-77, 9-96, 14-39, 8-77), [](12-80, 1-21, 10-10, 5-73, 8-70, 6-49, 2-31, 13-34, 4-40, 11-22, 0-15, 14-82, 3-57, 9-71, 7-48), [](2-17, 7-62, 5-75, 9-35, 1-91, 14-50, 3-7, 10-64, 13-75, 12-94, 0-55, 6-72, 8-47, 4-11, 11-90), [](11-93, 6-57, 1-71, 12-70, 9-93, 5-20, 3-15, 13-77, 10-58, 0-12, 2-67, 8-68, 14-7, 7-29, 4-52), [](13-76, 3-27, 4-26, 9-36, 11-8, 10-36, 0-95, 8-48, 2-82, 6-87, 5-6, 1-63, 7-56, 12-36, 14-15))).
jobshop(la38, "Lawrence 15x15 instance (Table 10, instance 3); also called (seti3) or (I3)", 15, 15, []([](1-26, 12-67, 0-72, 6-74, 14-13, 8-43, 4-30, 3-19, 10-23, 11-85, 5-98, 13-43, 2-38, 7-8, 9-75), [](14-42, 0-39, 4-55, 12-46, 1-19, 8-93, 9-80, 5-26, 10-7, 6-50, 11-57, 3-73, 2-9, 7-61, 13-72), [](3-96, 4-99, 12-34, 6-60, 7-43, 14-7, 13-12, 8-11, 11-70, 10-43, 0-91, 1-68, 9-11, 5-68, 2-72), [](14-63, 11-45, 4-49, 1-74, 8-27, 0-30, 9-72, 7-9, 12-99, 13-60, 5-69, 6-69, 2-84, 3-40, 10-59), [](2-91, 0-75, 9-98, 3-17, 10-72, 13-31, 11-9, 14-98, 7-50, 5-37, 4-8, 8-65, 1-90, 12-91, 6-71), [](11-35, 6-80, 4-39, 3-62, 14-74, 5-72, 10-35, 9-25, 1-49, 8-52, 7-63, 2-90, 13-21, 12-47, 0-38), [](14-19, 7-57, 10-24, 13-91, 3-50, 0-5, 11-49, 12-18, 9-58, 5-24, 8-52, 1-88, 2-68, 6-20, 4-53), [](7-77, 14-72, 5-35, 11-90, 4-68, 6-18, 3-9, 0-33, 8-60, 10-18, 12-10, 13-60, 1-38, 2-99, 9-15), [](13-6, 8-86, 2-40, 9-79, 12-92, 11-23, 5-89, 10-95, 6-91, 7-72, 0-80, 1-60, 3-56, 4-51, 14-23), [](1-46, 6-28, 5-34, 11-77, 4-47, 0-10, 14-49, 8-77, 10-48, 7-24, 12-8, 2-72, 13-55, 9-29, 3-40), [](10-22, 4-89, 12-79, 0-7, 9-15, 1-6, 11-30, 6-38, 5-11, 8-52, 3-20, 7-5, 14-9, 2-20, 13-28), [](5-73, 14-56, 2-37, 3-22, 13-25, 6-58, 1-8, 7-93, 4-88, 8-17, 12-9, 11-69, 10-71, 9-85, 0-55), [](9-85, 14-58, 3-46, 8-64, 2-49, 6-37, 1-33, 4-30, 5-26, 0-20, 13-74, 10-77, 12-99, 11-56, 7-21), [](10-17, 3-24, 4-89, 5-15, 11-60, 1-42, 8-98, 2-64, 13-92, 0-63, 7-52, 12-54, 6-75, 14-23, 9-38), [](3-8, 5-17, 11-56, 7-93, 14-26, 9-62, 6-7, 10-88, 0-97, 1-7, 2-43, 8-29, 13-35, 12-87, 4-57))).
jobshop(la39, "Lawrence 15x15 instance (Table 10, instance 4); also called (seti4) or (I4)", 15, 15, []([](10-51, 14-43, 7-80, 4-18, 6-38, 3-24, 2-67, 12-15, 11-24, 13-72, 8-45, 5-80, 9-64, 1-44, 0-88), [](6-40, 9-88, 10-77, 5-59, 11-20, 3-52, 8-70, 0-40, 4-32, 13-76, 12-43, 7-31, 2-21, 14-5, 1-47), [](0-32, 3-49, 10-5, 5-64, 7-58, 8-80, 6-94, 11-11, 1-26, 13-26, 14-59, 9-85, 4-47, 12-96, 2-14), [](5-23, 6-9, 0-75, 12-37, 11-43, 2-79, 4-75, 3-34, 7-20, 13-10, 14-83, 10-68, 9-52, 8-66, 1-9), [](12-69, 9-59, 3-28, 14-62, 13-36, 1-26, 6-84, 11-16, 8-54, 5-42, 2-54, 0-6, 10-40, 7-88, 4-79), [](13-78, 12-53, 11-17, 5-29, 4-82, 2-23, 9-12, 8-64, 1-86, 7-59, 6-5, 3-68, 14-59, 10-13, 0-56), [](10-83, 13-46, 9-7, 12-65, 11-69, 6-62, 0-16, 2-58, 8-66, 5-83, 7-90, 14-42, 4-81, 3-69, 1-85), [](7-73, 10-71, 8-64, 6-10, 9-20, 11-99, 4-24, 14-65, 5-82, 3-72, 12-43, 1-82, 13-27, 2-24, 0-33), [](4-82, 1-34, 3-92, 2-8, 0-38, 8-45, 6-21, 5-35, 12-52, 9-35, 11-15, 14-23, 10-6, 13-83, 7-30), [](2-84, 5-7, 9-66, 10-6, 4-28, 13-27, 6-79, 7-70, 0-85, 1-94, 3-60, 14-80, 12-39, 8-66, 11-29), [](3-44, 6-58, 13-14, 8-65, 1-72, 5-14, 12-52, 4-21, 9-25, 0-5, 11-51, 7-61, 14-55, 10-42, 2-36), [](14-43, 10-72, 5-78, 11-12, 12-17, 0-46, 9-27, 6-51, 2-63, 1-79, 8-79, 7-91, 4-49, 13-26, 3-93), [](7-49, 0-49, 4-71, 5-78, 9-44, 10-41, 12-91, 13-84, 8-91, 6-21, 11-47, 14-28, 3-61, 2-70, 1-93), [](3-25, 4-85, 0-66, 2-45, 10-95, 12-21, 8-84, 5-24, 9-53, 7-67, 6-91, 11-11, 13-32, 1-30, 14-89), [](3-92, 7-93, 0-99, 1-40, 10-37, 12-69, 5-66, 6-57, 14-22, 9-44, 8-73, 13-97, 11-18, 2-69, 4-41))).
jobshop(la40, "Lawrence 15x15 instance (Table 10, instance 5); also called (seti5) or (I5)", 15, 15, []([](9-65, 10-28, 4-74, 12-33, 2-51, 14-75, 5-73, 8-32, 6-13, 3-81, 1-35, 7-59, 13-38, 11-55, 0-27), [](0-64, 1-53, 11-83, 2-33, 4-6, 9-52, 14-72, 8-7, 13-90, 12-21, 6-23, 3-10, 10-39, 5-49, 7-72), [](14-73, 3-82, 1-23, 12-62, 6-88, 5-21, 8-65, 11-70, 7-53, 10-81, 2-93, 13-77, 0-61, 9-28, 4-78), [](1-12, 6-51, 7-33, 4-15, 14-72, 10-98, 9-94, 5-12, 11-42, 2-24, 13-15, 8-28, 3-6, 12-99, 0-41), [](12-97, 5-7, 9-96, 4-15, 14-73, 13-43, 0-32, 8-22, 11-42, 1-94, 2-23, 7-86, 6-78, 10-24, 3-31), [](1-72, 5-88, 2-93, 13-13, 4-44, 14-66, 6-63, 7-14, 9-67, 10-17, 11-85, 0-35, 3-68, 12-5, 8-49), [](9-15, 7-82, 6-21, 14-53, 3-72, 13-49, 2-99, 4-26, 12-56, 8-45, 1-68, 10-51, 0-8, 5-27, 11-96), [](3-54, 7-24, 4-14, 8-38, 5-36, 2-52, 14-55, 12-37, 11-48, 0-93, 13-60, 10-70, 1-23, 6-23, 9-83), [](3-12, 8-69, 6-26, 9-23, 14-28, 1-82, 5-33, 4-45, 13-64, 7-15, 11-9, 12-73, 10-59, 2-37, 0-62), [](0-87, 5-12, 7-80, 4-50, 10-48, 12-90, 1-72, 13-24, 6-14, 8-71, 11-44, 9-46, 2-15, 14-61, 3-92), [](2-54, 0-22, 6-61, 4-46, 3-73, 5-16, 12-6, 9-94, 14-93, 13-67, 8-54, 7-75, 11-32, 10-40, 1-97), [](10-92, 14-36, 4-22, 9-9, 3-47, 1-77, 12-79, 13-36, 6-30, 8-98, 11-79, 7-7, 5-55, 2-6, 0-30), [](0-49, 13-83, 3-73, 6-82, 1-82, 14-92, 11-73, 4-31, 10-35, 9-54, 5-7, 8-37, 7-72, 2-52, 12-76), [](10-98, 12-34, 13-52, 4-26, 1-28, 3-39, 8-80, 5-29, 9-70, 0-43, 6-48, 7-58, 2-45, 14-94, 11-96), [](1-70, 10-17, 6-90, 12-67, 4-14, 8-23, 3-21, 7-18, 13-43, 11-84, 5-26, 9-36, 2-93, 14-84, 0-42))).
jobshop(orb01, "trivial 10x10 instance from Bill Cook (BIC2)", 10, 10, []([](0-72, 1-64, 2-55, 3-31, 4-53, 5-95, 6-11, 7-52, 8-6, 9-84), [](0-61, 3-27, 4-88, 2-78, 1-49, 5-83, 8-91, 6-74, 7-29, 9-87), [](0-86, 3-32, 1-35, 2-37, 5-18, 4-48, 6-91, 7-52, 9-60, 8-30), [](0-8, 1-82, 4-27, 3-99, 6-74, 5-9, 2-33, 9-20, 7-59, 8-98), [](1-50, 0-94, 5-43, 3-62, 4-55, 7-48, 2-5, 8-36, 9-47, 6-36), [](0-53, 6-30, 2-7, 3-12, 1-68, 8-87, 4-28, 9-70, 7-45, 5-7), [](2-29, 3-96, 0-99, 1-14, 4-34, 7-14, 5-7, 6-76, 8-57, 9-76), [](2-90, 0-19, 3-87, 4-51, 1-84, 5-45, 9-84, 6-58, 7-81, 8-96), [](2-97, 1-99, 4-93, 0-38, 7-13, 5-96, 3-40, 9-64, 6-32, 8-45), [](2-44, 0-60, 8-29, 3-5, 6-74, 1-85, 4-34, 7-95, 9-51, 5-47))).
jobshop(orb02, "doomed 10x10 instance from Monika (MON2)", 10, 10, []([](0-72, 1-54, 2-33, 3-86, 4-75, 5-16, 6-96, 7-7, 8-99, 9-76), [](0-16, 3-88, 4-48, 8-52, 9-60, 6-29, 7-18, 5-89, 2-80, 1-76), [](0-47, 7-11, 3-14, 2-56, 6-16, 4-83, 1-10, 5-61, 8-24, 9-58), [](0-49, 1-31, 3-17, 8-50, 5-63, 2-35, 4-65, 7-23, 6-50, 9-29), [](0-55, 6-6, 1-28, 3-96, 5-86, 2-99, 9-14, 7-70, 8-64, 4-24), [](4-46, 0-23, 6-70, 8-19, 2-54, 3-22, 9-85, 7-87, 5-79, 1-93), [](4-76, 3-60, 0-76, 9-98, 2-76, 1-50, 8-86, 7-14, 6-27, 5-57), [](4-93, 6-27, 9-57, 3-87, 8-86, 2-54, 7-24, 5-49, 0-20, 1-47), [](2-28, 6-11, 8-78, 7-85, 4-63, 9-81, 3-10, 1-9, 5-46, 0-32), [](2-22, 9-76, 5-89, 8-13, 6-88, 3-10, 7-75, 4-98, 1-78, 0-17))).
jobshop(orb03, "deadlier 10x10 instance from Bruce Gamble (BRG1)", 10, 10, []([](0-96, 1-69, 2-25, 3-5, 4-55, 5-15, 6-88, 7-11, 8-17, 9-82), [](0-11, 1-48, 2-67, 3-38, 4-18, 7-24, 6-62, 5-92, 9-96, 8-81), [](2-67, 1-63, 0-93, 4-85, 3-25, 5-72, 6-51, 7-81, 8-58, 9-15), [](2-30, 1-35, 0-27, 4-82, 3-44, 7-92, 6-25, 5-49, 9-28, 8-77), [](1-53, 0-83, 4-73, 3-26, 2-77, 6-33, 5-92, 9-99, 8-38, 7-38), [](1-20, 0-44, 4-81, 3-88, 2-66, 6-70, 5-91, 9-37, 8-55, 7-96), [](1-21, 2-93, 4-22, 0-56, 3-34, 6-40, 7-53, 9-46, 5-29, 8-63), [](1-32, 2-63, 4-36, 0-26, 3-17, 5-85, 7-15, 8-55, 9-16, 6-82), [](0-73, 2-46, 3-89, 4-24, 1-99, 6-92, 7-7, 9-51, 5-19, 8-14), [](0-52, 2-20, 3-70, 4-98, 1-23, 5-15, 7-81, 8-71, 9-24, 6-81))).
jobshop(orb04, "deadly 10x10 instance from Bruce Shepherd (BRS1)", 10, 10, []([](0-8, 1-10, 2-35, 3-44, 4-15, 5-92, 6-70, 7-89, 8-50, 9-12), [](0-63, 8-39, 3-80, 5-22, 2-88, 1-39, 9-85, 6-27, 7-74, 4-69), [](0-52, 6-22, 1-33, 3-68, 8-27, 2-68, 5-25, 4-34, 7-24, 9-84), [](0-31, 1-85, 4-55, 8-80, 5-58, 7-11, 6-69, 9-56, 3-73, 2-25), [](0-97, 5-98, 9-87, 8-47, 7-77, 4-90, 3-98, 2-80, 1-39, 6-40), [](1-97, 5-68, 0-44, 9-67, 2-44, 8-85, 3-78, 6-90, 7-33, 4-81), [](0-34, 3-76, 8-48, 7-61, 9-11, 2-36, 4-33, 6-98, 1-7, 5-44), [](0-44, 9-5, 4-85, 1-51, 5-58, 7-79, 2-95, 6-48, 3-86, 8-73), [](0-24, 1-63, 9-48, 7-77, 8-73, 6-74, 4-63, 5-17, 2-93, 3-84), [](0-51, 2-5, 4-40, 9-60, 1-46, 5-58, 8-54, 3-72, 6-29, 7-94))).
jobshop(orb05, "10x10 instance from George Steiner (GES1)", 10, 10, []([](9-11, 8-93, 0-48, 7-76, 6-13, 5-71, 3-59, 2-90, 4-10, 1-65), [](8-52, 9-76, 0-84, 7-73, 5-56, 4-10, 6-26, 2-43, 3-39, 1-49), [](9-28, 8-44, 7-26, 6-66, 4-68, 5-74, 3-27, 2-14, 1-6, 0-21), [](0-18, 1-58, 3-62, 2-46, 6-25, 4-6, 5-60, 7-28, 8-80, 9-30), [](0-78, 1-47, 7-29, 5-16, 4-29, 6-57, 3-78, 2-87, 8-39, 9-73), [](9-66, 8-51, 3-12, 7-64, 5-67, 4-15, 6-66, 2-26, 1-20, 0-98), [](8-23, 9-76, 6-45, 7-75, 5-24, 3-18, 4-83, 2-15, 1-88, 0-17), [](9-56, 8-83, 7-80, 6-16, 4-31, 5-93, 3-30, 2-29, 1-66, 0-28), [](9-79, 8-69, 2-82, 4-16, 5-62, 3-41, 6-91, 7-35, 0-34, 1-75), [](0-5, 1-19, 2-20, 3-12, 4-94, 5-60, 6-99, 7-31, 8-96, 9-63))).
jobshop(orb06, "trivial 10X10 instance from Bill Cook (BIC1)", 10, 10, []([](0-99, 1-74, 2-49, 3-67, 4-17, 5-7, 6-9, 7-39, 8-35, 9-49), [](0-49, 3-67, 4-82, 2-92, 1-62, 5-84, 8-45, 6-30, 7-42, 9-71), [](0-26, 3-33, 1-82, 2-98, 5-83, 4-16, 6-64, 7-65, 9-36, 8-77), [](0-41, 1-62, 4-73, 3-94, 6-51, 5-46, 2-55, 9-31, 7-64, 8-46), [](1-68, 0-26, 5-50, 3-46, 4-25, 7-88, 2-6, 8-13, 9-98, 6-84), [](0-24, 6-80, 2-91, 3-55, 1-48, 8-99, 4-72, 9-91, 7-84, 5-12), [](2-16, 3-13, 0-9, 1-58, 4-23, 7-85, 5-36, 6-89, 8-71, 9-41), [](2-54, 0-41, 3-38, 4-53, 1-11, 5-74, 9-88, 6-46, 7-41, 8-65), [](2-53, 1-50, 4-40, 0-90, 7-7, 5-80, 3-57, 9-60, 6-91, 8-47), [](2-45, 0-59, 8-81, 3-99, 6-71, 1-19, 4-75, 7-77, 9-94, 5-95))).
jobshop(orb07, "doomed 10x10 instance from Monika (MON1)", 10, 10, []([](0-32, 1-14, 2-15, 3-37, 4-18, 5-43, 6-19, 7-27, 8-28, 9-31), [](0-8, 3-12, 4-49, 8-24, 9-52, 6-19, 7-23, 5-19, 2-17, 1-32), [](0-25, 7-19, 3-27, 2-45, 6-21, 4-15, 1-13, 5-16, 8-43, 9-19), [](0-24, 1-18, 3-41, 8-29, 5-14, 2-17, 4-23, 7-15, 6-18, 9-23), [](0-27, 6-29, 1-39, 3-21, 5-15, 2-15, 9-25, 7-26, 8-44, 4-20), [](4-17, 0-15, 6-51, 8-17, 2-46, 3-16, 9-33, 7-25, 5-30, 1-25), [](4-15, 3-31, 0-25, 9-12, 2-13, 1-51, 8-19, 7-21, 6-12, 5-26), [](4-8, 6-29, 9-25, 3-15, 8-17, 2-22, 7-32, 5-20, 0-11, 1-28), [](2-41, 6-10, 8-32, 7-5, 4-21, 9-59, 3-26, 1-10, 5-16, 0-29), [](2-20, 9-7, 5-44, 8-22, 6-33, 3-25, 7-29, 4-12, 1-14, 0-0))).
jobshop(orb08, "deadlier 10x10 instance from Bruce Gamble (BRG2)", 10, 10, []([](0-55, 1-74, 2-45, 3-23, 4-76, 5-19, 6-18, 7-61, 8-44, 9-11), [](0-63, 1-43, 2-51, 3-18, 4-42, 7-11, 6-29, 5-52, 9-29, 8-88), [](2-88, 1-31, 0-47, 4-10, 3-62, 5-60, 6-58, 7-29, 8-52, 9-92), [](2-16, 1-71, 0-55, 4-55, 3-9, 7-49, 6-83, 5-54, 9-7, 8-57), [](1-7, 0-41, 4-92, 3-94, 2-46, 6-79, 5-34, 9-38, 8-8, 7-18), [](1-25, 0-5, 4-89, 3-94, 2-14, 6-94, 5-20, 9-23, 8-44, 7-39), [](1-24, 2-21, 4-47, 0-40, 3-94, 6-71, 7-89, 9-75, 5-97, 8-15), [](1-5, 2-7, 4-74, 0-28, 3-72, 5-61, 7-9, 8-53, 9-32, 6-97), [](0-34, 2-52, 3-37, 4-6, 1-94, 6-6, 7-56, 9-41, 5-5, 8-16), [](0-77, 2-74, 3-82, 4-10, 1-29, 5-15, 7-51, 8-65, 9-37, 6-21))).
jobshop(orb09, "deadly 10x10 instance from Bruce Shepherd (BRS2)", 10, 10, []([](0-36, 1-96, 2-86, 3-7, 4-20, 5-9, 6-39, 7-79, 8-82, 9-24), [](0-16, 8-95, 3-67, 5-63, 2-87, 1-24, 9-62, 6-49, 7-92, 4-16), [](0-65, 6-71, 1-9, 3-67, 8-70, 2-48, 5-49, 4-66, 7-5, 9-96), [](0-50, 1-31, 4-6, 8-13, 5-98, 7-97, 6-93, 9-30, 3-34, 2-83), [](0-99, 5-7, 9-55, 8-78, 7-68, 4-81, 3-90, 2-75, 1-66, 6-40), [](1-42, 5-11, 0-5, 9-39, 2-10, 8-30, 3-39, 6-50, 7-20, 4-51), [](0-38, 3-68, 8-86, 7-77, 9-32, 2-89, 4-37, 6-53, 1-43, 5-89), [](0-19, 9-11, 4-37, 1-41, 5-72, 7-7, 2-52, 6-31, 3-68, 8-10), [](0-83, 1-21, 9-23, 7-87, 8-58, 6-89, 4-74, 5-29, 2-74, 3-23), [](0-44, 2-57, 4-69, 9-50, 1-65, 5-69, 8-60, 3-58, 6-89, 7-13))).
jobshop(orb10, "10x10 instance from George Steiner (GES2)", 10, 10, []([](9-66, 8-13, 0-93, 7-91, 6-14, 5-70, 3-99, 2-53, 4-86, 1-16), [](8-34, 9-99, 0-62, 7-65, 5-62, 4-64, 6-21, 2-12, 3-9, 1-75), [](9-12, 8-26, 7-64, 6-92, 4-67, 5-28, 3-66, 2-83, 1-38, 0-58), [](0-77, 1-73, 3-82, 2-75, 6-84, 4-19, 5-18, 7-89, 8-8, 9-73), [](0-34, 1-74, 7-48, 5-44, 4-92, 6-40, 3-60, 2-62, 8-22, 9-67), [](9-8, 8-85, 3-58, 7-97, 5-92, 4-89, 6-75, 2-77, 1-95, 0-5), [](8-52, 9-43, 6-5, 7-78, 5-12, 3-62, 4-21, 2-80, 1-60, 0-31), [](9-81, 8-23, 7-23, 6-75, 4-78, 5-56, 3-51, 2-39, 1-53, 0-96), [](9-79, 8-55, 2-88, 4-21, 5-83, 3-93, 6-47, 7-10, 0-63, 1-14), [](0-43, 1-63, 2-83, 3-29, 4-52, 5-98, 6-54, 7-39, 8-33, 9-23))).
jobshop(swv01, "Storer, Wu, and Vaccari hard 20x10 instance (Table 2, instance 1)", 20, 10, []([](3-19, 2-27, 1-39, 4-13, 0-25, 8-37, 9-40, 5-54, 7-74, 6-93), [](2-69, 0-30, 4-1, 3-4, 1-64, 7-71, 5-2, 9-84, 6-31, 8-8), [](4-79, 3-80, 0-86, 2-55, 1-54, 8-81, 6-72, 7-86, 5-59, 9-75), [](2-76, 3-15, 1-26, 0-17, 4-30, 8-44, 7-91, 6-83, 5-52, 9-68), [](4-73, 3-87, 1-74, 0-39, 2-98, 9-100, 5-43, 8-17, 7-7, 6-77), [](1-63, 0-49, 2-16, 3-55, 4-9, 9-73, 5-61, 8-34, 6-82, 7-46), [](0-87, 1-71, 4-43, 3-80, 2-39, 7-70, 8-18, 6-41, 9-79, 5-44), [](4-70, 2-22, 0-73, 3-62, 1-64, 5-25, 8-19, 6-69, 9-41, 7-28), [](3-16, 0-84, 1-58, 4-7, 2-9, 5-8, 6-10, 7-17, 8-42, 9-65), [](3-8, 0-10, 1-3, 4-41, 2-3, 7-40, 8-56, 5-53, 9-96, 6-13), [](4-62, 1-60, 3-64, 2-12, 0-39, 5-2, 7-64, 6-87, 9-21, 8-60), [](2-66, 1-71, 3-23, 4-75, 0-78, 7-74, 6-35, 9-24, 8-23, 5-50), [](1-5, 3-92, 4-6, 0-69, 2-80, 7-13, 5-17, 9-89, 6-80, 8-47), [](0-82, 3-84, 1-24, 2-47, 4-93, 7-85, 5-34, 6-73, 8-28, 9-91), [](4-55, 0-57, 3-63, 2-24, 1-40, 7-30, 6-37, 5-99, 8-88, 9-41), [](1-75, 2-47, 3-68, 0-7, 4-78, 7-80, 6-2, 9-23, 8-49, 5-50), [](0-91, 4-25, 2-10, 1-21, 3-94, 8-6, 7-59, 5-84, 9-75, 6-70), [](2-85, 1-31, 0-94, 4-94, 3-11, 5-21, 9-7, 6-61, 8-50, 7-93), [](1-27, 0-77, 4-13, 2-30, 3-2, 5-88, 7-4, 9-39, 6-53, 8-54), [](1-34, 2-12, 3-31, 0-24, 4-24, 7-16, 5-6, 9-88, 8-81, 6-11))).
jobshop(swv02, "Storer, Wu, and Vaccari hard 20x10 instance (Table 2, instance 2)", 20, 10, []([](2-16, 1-58, 0-22, 4-24, 3-53, 8-9, 9-57, 7-63, 5-92, 6-43), [](3-6, 1-48, 4-14, 0-66, 2-24, 7-2, 9-85, 6-73, 8-19, 5-99), [](4-100, 2-90, 0-63, 1-14, 3-31, 5-27, 9-15, 8-1, 6-51, 7-33), [](2-98, 3-84, 4-52, 0-12, 1-96, 9-60, 6-74, 8-93, 5-45, 7-49), [](4-39, 0-54, 2-28, 3-8, 1-30, 8-57, 6-75, 5-9, 7-41, 9-19), [](3-94, 0-8, 2-89, 1-13, 4-37, 8-36, 6-63, 9-24, 5-71, 7-97), [](3-90, 2-69, 1-25, 4-15, 0-65, 7-52, 6-56, 9-91, 8-83, 5-86), [](3-59, 1-99, 4-41, 0-68, 2-14, 7-4, 9-55, 6-48, 8-13, 5-15), [](4-36, 2-17, 1-51, 0-16, 3-54, 8-45, 5-50, 7-98, 6-68, 9-82), [](1-75, 0-11, 4-55, 2-93, 3-51, 6-61, 9-40, 7-19, 8-24, 5-55), [](4-56, 0-73, 3-59, 2-38, 1-51, 6-99, 8-29, 9-53, 5-7, 7-72), [](3-68, 4-50, 1-88, 2-88, 0-33, 5-47, 8-52, 6-26, 9-74, 7-68), [](2-3, 3-42, 0-45, 1-57, 4-28, 5-14, 8-22, 9-31, 6-44, 7-38), [](3-89, 0-73, 4-12, 1-9, 2-49, 5-11, 8-15, 7-41, 9-37, 6-10), [](3-76, 2-97, 4-100, 1-92, 0-25, 5-8, 9-92, 7-51, 6-58, 8-65), [](4-50, 0-54, 3-85, 1-47, 2-45, 6-99, 9-39, 5-32, 8-87, 7-56), [](0-70, 2-58, 3-33, 1-85, 4-25, 8-5, 7-65, 9-20, 6-52, 5-44), [](1-22, 3-45, 4-60, 0-66, 2-5, 7-61, 6-73, 9-60, 5-14, 8-44), [](4-64, 0-97, 2-31, 1-4, 3-43, 9-47, 7-93, 6-100, 5-10, 8-51), [](3-9, 4-87, 2-34, 0-62, 1-56, 5-66, 8-95, 7-56, 9-42, 6-86))).
jobshop(swv03, "Storer, Wu, and Vaccari hard 20x10 instance (Table 2, instance 3)", 20, 10, []([](2-19, 0-30, 1-68, 4-55, 3-24, 8-34, 7-72, 5-32, 9-62, 6-45), [](2-63, 1-11, 4-65, 3-16, 0-67, 9-95, 8-23, 7-82, 6-52, 5-53), [](2-19, 4-17, 1-79, 3-49, 0-12, 7-41, 9-67, 8-40, 6-25, 5-42), [](0-42, 2-71, 3-27, 4-95, 1-19, 5-48, 8-100, 6-31, 7-25, 9-38), [](3-1, 1-100, 4-68, 0-94, 2-89, 5-86, 7-35, 9-29, 8-56, 6-55), [](4-93, 1-53, 2-4, 3-48, 0-57, 8-99, 7-67, 5-86, 6-80, 9-60), [](4-82, 1-95, 2-12, 0-60, 3-80, 8-88, 7-5, 6-81, 9-52, 5-69), [](3-79, 1-31, 4-63, 0-28, 2-64, 8-63, 5-29, 7-75, 9-18, 6-33), [](4-9, 1-64, 2-31, 0-13, 3-33, 9-82, 6-79, 5-30, 7-84, 8-20), [](2-14, 0-56, 1-95, 4-34, 3-13, 6-16, 5-44, 7-45, 8-62, 9-86), [](4-66, 3-9, 2-66, 1-46, 0-12, 5-10, 7-58, 6-6, 8-62, 9-17), [](4-89, 1-52, 2-37, 3-74, 0-7, 8-43, 5-96, 7-89, 6-21, 9-66), [](1-73, 3-68, 2-5, 4-49, 0-67, 9-23, 7-7, 5-44, 8-30, 6-29), [](2-21, 0-68, 1-88, 4-75, 3-64, 6-6, 8-72, 7-66, 9-66, 5-56), [](1-24, 4-25, 2-69, 0-27, 3-51, 9-60, 8-26, 6-45, 5-77, 7-93), [](2-19, 3-17, 1-82, 4-75, 0-34, 5-67, 9-89, 6-91, 7-13, 8-35), [](4-2, 0-21, 3-83, 1-19, 2-65, 6-65, 8-8, 9-68, 7-60, 5-7), [](1-63, 3-49, 2-4, 4-2, 0-50, 9-99, 5-27, 6-68, 8-46, 7-89), [](0-48, 4-45, 3-100, 2-66, 1-30, 6-58, 7-73, 9-94, 5-36, 8-5), [](2-36, 0-53, 4-56, 3-57, 1-77, 9-7, 6-59, 8-8, 5-15, 7-23))).
jobshop(swv04, "Storer, Wu, and Vaccari hard 20x10 instance (Table 2, instance 4)", 20, 10, []([](2-16, 0-59, 4-10, 3-95, 1-64, 8-92, 9-56, 7-3, 5-73, 6-17), [](1-5, 4-64, 3-30, 2-14, 0-96, 9-11, 8-73, 7-35, 6-93, 5-12), [](3-35, 4-75, 0-54, 1-30, 2-83, 9-20, 8-29, 7-38, 6-90, 5-39), [](4-29, 3-21, 0-52, 2-93, 1-20, 5-5, 7-11, 8-53, 9-56, 6-98), [](0-17, 3-16, 4-41, 1-78, 2-100, 5-55, 8-27, 6-2, 7-87, 9-55), [](3-97, 1-32, 4-84, 2-71, 0-38, 9-64, 7-16, 5-5, 6-41, 8-41), [](3-41, 1-57, 4-37, 0-64, 2-92, 6-19, 9-47, 7-94, 8-79, 5-21), [](0-23, 3-67, 1-39, 4-98, 2-63, 8-83, 5-45, 6-89, 9-81, 7-44), [](1-88, 0-59, 3-39, 2-63, 4-91, 8-36, 5-44, 6-45, 9-43, 7-12), [](2-29, 1-17, 0-6, 3-74, 4-51, 9-14, 6-2, 5-56, 7-49, 8-14), [](3-75, 2-10, 4-1, 0-35, 1-99, 7-56, 5-95, 9-78, 6-53, 8-82), [](0-75, 2-96, 1-21, 3-90, 4-55, 6-23, 7-40, 9-76, 8-55, 5-45), [](3-90, 4-64, 0-72, 2-33, 1-59, 7-51, 6-74, 5-85, 9-76, 8-38), [](3-57, 1-84, 2-87, 4-2, 0-68, 8-4, 5-77, 6-37, 7-37, 9-94), [](1-16, 3-46, 4-34, 2-23, 0-77, 7-68, 8-14, 9-54, 5-37, 6-99), [](4-24, 1-73, 2-92, 0-43, 3-42, 5-81, 7-99, 8-88, 9-80, 6-5), [](1-56, 2-51, 0-3, 4-87, 3-25, 5-62, 7-11, 8-88, 6-68, 9-29), [](2-85, 3-3, 4-21, 0-49, 1-79, 8-38, 5-37, 9-72, 7-18, 6-18), [](0-2, 3-55, 1-31, 2-29, 4-98, 5-92, 6-43, 8-99, 7-67, 9-41), [](4-69, 3-64, 0-61, 1-13, 2-31, 5-6, 8-84, 9-94, 7-32, 6-54))).
jobshop(swv05, "Storer, Wu, and Vaccari hard 20x10 instance (Table 2, instance 5)", 20, 10, []([](2-19, 1-30, 3-80, 0-84, 4-14, 8-51, 5-73, 6-91, 7-81, 9-71), [](2-74, 4-79, 1-39, 0-7, 3-66, 9-6, 5-93, 8-76, 6-21, 7-76), [](4-90, 3-33, 1-38, 2-73, 0-61, 8-61, 7-76, 5-86, 9-28, 6-35), [](4-1, 3-22, 2-1, 0-77, 1-33, 6-98, 5-4, 9-27, 8-8, 7-68), [](2-63, 4-5, 1-95, 0-7, 3-50, 8-46, 9-28, 6-70, 5-60, 7-34), [](0-98, 1-73, 4-15, 3-21, 2-32, 7-24, 9-9, 8-24, 5-7, 6-34), [](3-51, 4-47, 2-30, 1-16, 0-51, 5-41, 6-79, 7-79, 9-3, 8-72), [](4-3, 1-59, 0-53, 3-20, 2-19, 6-20, 9-16, 7-90, 5-96, 8-18), [](1-34, 2-55, 3-97, 0-93, 4-90, 7-81, 5-63, 8-41, 6-1, 9-51), [](4-77, 3-87, 1-92, 2-83, 0-45, 7-75, 9-60, 6-75, 5-93, 8-33), [](0-31, 2-66, 1-58, 4-17, 3-94, 5-63, 7-80, 9-61, 6-78, 8-52), [](4-70, 1-25, 2-75, 0-89, 3-41, 7-100, 5-73, 6-28, 8-94, 9-88), [](1-67, 4-62, 3-12, 2-55, 0-62, 5-58, 8-66, 7-73, 6-55, 9-1), [](4-81, 0-37, 1-2, 3-39, 2-17, 7-74, 6-71, 8-61, 5-42, 9-5), [](3-62, 0-31, 4-63, 2-31, 1-5, 9-7, 7-77, 8-34, 6-34, 5-3), [](0-5, 2-55, 3-62, 1-82, 4-80, 6-6, 8-7, 7-29, 5-80, 9-89), [](3-26, 1-50, 2-58, 0-22, 4-68, 7-12, 6-9, 9-34, 5-90, 8-87), [](0-50, 2-28, 1-64, 4-34, 3-63, 7-9, 9-48, 6-63, 8-61, 5-2), [](0-47, 2-23, 1-23, 4-82, 3-98, 7-66, 6-78, 8-100, 9-79, 5-32), [](1-13, 4-14, 0-90, 2-77, 3-80, 9-30, 7-31, 5-36, 6-51, 8-69))).
jobshop(swv06, "Storer, Wu, and Vaccari hard 20x15 instance (Table 2, instance 6)", 20, 15, []([](1-16, 6-58, 2-22, 4-24, 5-53, 3-9, 0-57, 10-63, 8-92, 12-43, 7-41, 13-26, 14-20, 9-44, 11-93), [](2-89, 1-94, 0-86, 3-13, 6-54, 4-41, 5-55, 7-98, 13-38, 14-80, 9-1, 11-100, 12-90, 10-63, 8-14), [](1-26, 6-96, 3-32, 4-75, 5-9, 0-57, 2-39, 12-54, 14-28, 10-8, 11-30, 13-57, 9-75, 7-9, 8-41), [](3-37, 2-36, 5-63, 0-24, 6-71, 1-97, 4-74, 14-19, 12-45, 8-24, 11-71, 13-53, 10-61, 9-6, 7-32), [](3-57, 0-55, 1-21, 5-84, 2-23, 6-79, 4-90, 11-8, 14-59, 10-99, 9-41, 12-68, 8-14, 13-4, 7-55), [](4-10, 2-81, 1-13, 3-78, 0-78, 5-10, 6-48, 9-37, 11-21, 7-88, 12-75, 14-11, 13-55, 10-93, 8-51), [](6-100, 2-52, 3-54, 1-37, 5-26, 4-74, 0-87, 8-13, 12-88, 10-94, 14-73, 7-55, 11-68, 9-50, 13-88), [](4-47, 5-70, 6-7, 2-72, 0-62, 3-30, 1-95, 10-18, 9-65, 7-69, 13-89, 8-89, 14-64, 12-81, 11-25), [](6-1, 1-10, 0-72, 3-59, 4-92, 5-53, 2-89, 14-52, 7-48, 8-8, 13-69, 10-49, 9-26, 12-76, 11-97), [](6-85, 2-47, 4-45, 1-99, 0-39, 5-32, 3-87, 10-56, 8-98, 11-13, 7-96, 12-71, 14-95, 9-11, 13-78), [](0-17, 2-21, 3-87, 6-41, 5-41, 4-31, 1-96, 8-17, 11-95, 13-29, 14-3, 10-71, 7-64, 9-97, 12-31), [](6-9, 0-87, 4-34, 1-62, 3-56, 5-66, 2-95, 9-56, 14-42, 8-86, 7-68, 12-82, 10-82, 13-52, 11-97), [](3-86, 1-37, 2-49, 0-2, 6-30, 5-63, 4-4, 14-47, 8-84, 10-5, 13-13, 9-39, 12-18, 7-76, 11-63), [](0-29, 6-34, 1-53, 3-7, 5-19, 4-26, 2-63, 12-22, 10-98, 13-77, 14-11, 7-87, 9-5, 11-44, 8-42), [](6-44, 4-91, 1-91, 2-58, 0-77, 3-51, 5-14, 13-1, 9-17, 7-55, 12-40, 8-95, 14-31, 11-54, 10-37), [](5-59, 4-47, 1-56, 6-39, 2-7, 0-43, 3-39, 13-75, 10-43, 12-32, 9-6, 11-93, 7-69, 8-47, 14-93), [](4-24, 1-30, 3-97, 6-17, 0-7, 2-55, 5-8, 7-70, 10-87, 8-29, 12-20, 13-29, 11-51, 9-14, 14-32), [](2-29, 4-99, 3-17, 0-96, 1-50, 5-67, 6-91, 10-91, 13-14, 12-14, 7-19, 8-36, 11-11, 14-83, 9-6), [](0-7, 6-60, 3-31, 5-76, 1-23, 2-83, 4-30, 8-73, 14-76, 11-17, 10-53, 13-9, 12-72, 7-89, 9-24), [](3-63, 0-89, 2-2, 1-46, 6-86, 5-74, 4-1, 7-34, 9-30, 12-19, 13-48, 11-75, 8-72, 14-47, 10-58))).
jobshop(swv07, "Storer, Wu, and Vaccari hard 20x15 instance (Table 2, instance 7)", 20, 15, []([](3-92, 1-49, 2-93, 6-48, 0-1, 4-52, 5-57, 8-16, 12-6, 13-6, 11-19, 9-96, 7-27, 14-76, 10-60), [](5-4, 3-96, 6-52, 1-87, 2-94, 4-83, 0-9, 11-85, 10-47, 8-63, 9-31, 13-26, 12-46, 7-49, 14-48), [](1-34, 6-34, 4-37, 2-82, 0-25, 5-43, 3-11, 9-71, 14-55, 7-34, 11-77, 12-20, 8-89, 10-23, 13-32), [](3-49, 5-12, 6-52, 2-76, 0-64, 1-51, 4-84, 10-42, 12-5, 7-45, 8-20, 11-93, 14-48, 13-75, 9-100), [](2-35, 1-1, 3-15, 6-49, 5-78, 4-80, 0-99, 9-88, 7-24, 11-20, 10-100, 8-28, 14-71, 13-1, 12-7), [](3-69, 6-24, 5-21, 4-3, 1-28, 2-8, 0-42, 10-33, 11-40, 9-50, 8-8, 13-5, 12-13, 7-42, 14-73), [](0-83, 4-15, 2-62, 6-27, 5-5, 1-65, 3-100, 14-65, 10-82, 7-89, 13-81, 9-92, 8-38, 11-47, 12-96), [](6-98, 4-24, 2-75, 0-57, 1-93, 3-74, 5-10, 7-44, 13-59, 11-51, 12-82, 14-65, 10-8, 8-12, 9-24), [](4-55, 0-44, 3-47, 5-75, 2-81, 6-30, 1-42, 10-100, 8-81, 7-29, 13-31, 9-47, 11-34, 12-77, 14-92), [](2-18, 5-42, 0-37, 4-1, 3-67, 6-20, 1-91, 8-21, 14-57, 12-100, 10-100, 11-59, 13-77, 9-21, 7-98), [](3-42, 1-16, 4-19, 6-70, 2-7, 0-74, 5-7, 12-50, 9-74, 8-46, 14-88, 13-71, 10-42, 7-34, 11-60), [](6-12, 4-45, 2-7, 0-15, 1-22, 3-31, 5-70, 13-88, 9-46, 8-44, 14-45, 12-87, 11-5, 7-99, 10-70), [](4-51, 5-39, 0-50, 2-9, 3-23, 6-28, 1-49, 13-5, 12-17, 14-40, 10-30, 11-62, 8-65, 7-84, 9-12), [](6-92, 0-67, 5-85, 1-88, 3-18, 4-13, 2-70, 7-69, 14-10, 13-52, 8-42, 11-82, 10-19, 12-21, 9-5), [](4-34, 0-60, 1-52, 5-70, 2-51, 6-2, 3-43, 10-75, 11-45, 8-53, 12-96, 13-1, 14-44, 7-66, 9-19), [](6-31, 1-44, 0-84, 3-16, 4-10, 2-4, 5-48, 13-67, 14-11, 12-21, 8-78, 7-42, 11-44, 9-37, 10-35), [](1-20, 4-40, 3-37, 2-68, 6-42, 0-11, 5-6, 10-44, 11-43, 12-17, 14-3, 7-77, 13-100, 9-82, 8-5), [](5-14, 0-5, 3-40, 1-70, 4-63, 2-59, 6-42, 9-74, 13-32, 7-50, 10-21, 14-29, 12-83, 11-64, 8-45), [](6-70, 0-28, 3-79, 4-25, 5-98, 2-24, 1-54, 12-65, 13-93, 10-74, 7-22, 9-73, 11-75, 8-69, 14-9), [](5-100, 2-46, 4-69, 3-41, 1-3, 6-18, 0-41, 8-94, 11-97, 12-30, 14-96, 7-7, 9-86, 13-83, 10-90))).
jobshop(swv08, "Storer, Wu, and Vaccari hard 20x15 instance (Table 2, instance 8)", 20, 15, []([](3-8, 4-73, 2-49, 5-24, 6-81, 1-68, 0-23, 12-69, 8-74, 10-45, 11-4, 14-59, 9-25, 7-70, 13-68), [](3-34, 2-33, 5-7, 1-69, 4-54, 6-18, 0-38, 8-28, 12-12, 14-50, 10-66, 7-81, 9-81, 13-91, 11-66), [](0-8, 6-20, 3-52, 4-83, 5-18, 2-82, 1-68, 7-50, 14-54, 11-6, 10-73, 13-48, 9-20, 8-93, 12-99), [](2-41, 0-72, 1-91, 4-52, 5-30, 3-1, 6-92, 13-52, 8-41, 9-45, 14-43, 12-97, 10-64, 11-71, 7-76), [](0-48, 1-44, 5-49, 6-92, 3-29, 2-29, 4-88, 14-14, 10-99, 8-22, 13-79, 9-93, 12-69, 11-63, 7-68), [](0-56, 6-42, 2-42, 3-93, 1-80, 4-54, 5-94, 12-80, 14-69, 11-39, 8-85, 10-95, 13-12, 9-28, 7-64), [](0-90, 4-75, 6-9, 1-46, 2-91, 3-93, 5-93, 14-77, 9-63, 11-50, 12-82, 13-74, 8-67, 7-72, 10-76), [](0-55, 2-90, 6-11, 3-60, 4-75, 1-23, 5-74, 11-54, 7-97, 12-32, 13-67, 10-15, 14-48, 8-100, 9-55), [](6-71, 5-64, 2-40, 0-32, 3-92, 1-59, 4-69, 13-68, 14-34, 12-71, 8-28, 9-94, 7-82, 10-1, 11-58), [](6-36, 4-46, 1-50, 5-87, 3-33, 2-94, 0-3, 14-60, 11-45, 13-84, 9-1, 8-38, 10-22, 12-39, 7-50), [](1-53, 0-34, 5-56, 6-97, 3-95, 4-32, 2-28, 14-48, 7-54, 12-98, 8-84, 9-77, 10-46, 13-65, 11-94), [](2-1, 5-97, 0-77, 4-82, 6-14, 1-18, 3-74, 14-52, 11-14, 12-93, 9-35, 8-34, 13-84, 10-6, 7-81), [](1-62, 0-86, 2-57, 6-80, 5-37, 3-94, 4-77, 7-72, 9-26, 11-41, 10-7, 8-56, 13-98, 14-67, 12-47), [](5-45, 3-30, 0-57, 6-68, 1-61, 2-34, 4-2, 7-57, 13-96, 9-10, 12-85, 14-42, 10-93, 8-89, 11-43), [](6-49, 4-53, 1-51, 2-4, 0-17, 5-21, 3-31, 10-45, 13-45, 9-63, 11-21, 8-4, 7-23, 14-90, 12-1), [](6-68, 5-18, 0-87, 3-6, 4-13, 2-9, 1-40, 8-83, 7-95, 12-27, 10-94, 14-68, 11-22, 13-28, 9-66), [](2-80, 6-14, 0-67, 5-15, 1-14, 3-97, 4-23, 8-45, 10-1, 11-5, 14-87, 7-34, 12-12, 9-98, 13-35), [](4-33, 2-20, 3-74, 6-20, 5-3, 0-90, 1-37, 13-56, 12-38, 8-7, 14-84, 9-100, 11-41, 10-6, 7-97), [](6-47, 4-63, 3-1, 0-28, 2-99, 1-41, 5-45, 14-60, 13-2, 7-25, 8-59, 9-39, 10-76, 11-89, 12-5), [](6-67, 2-46, 3-25, 1-2, 5-22, 4-8, 0-22, 13-64, 7-82, 12-99, 11-79, 10-87, 8-71, 9-24, 14-19))).
jobshop(swv09, "Storer, Wu, and Vaccari hard 20x15 instance (Table 2, instance 9)", 20, 15, []([](5-8, 3-73, 0-69, 2-38, 6-6, 4-62, 1-78, 9-79, 8-59, 13-77, 11-22, 10-80, 12-58, 14-49, 7-48), [](3-34, 4-29, 2-69, 0-5, 5-63, 1-82, 6-94, 14-17, 11-94, 9-29, 10-5, 13-75, 7-15, 8-61, 12-61), [](1-52, 2-30, 0-25, 6-17, 3-46, 4-86, 5-3, 14-70, 11-34, 9-23, 10-68, 13-76, 8-53, 12-71, 7-9), [](2-50, 4-20, 3-24, 0-53, 1-97, 5-79, 6-92, 14-3, 12-52, 10-75, 9-74, 8-59, 7-75, 13-84, 11-99), [](2-15, 0-61, 3-47, 4-38, 6-49, 5-21, 1-6, 11-8, 8-71, 14-83, 13-24, 12-18, 9-33, 7-70, 10-100), [](4-48, 5-50, 2-66, 0-92, 6-2, 3-58, 1-23, 9-84, 8-66, 10-12, 7-36, 14-4, 12-88, 13-64, 11-12), [](3-29, 0-25, 6-44, 5-87, 2-42, 1-44, 4-86, 8-28, 10-86, 9-74, 14-77, 13-59, 12-94, 7-58, 11-16), [](4-31, 3-58, 0-94, 5-69, 2-44, 1-93, 6-92, 9-80, 8-63, 12-47, 13-3, 7-79, 11-39, 14-80, 10-75), [](1-69, 2-27, 0-76, 5-19, 6-86, 3-16, 4-31, 12-33, 9-69, 13-19, 10-43, 14-9, 11-37, 7-35, 8-24), [](2-75, 3-78, 6-41, 4-60, 5-59, 0-42, 1-60, 12-18, 8-31, 10-15, 7-54, 14-60, 9-20, 11-61, 13-69), [](4-89, 6-20, 1-27, 5-78, 3-2, 2-21, 0-55, 13-79, 11-77, 10-99, 9-70, 12-30, 7-97, 8-41, 14-98), [](6-1, 2-10, 4-84, 5-72, 0-14, 1-9, 3-51, 7-22, 14-65, 10-100, 13-65, 11-43, 8-10, 12-14, 9-19), [](5-50, 2-13, 3-49, 6-75, 1-42, 0-81, 4-89, 9-100, 14-54, 13-37, 10-7, 11-38, 8-25, 12-78, 7-79), [](2-44, 3-77, 5-26, 1-42, 4-9, 6-73, 0-60, 9-61, 10-85, 12-14, 11-92, 7-100, 14-49, 8-46, 13-12), [](2-72, 0-53, 1-43, 5-65, 6-59, 4-87, 3-13, 8-71, 12-25, 9-71, 10-89, 11-2, 7-76, 14-21, 13-12), [](2-60, 6-28, 5-33, 1-36, 0-6, 3-96, 4-48, 9-40, 11-79, 10-60, 8-39, 13-34, 7-54, 12-20, 14-52), [](5-82, 2-12, 3-11, 4-61, 1-21, 0-21, 6-34, 12-86, 14-53, 8-7, 9-4, 7-95, 10-62, 13-54, 11-82), [](5-72, 0-13, 3-46, 6-97, 1-87, 4-87, 2-11, 7-45, 14-85, 11-66, 8-43, 9-39, 13-34, 10-30, 12-55), [](1-39, 5-19, 0-19, 4-73, 6-63, 3-30, 2-69, 9-36, 7-13, 10-96, 12-27, 13-59, 14-76, 11-62, 8-14), [](1-7, 4-14, 3-79, 2-27, 6-43, 0-96, 5-24, 11-30, 7-27, 12-2, 8-69, 14-75, 13-34, 10-79, 9-96))).
jobshop(swv10, "Storer, Wu, and Vaccari hard 20x15 instance (Table 2, instance 10)", 20, 15, []([](3-8, 2-73, 1-79, 0-95, 6-69, 4-9, 5-5, 8-85, 9-52, 11-43, 14-32, 7-91, 10-24, 13-89, 12-38), [](6-45, 1-70, 4-84, 3-24, 5-18, 0-20, 2-71, 8-21, 7-60, 9-98, 10-70, 13-52, 12-34, 11-23, 14-52), [](6-16, 4-68, 1-85, 0-39, 5-40, 2-98, 3-61, 10-77, 7-60, 11-73, 9-66, 14-84, 8-16, 13-43, 12-88), [](0-72, 1-17, 3-68, 4-89, 2-94, 6-98, 5-56, 10-88, 13-27, 9-60, 12-61, 8-8, 7-88, 11-48, 14-65), [](6-78, 2-24, 5-28, 0-73, 4-21, 1-69, 3-52, 14-32, 8-83, 11-48, 10-29, 13-48, 12-92, 9-43, 7-82), [](4-54, 6-31, 5-14, 3-47, 0-82, 1-75, 2-4, 8-31, 12-72, 7-58, 9-45, 13-91, 14-31, 11-61, 10-27), [](4-88, 1-28, 5-92, 6-62, 3-93, 0-14, 2-65, 7-33, 9-44, 8-31, 14-32, 11-72, 13-47, 12-61, 10-34), [](0-52, 1-59, 5-98, 3-6, 2-19, 6-53, 4-39, 8-74, 12-48, 10-33, 13-49, 11-92, 7-22, 14-41, 9-37), [](0-2, 6-85, 3-34, 2-51, 4-97, 5-95, 1-73, 14-61, 9-28, 12-73, 8-21, 11-85, 7-75, 13-42, 10-7), [](5-94, 1-28, 0-77, 2-56, 6-79, 4-2, 3-82, 9-88, 10-93, 12-44, 14-5, 8-96, 7-34, 13-56, 11-41), [](2-15, 5-88, 6-18, 3-14, 1-82, 0-58, 4-33, 13-19, 10-42, 9-36, 14-57, 12-85, 7-3, 11-62, 8-36), [](3-30, 6-33, 0-13, 4-4, 2-74, 1-37, 5-78, 14-2, 13-56, 9-21, 10-61, 11-81, 7-18, 8-59, 12-62), [](5-40, 1-75, 6-45, 0-41, 3-97, 2-65, 4-92, 7-11, 12-44, 8-40, 9-100, 11-91, 14-66, 13-53, 10-27), [](1-83, 2-52, 0-84, 3-66, 5-3, 6-5, 4-71, 13-41, 10-42, 11-63, 12-50, 14-43, 8-3, 9-35, 7-18), [](4-44, 0-26, 1-59, 6-81, 2-84, 5-81, 3-91, 13-41, 7-42, 11-53, 8-63, 14-89, 9-15, 10-64, 12-40), [](1-46, 0-97, 5-67, 4-97, 3-71, 6-88, 2-69, 14-44, 12-20, 11-52, 13-34, 10-74, 8-79, 7-10, 9-87), [](3-71, 6-13, 4-100, 2-67, 1-57, 5-24, 0-36, 7-88, 14-79, 8-21, 9-86, 12-60, 11-28, 10-14, 13-3), [](0-97, 6-24, 2-41, 4-40, 1-51, 5-73, 3-19, 9-27, 12-70, 13-98, 10-11, 11-83, 7-76, 8-60, 14-12), [](5-88, 3-48, 1-33, 4-96, 6-10, 0-49, 2-52, 10-38, 13-49, 7-31, 12-94, 14-23, 9-7, 11-5, 8-4), [](2-85, 0-100, 5-51, 6-91, 1-21, 3-83, 4-30, 12-23, 9-48, 8-19, 11-47, 10-95, 7-23, 14-78, 13-22))).
jobshop(swv11, "Storer, Wu, and Vaccari hard 50x10 instance (Table 2, instance 11)", 50, 10, []([](0-92, 4-47, 3-56, 2-91, 1-49, 5-39, 9-63, 7-12, 6-1, 8-37), [](0-86, 2-100, 1-75, 3-92, 4-90, 5-11, 7-85, 8-54, 9-100, 6-38), [](1-4, 4-94, 3-44, 2-40, 0-92, 8-53, 6-40, 9-5, 5-68, 7-27), [](4-87, 0-48, 1-59, 2-92, 3-35, 6-99, 7-46, 9-27, 8-83, 5-91), [](0-83, 1-78, 4-76, 3-64, 2-44, 8-12, 9-91, 6-31, 7-98, 5-63), [](3-49, 0-15, 1-100, 4-18, 2-24, 6-92, 9-65, 5-26, 7-29, 8-24), [](0-28, 3-53, 4-84, 2-47, 1-85, 7-100, 5-34, 6-35, 8-90, 9-88), [](2-61, 4-71, 3-54, 1-34, 0-13, 9-47, 8-2, 6-97, 7-27, 5-97), [](0-85, 2-75, 1-33, 4-72, 3-49, 7-23, 5-12, 8-90, 6-87, 9-42), [](2-24, 3-20, 1-65, 4-33, 0-75, 9-47, 6-84, 8-44, 7-74, 5-29), [](2-48, 3-27, 4-1, 0-23, 1-66, 6-35, 7-46, 9-29, 5-63, 8-44), [](2-79, 0-4, 4-61, 3-46, 1-69, 7-10, 8-88, 9-19, 6-50, 5-34), [](0-16, 4-31, 3-77, 2-3, 1-25, 8-88, 7-97, 9-49, 6-79, 5-22), [](1-40, 0-39, 4-15, 2-93, 3-48, 6-63, 9-74, 8-46, 7-91, 5-51), [](4-48, 0-93, 2-8, 3-50, 1-5, 6-48, 7-46, 9-35, 5-88, 8-97), [](3-70, 1-8, 2-65, 0-32, 4-84, 8-9, 6-43, 7-10, 5-72, 9-60), [](0-21, 2-28, 1-26, 3-91, 4-58, 9-90, 6-43, 8-64, 5-39, 7-93), [](1-50, 2-60, 0-51, 4-90, 3-93, 7-20, 9-33, 8-27, 6-12, 5-89), [](1-21, 3-3, 2-47, 4-34, 0-53, 9-67, 8-8, 5-68, 7-1, 6-71), [](3-57, 4-26, 2-36, 0-48, 1-11, 9-44, 7-25, 5-30, 8-92, 6-57), [](1-20, 0-20, 4-6, 3-74, 2-48, 9-77, 8-15, 5-80, 7-27, 6-10), [](3-71, 1-40, 0-86, 2-23, 4-29, 7-99, 8-56, 6-100, 9-77, 5-28), [](4-83, 0-61, 3-27, 1-86, 2-99, 7-31, 5-60, 8-40, 9-84, 6-26), [](4-68, 1-94, 3-46, 2-60, 0-33, 7-46, 5-86, 9-63, 6-70, 8-89), [](4-33, 1-13, 2-91, 3-27, 0-38, 8-82, 7-31, 6-23, 9-27, 5-87), [](4-58, 3-30, 0-24, 2-12, 1-38, 8-2, 9-37, 5-59, 6-37, 7-36), [](2-62, 1-47, 4-5, 3-39, 0-75, 7-60, 9-65, 8-61, 6-77, 5-31), [](4-100, 0-21, 1-53, 3-74, 2-3, 8-34, 6-6, 7-91, 9-80, 5-28), [](1-8, 0-3, 2-88, 3-54, 4-18, 9-4, 6-34, 5-54, 8-59, 7-42), [](3-33, 4-72, 0-83, 2-17, 1-23, 6-24, 8-60, 9-96, 7-78, 5-70), [](4-63, 2-36, 3-70, 0-97, 1-99, 6-71, 9-92, 5-41, 8-73, 7-97), [](2-28, 1-37, 4-24, 0-30, 3-55, 8-38, 5-9, 9-77, 7-17, 6-51), [](3-15, 0-46, 2-14, 4-18, 1-99, 9-48, 6-41, 5-10, 7-47, 8-80), [](4-89, 3-78, 2-51, 1-63, 0-29, 7-70, 9-7, 5-14, 8-84, 6-32), [](4-26, 1-69, 2-92, 3-15, 0-23, 8-42, 6-95, 5-47, 9-83, 7-56), [](1-38, 2-44, 3-47, 4-23, 0-10, 9-63, 7-65, 6-21, 5-70, 8-56), [](3-42, 4-85, 1-29, 0-35, 2-66, 9-46, 8-25, 5-90, 7-85, 6-75), [](3-99, 0-46, 4-74, 2-96, 1-48, 5-52, 6-13, 7-88, 8-4, 9-30), [](1-15, 3-80, 4-47, 2-25, 0-8, 9-61, 7-70, 8-23, 6-93, 5-5), [](0-90, 2-51, 3-66, 4-5, 1-86, 5-59, 6-97, 9-28, 7-85, 8-9), [](0-59, 1-50, 4-40, 3-23, 2-93, 7-61, 9-96, 8-63, 6-34, 5-14), [](1-62, 2-72, 4-30, 0-21, 3-15, 5-77, 6-13, 7-2, 8-22, 9-22), [](2-20, 4-14, 3-85, 1-4, 0-2, 9-33, 7-90, 5-48, 8-90, 6-62), [](0-49, 3-49, 4-46, 1-89, 2-64, 9-72, 8-6, 5-83, 6-13, 7-66), [](4-74, 1-55, 2-73, 0-25, 3-16, 7-19, 9-38, 6-22, 5-26, 8-63), [](3-13, 2-96, 1-8, 0-15, 4-97, 6-95, 7-2, 5-66, 8-57, 9-46), [](4-73, 1-97, 3-39, 0-22, 2-90, 9-64, 6-65, 8-31, 5-98, 7-85), [](3-43, 2-67, 0-38, 1-77, 4-11, 7-61, 5-7, 9-95, 8-97, 6-69), [](0-35, 2-68, 1-5, 3-46, 4-4, 7-51, 6-44, 5-58, 9-69, 8-98), [](2-68, 1-81, 0-2, 3-4, 4-59, 9-53, 8-69, 5-69, 6-14, 7-21))).
jobshop(swv12, "Storer, Wu, and Vaccari hard 50x10 instance (Table 2, instance 12)", 50, 10, []([](0-92, 4-49, 1-93, 3-48, 2-1, 7-52, 6-57, 9-16, 5-6, 8-6), [](4-82, 3-25, 2-69, 1-86, 0-54, 6-15, 5-31, 9-5, 7-6, 8-18), [](0-31, 1-26, 3-46, 2-49, 4-48, 8-74, 7-82, 5-47, 9-93, 6-91), [](0-34, 4-37, 1-82, 3-25, 2-43, 6-11, 9-71, 5-55, 7-34, 8-77), [](4-22, 0-91, 3-54, 2-49, 1-97, 9-2, 7-46, 5-98, 6-27, 8-89), [](2-46, 3-70, 1-3, 0-44, 4-24, 9-65, 6-60, 5-94, 8-58, 7-22), [](3-53, 0-99, 1-80, 2-74, 4-29, 6-72, 7-54, 5-98, 8-60, 9-69), [](3-96, 1-87, 0-36, 2-57, 4-7, 8-36, 9-26, 5-94, 6-47, 7-70), [](3-5, 2-47, 1-59, 0-57, 4-28, 9-24, 8-79, 6-19, 5-44, 7-35), [](0-96, 1-4, 3-60, 2-43, 4-39, 7-97, 5-2, 9-81, 6-89, 8-91), [](2-23, 4-74, 3-98, 0-24, 1-75, 9-57, 8-93, 6-74, 5-10, 7-44), [](3-36, 4-5, 2-36, 0-49, 1-90, 8-62, 5-74, 9-4, 6-85, 7-53), [](2-44, 1-47, 3-75, 4-81, 0-30, 7-42, 8-100, 9-81, 6-29, 5-31), [](1-2, 0-18, 3-88, 2-27, 4-5, 5-36, 7-30, 6-51, 8-51, 9-31), [](1-21, 0-57, 3-100, 2-100, 4-59, 8-77, 7-21, 5-98, 6-38, 9-84), [](4-97, 2-72, 1-70, 3-99, 0-42, 6-94, 5-59, 9-90, 8-78, 7-13), [](3-16, 2-19, 1-70, 0-7, 4-74, 6-7, 5-50, 9-74, 8-46, 7-88), [](3-45, 4-91, 2-28, 0-52, 1-12, 5-45, 6-7, 7-15, 9-22, 8-31), [](3-56, 2-3, 1-8, 4-25, 0-90, 8-99, 6-22, 9-65, 7-51, 5-31), [](0-23, 3-28, 1-49, 2-5, 4-17, 7-40, 9-30, 5-62, 8-65, 6-84), [](2-88, 0-86, 4-8, 1-41, 3-12, 6-67, 9-77, 5-94, 7-80, 8-11), [](4-81, 3-42, 0-19, 2-100, 1-10, 5-23, 9-71, 8-18, 6-93, 7-36), [](4-74, 2-73, 3-63, 1-9, 0-51, 8-39, 7-7, 6-96, 5-81, 9-22), [](1-1, 3-44, 0-66, 4-19, 2-65, 7-10, 6-23, 8-26, 9-76, 5-77), [](1-54, 2-18, 4-99, 0-79, 3-22, 5-2, 6-42, 8-54, 7-90, 9-28), [](3-16, 4-1, 1-28, 0-54, 2-97, 5-71, 6-53, 8-32, 7-26, 9-28), [](0-82, 3-5, 2-18, 4-71, 1-50, 5-41, 7-62, 9-89, 6-93, 8-54), [](2-63, 3-59, 0-42, 1-74, 4-32, 5-50, 6-21, 7-29, 8-83, 9-64), [](4-29, 2-76, 1-6, 3-44, 0-4, 9-81, 5-29, 7-95, 8-66, 6-89), [](3-55, 4-84, 1-36, 0-42, 2-64, 5-81, 8-85, 6-76, 7-4, 9-16), [](4-100, 0-46, 1-69, 3-41, 2-3, 6-18, 5-41, 7-94, 8-97, 9-30), [](3-34, 4-35, 2-18, 1-58, 0-98, 9-78, 8-17, 5-53, 6-85, 7-86), [](4-68, 2-89, 1-99, 0-3, 3-92, 5-10, 6-52, 7-30, 8-66, 9-69), [](0-21, 3-65, 4-19, 2-14, 1-76, 9-84, 6-45, 5-24, 8-54, 7-73), [](4-47, 0-68, 2-87, 3-92, 1-96, 6-29, 5-90, 8-29, 7-39, 9-100), [](2-35, 0-60, 4-61, 1-61, 3-72, 9-57, 8-94, 5-77, 7-1, 6-53), [](3-85, 2-38, 0-79, 4-43, 1-71, 6-44, 5-87, 8-61, 7-51, 9-37), [](1-100, 2-33, 3-94, 0-59, 4-25, 5-88, 9-50, 6-19, 8-4, 7-66), [](2-8, 0-85, 1-80, 4-75, 3-1, 7-17, 9-32, 6-60, 5-30, 8-57), [](4-25, 2-98, 1-94, 3-49, 0-34, 9-37, 7-80, 6-50, 8-25, 5-72), [](3-51, 4-49, 1-53, 2-7, 0-73, 6-96, 7-19, 9-41, 5-55, 8-42), [](0-57, 1-86, 2-1, 4-61, 3-66, 6-28, 5-56, 7-68, 8-21, 9-65), [](2-98, 1-100, 0-47, 4-28, 3-4, 7-34, 9-55, 5-32, 6-72, 8-66), [](4-2, 0-74, 2-20, 1-39, 3-63, 5-88, 9-3, 7-22, 6-8, 8-73), [](2-44, 0-1, 3-52, 1-43, 4-4, 6-36, 9-75, 8-58, 5-61, 7-38), [](2-21, 4-6, 3-32, 1-74, 0-57, 5-72, 8-10, 9-34, 6-91, 7-94), [](4-26, 0-59, 3-53, 1-45, 2-23, 5-55, 8-12, 7-34, 6-98, 9-43), [](2-4, 1-53, 4-57, 3-95, 0-6, 6-30, 8-1, 7-92, 9-20, 5-86), [](1-98, 2-77, 3-65, 4-51, 0-85, 7-23, 6-79, 5-30, 8-41, 9-17), [](4-58, 2-43, 3-14, 0-74, 1-64, 7-37, 8-78, 6-33, 9-42, 5-80))).
jobshop(swv13, "Storer, Wu, and Vaccari hard 50x10 instance (Table 2, instance 13)", 50, 10, []([](4-68, 1-39, 2-79, 0-72, 3-65, 5-82, 7-33, 6-82, 8-66, 9-55), [](2-14, 3-45, 0-18, 4-72, 1-27, 7-57, 6-90, 8-19, 9-19, 5-50), [](4-25, 1-77, 0-64, 3-18, 2-19, 8-27, 6-97, 9-81, 7-65, 5-11), [](3-70, 0-29, 2-31, 1-39, 4-62, 8-12, 9-2, 5-91, 7-98, 6-91), [](2-90, 4-51, 3-38, 1-27, 0-29, 6-67, 8-95, 9-60, 7-86, 5-64), [](4-90, 0-55, 3-69, 1-76, 2-97, 7-94, 5-57, 8-65, 9-80, 6-24), [](1-23, 4-13, 0-90, 3-24, 2-41, 8-69, 7-8, 5-81, 6-94, 9-76), [](3-19, 1-37, 0-16, 4-4, 2-68, 6-45, 8-79, 9-4, 7-30, 5-33), [](2-36, 0-76, 3-97, 4-71, 1-19, 9-87, 6-97, 8-64, 5-84, 7-43), [](2-20, 1-77, 0-71, 3-73, 4-47, 7-88, 5-100, 9-16, 8-69, 6-77), [](3-55, 4-96, 0-8, 2-61, 1-40, 8-46, 7-29, 9-71, 5-89, 6-59), [](2-21, 0-18, 3-37, 4-97, 1-59, 7-79, 6-2, 5-80, 8-85, 9-59), [](4-19, 1-83, 2-1, 0-95, 3-48, 9-37, 7-59, 5-56, 8-57, 6-81), [](0-8, 1-60, 4-91, 3-85, 2-27, 9-39, 5-31, 6-62, 7-94, 8-12), [](4-2, 3-10, 0-17, 1-38, 2-96, 6-21, 9-81, 8-64, 5-76, 7-46), [](2-46, 1-4, 4-25, 3-41, 0-11, 5-96, 9-56, 6-10, 7-25, 8-32), [](0-21, 1-77, 4-22, 2-72, 3-53, 9-28, 7-23, 5-2, 8-52, 6-83), [](3-9, 4-37, 0-2, 2-74, 1-15, 8-26, 5-83, 6-90, 7-51, 9-80), [](3-6, 1-7, 0-57, 2-4, 4-56, 7-11, 5-57, 8-12, 6-94, 9-29), [](1-40, 2-93, 3-65, 4-66, 0-96, 9-5, 7-32, 8-85, 5-93, 6-94), [](1-38, 2-19, 4-22, 0-73, 3-7, 5-63, 8-28, 6-23, 9-11, 7-84), [](1-96, 4-10, 0-29, 3-59, 2-94, 5-26, 7-22, 8-52, 6-37, 9-50), [](1-38, 3-31, 2-76, 0-8, 4-8, 6-50, 5-95, 8-5, 9-25, 7-62), [](0-15, 2-84, 4-100, 3-76, 1-66, 7-56, 5-95, 8-94, 6-56, 9-85), [](3-73, 2-38, 1-84, 0-42, 4-37, 5-16, 7-24, 9-59, 6-60, 8-23), [](3-43, 1-79, 0-80, 2-44, 4-65, 5-81, 7-7, 8-93, 6-55, 9-34), [](2-8, 4-2, 0-12, 3-55, 1-60, 9-91, 6-6, 5-83, 8-31, 7-91), [](0-8, 4-46, 3-47, 2-57, 1-47, 9-55, 8-74, 7-98, 6-54, 5-51), [](2-56, 4-90, 1-41, 0-35, 3-62, 7-4, 5-15, 9-89, 6-73, 8-66), [](0-2, 4-39, 3-44, 1-68, 2-54, 7-7, 8-76, 9-29, 5-90, 6-53), [](2-34, 0-94, 3-1, 1-23, 4-45, 8-83, 7-84, 5-49, 6-67, 9-49), [](4-4, 2-70, 1-19, 0-19, 3-92, 5-70, 7-33, 9-50, 8-82, 6-48), [](4-64, 2-76, 0-70, 3-83, 1-91, 7-98, 8-37, 5-3, 9-75, 6-92), [](3-96, 1-17, 0-20, 4-13, 2-28, 7-21, 9-65, 5-87, 6-54, 8-98), [](0-68, 4-40, 3-98, 2-90, 1-38, 7-45, 8-21, 5-9, 9-3, 6-47), [](0-58, 4-19, 2-16, 3-74, 1-32, 9-32, 5-58, 6-93, 7-1, 8-80), [](0-32, 2-99, 1-95, 3-2, 4-8, 9-55, 6-32, 8-26, 5-6, 7-68), [](3-7, 4-45, 2-19, 0-97, 1-56, 7-22, 9-72, 8-98, 5-59, 6-20), [](2-97, 4-98, 3-43, 0-28, 1-23, 5-3, 8-75, 9-43, 7-58, 6-71), [](3-31, 0-88, 2-88, 1-82, 4-65, 5-53, 9-15, 7-68, 6-60, 8-99), [](4-4, 0-100, 2-95, 1-11, 3-28, 5-80, 7-25, 9-87, 6-25, 8-9), [](0-75, 3-10, 4-59, 2-80, 1-60, 5-75, 8-87, 6-33, 9-10, 7-31), [](0-54, 3-6, 4-7, 1-72, 2-49, 7-72, 8-64, 6-32, 9-86, 5-69), [](4-15, 3-19, 1-18, 0-84, 2-96, 9-71, 8-64, 6-38, 5-58, 7-62), [](1-32, 4-80, 2-83, 3-83, 0-50, 5-81, 7-82, 9-33, 8-10, 6-55), [](0-65, 4-95, 3-84, 2-64, 1-18, 9-27, 6-70, 7-74, 5-87, 8-68), [](1-50, 2-49, 0-96, 3-1, 4-89, 8-42, 5-88, 9-91, 6-64, 7-3), [](3-44, 0-91, 1-5, 2-100, 4-77, 6-20, 5-13, 7-25, 9-71, 8-71), [](0-86, 4-91, 1-19, 2-69, 3-71, 5-13, 8-87, 6-98, 9-43, 7-13), [](4-8, 0-60, 3-31, 2-93, 1-8, 9-1, 7-19, 6-8, 5-85, 8-24))).
jobshop(swv14, "Storer, Wu, and Vaccari hard 50x10 instance (Table 2, instance 14)", 50, 10, []([](4-69, 0-37, 3-64, 1-1, 2-65, 9-34, 5-67, 8-43, 7-72, 6-79), [](1-11, 0-7, 3-68, 4-43, 2-52, 6-29, 9-71, 7-81, 8-12, 5-36), [](4-90, 3-29, 1-1, 2-1, 0-14, 8-38, 5-13, 9-21, 7-41, 6-97), [](1-46, 0-26, 4-83, 2-36, 3-20, 9-4, 8-23, 7-65, 5-56, 6-42), [](4-46, 0-39, 2-92, 3-53, 1-62, 9-68, 7-65, 8-74, 6-87, 5-46), [](4-13, 1-44, 3-43, 2-67, 0-75, 6-5, 9-94, 5-95, 7-28, 8-85), [](1-1, 2-99, 4-36, 3-86, 0-65, 8-32, 5-17, 7-71, 6-15, 9-61), [](2-18, 4-63, 3-15, 0-59, 1-33, 7-95, 5-63, 6-85, 8-34, 9-3), [](4-13, 2-25, 0-82, 3-23, 1-26, 7-22, 9-35, 8-16, 6-24, 5-41), [](3-1, 1-7, 0-21, 2-73, 4-39, 6-32, 7-77, 5-29, 8-89, 9-21), [](1-53, 3-27, 4-55, 0-16, 2-64, 5-78, 9-32, 8-60, 7-20, 6-20), [](1-71, 2-54, 3-21, 0-20, 4-23, 9-40, 5-99, 7-61, 6-94, 8-71), [](2-76, 4-72, 3-91, 0-75, 1-7, 6-53, 8-32, 7-71, 5-63, 9-53), [](2-12, 1-3, 4-35, 0-64, 3-30, 5-94, 8-67, 7-31, 6-79, 9-14), [](4-63, 1-28, 3-87, 0-89, 2-52, 8-2, 9-21, 7-92, 6-44, 5-37), [](0-79, 1-65, 4-35, 3-78, 2-17, 8-90, 5-54, 9-91, 7-57, 6-23), [](3-20, 1-93, 4-61, 0-76, 2-23, 5-10, 8-34, 7-20, 9-87, 6-77), [](0-37, 2-17, 1-92, 4-30, 3-59, 5-47, 8-7, 7-45, 6-13, 9-60), [](4-90, 3-74, 0-46, 2-36, 1-2, 6-9, 5-83, 8-90, 7-88, 9-39), [](3-83, 0-85, 2-20, 4-88, 1-94, 6-14, 5-16, 7-62, 9-53, 8-9), [](0-4, 4-16, 2-64, 1-60, 3-79, 5-37, 6-49, 7-67, 9-95, 8-5), [](3-32, 0-86, 1-5, 4-66, 2-77, 7-15, 5-68, 9-40, 8-1, 6-4), [](0-2, 1-48, 4-23, 3-25, 2-58, 9-55, 7-14, 8-21, 6-85, 5-27), [](1-71, 4-92, 3-99, 2-56, 0-81, 7-79, 6-66, 9-42, 8-47, 5-43), [](1-77, 4-85, 3-72, 2-19, 0-71, 5-34, 7-9, 9-14, 6-62, 8-58), [](4-38, 0-3, 2-61, 3-98, 1-76, 5-14, 9-56, 8-26, 7-43, 6-44), [](1-68, 4-54, 0-62, 2-93, 3-22, 6-57, 7-79, 9-19, 5-77, 8-45), [](2-62, 1-96, 4-56, 0-68, 3-24, 5-41, 6-19, 7-2, 8-73, 9-50), [](2-86, 0-53, 3-3, 1-89, 4-37, 7-100, 5-59, 9-23, 6-19, 8-35), [](3-90, 4-94, 0-21, 2-78, 1-85, 5-94, 6-90, 8-28, 9-92, 7-56), [](4-85, 2-97, 0-8, 3-27, 1-86, 9-26, 7-5, 8-96, 5-68, 6-57), [](0-58, 3-4, 4-49, 2-1, 1-79, 8-10, 6-44, 9-87, 5-16, 7-13), [](3-85, 0-24, 4-23, 1-41, 2-59, 8-20, 6-52, 5-58, 9-75, 7-77), [](0-47, 1-89, 2-68, 4-88, 3-17, 6-48, 8-84, 9-100, 5-92, 7-47), [](1-30, 0-1, 3-61, 4-20, 2-73, 8-78, 7-41, 9-52, 5-43, 6-74), [](0-11, 4-58, 3-66, 2-67, 1-18, 8-42, 7-88, 9-49, 5-62, 6-71), [](4-5, 2-51, 3-67, 1-20, 0-11, 7-37, 6-42, 8-25, 9-57, 5-1), [](0-58, 4-83, 2-9, 3-68, 1-21, 6-28, 9-77, 5-19, 7-32, 8-66), [](3-85, 2-58, 0-65, 1-80, 4-50, 7-79, 5-43, 8-29, 9-9, 6-18), [](3-74, 2-29, 0-11, 1-23, 4-34, 7-84, 8-57, 5-77, 6-83, 9-82), [](2-6, 4-67, 0-97, 3-66, 1-21, 8-90, 9-46, 6-12, 5-17, 7-96), [](4-34, 1-5, 2-13, 0-100, 3-12, 8-63, 7-59, 5-75, 6-91, 9-89), [](1-30, 2-66, 0-33, 3-70, 4-16, 6-80, 5-58, 8-8, 7-86, 9-66), [](3-55, 0-46, 2-1, 1-77, 4-19, 7-85, 9-32, 6-59, 5-37, 8-69), [](2-3, 0-16, 1-48, 4-8, 3-51, 7-72, 6-19, 8-58, 9-59, 5-94), [](3-30, 4-23, 1-92, 0-18, 2-19, 9-32, 6-57, 5-50, 7-64, 8-27), [](2-18, 0-72, 4-92, 1-6, 3-67, 8-100, 6-32, 9-14, 5-51, 7-55), [](4-48, 0-87, 1-96, 2-58, 3-83, 8-77, 5-26, 7-77, 9-72, 6-86), [](1-80, 4-5, 0-50, 3-65, 2-85, 7-88, 5-47, 6-33, 8-50, 9-75), [](1-78, 0-96, 4-80, 3-5, 2-99, 9-58, 5-38, 7-29, 8-69, 6-44))).
jobshop(swv15, "Storer, Wu, and Vaccari hard 50x10 instance (Table 2, instance 15)", 50, 10, []([](2-93, 4-40, 0-1, 3-77, 1-77, 5-16, 9-74, 8-11, 6-51, 7-92), [](0-92, 4-80, 1-76, 3-59, 2-70, 5-86, 9-17, 6-78, 7-30, 8-93), [](1-44, 2-92, 3-96, 4-77, 0-53, 9-10, 7-49, 5-84, 8-59, 6-14), [](1-60, 2-19, 3-76, 0-73, 4-85, 7-13, 8-93, 5-68, 9-50, 6-78), [](2-20, 0-24, 3-41, 1-2, 4-4, 9-44, 7-79, 8-81, 5-16, 6-39), [](3-41, 2-35, 1-32, 4-18, 0-15, 8-98, 6-29, 5-19, 7-14, 9-26), [](1-59, 0-45, 4-53, 3-44, 2-98, 5-84, 6-23, 7-45, 8-39, 9-89), [](1-30, 4-51, 3-25, 0-51, 2-84, 6-60, 5-45, 7-89, 8-25, 9-97), [](0-47, 3-18, 2-40, 4-62, 1-58, 5-36, 7-93, 8-77, 9-90, 6-15), [](3-33, 1-68, 0-41, 4-72, 2-20, 6-69, 7-47, 5-22, 9-47, 8-22), [](2-28, 1-100, 4-20, 0-35, 3-26, 5-24, 9-41, 6-42, 7-100, 8-32), [](0-65, 2-12, 4-53, 3-93, 1-40, 8-18, 7-23, 5-60, 6-89, 9-53), [](0-58, 1-60, 4-97, 3-31, 2-50, 9-85, 5-64, 7-38, 6-85, 8-35), [](3-64, 0-58, 1-49, 2-45, 4-9, 8-49, 6-22, 5-99, 9-15, 7-7), [](0-10, 4-85, 3-72, 2-37, 1-77, 5-70, 7-45, 9-8, 6-83, 8-57), [](4-93, 0-87, 1-87, 2-18, 3-4, 8-78, 5-67, 9-20, 6-17, 7-35), [](4-72, 0-56, 3-57, 2-15, 1-45, 6-41, 5-40, 9-85, 8-32, 7-81), [](0-36, 3-63, 4-79, 2-32, 1-5, 6-25, 7-86, 9-91, 5-21, 8-35), [](2-83, 4-29, 0-9, 1-38, 3-73, 7-50, 9-99, 5-18, 8-29, 6-41), [](0-100, 3-29, 2-60, 4-63, 1-64, 8-71, 6-35, 5-26, 9-9, 7-22), [](1-81, 0-60, 3-62, 4-48, 2-68, 7-28, 5-69, 8-92, 6-79, 9-10), [](0-40, 4-80, 1-41, 2-10, 3-68, 8-28, 9-51, 7-33, 6-82, 5-25), [](4-30, 2-12, 0-35, 3-17, 1-70, 9-29, 7-18, 8-93, 6-94, 5-37), [](1-36, 2-41, 3-27, 4-36, 0-78, 7-64, 6-88, 5-25, 9-92, 8-66), [](2-65, 3-27, 4-74, 0-32, 1-40, 5-88, 8-73, 6-92, 7-83, 9-42), [](0-48, 1-85, 2-92, 4-95, 3-61, 8-72, 9-76, 5-58, 7-11, 6-89), [](3-84, 2-50, 0-70, 4-24, 1-42, 9-55, 5-100, 6-70, 7-4, 8-68), [](0-95, 4-41, 2-11, 3-98, 1-85, 5-64, 6-8, 7-26, 8-6, 9-6), [](0-84, 2-49, 1-17, 3-69, 4-55, 8-75, 6-45, 9-38, 7-59, 5-28), [](2-48, 0-29, 4-1, 1-64, 3-41, 5-23, 7-64, 9-31, 6-56, 8-12), [](2-81, 4-25, 3-33, 0-22, 1-50, 5-74, 9-56, 8-33, 7-85, 6-83), [](1-62, 4-25, 0-21, 2-20, 3-8, 6-36, 9-9, 5-91, 8-90, 7-49), [](1-43, 0-16, 2-91, 3-96, 4-24, 5-11, 9-91, 7-41, 8-35, 6-66), [](1-91, 2-20, 4-44, 0-42, 3-87, 9-57, 6-15, 5-38, 8-42, 7-89), [](0-33, 3-95, 4-68, 2-22, 1-80, 7-53, 8-13, 9-70, 5-22, 6-69), [](0-15, 3-47, 1-24, 2-31, 4-41, 8-14, 9-28, 7-59, 5-52, 6-39), [](2-95, 0-42, 4-5, 1-57, 3-67, 6-30, 9-21, 8-70, 5-9, 7-20), [](2-54, 0-15, 1-20, 3-64, 4-83, 9-40, 7-6, 5-89, 6-91, 8-48), [](0-22, 4-27, 1-77, 3-25, 2-16, 8-72, 9-61, 6-75, 7-4, 5-19), [](3-68, 1-82, 2-16, 0-83, 4-2, 7-10, 8-88, 5-41, 9-21, 6-66), [](1-64, 0-76, 2-85, 3-71, 4-97, 5-97, 7-8, 6-40, 8-70, 9-35), [](0-94, 1-45, 2-94, 4-84, 3-44, 8-41, 5-30, 7-47, 6-19, 9-22), [](2-23, 1-10, 0-82, 3-93, 4-90, 8-67, 7-9, 9-18, 5-22, 6-87), [](0-75, 2-27, 4-97, 3-9, 1-57, 9-14, 5-50, 7-31, 8-62, 6-23), [](1-42, 3-41, 2-35, 0-75, 4-18, 9-65, 7-38, 6-38, 8-51, 5-56), [](4-72, 1-63, 0-33, 2-27, 3-41, 5-52, 7-42, 9-10, 6-14, 8-71), [](2-91, 1-89, 0-44, 4-91, 3-26, 6-49, 5-22, 8-31, 9-69, 7-5), [](3-42, 1-34, 0-4, 4-34, 2-16, 6-86, 7-25, 8-99, 5-67, 9-25), [](4-34, 1-93, 0-26, 3-81, 2-9, 7-96, 8-79, 9-68, 5-76, 6-10), [](3-19, 1-47, 4-13, 2-98, 0-32, 7-12, 9-45, 6-52, 8-49, 5-34))).
jobshop(swv16, "Storer, Wu, and Vaccari easy 50x10 instance (Table 2, instance 16)", 50, 10, []([](1-55, 3-46, 5-71, 8-29, 0-47, 2-12, 7-57, 4-79, 6-91, 9-30), [](2-96, 6-94, 8-98, 0-55, 3-10, 1-95, 5-95, 7-37, 9-82, 4-2), [](6-43, 3-93, 8-30, 2-41, 0-23, 1-60, 7-14, 4-15, 5-42, 9-56), [](0-45, 6-85, 2-59, 7-76, 1-93, 9-62, 4-33, 8-46, 5-33, 3-35), [](2-45, 3-36, 8-11, 6-96, 7-96, 1-8, 0-75, 5-6, 4-13, 9-2), [](9-51, 7-75, 0-4, 3-13, 5-12, 1-4, 2-38, 6-30, 4-42, 8-28), [](9-58, 4-33, 6-77, 2-11, 3-37, 8-64, 5-94, 7-89, 1-96, 0-93), [](6-37, 3-67, 0-88, 9-92, 8-19, 4-27, 7-46, 1-58, 2-60, 5-55), [](4-60, 2-88, 0-23, 5-69, 8-60, 1-32, 7-4, 6-56, 9-25, 3-14), [](2-98, 5-56, 1-68, 6-63, 7-61, 3-78, 8-45, 0-62, 4-31, 9-70), [](7-66, 8-80, 0-18, 3-97, 9-47, 5-38, 1-26, 2-8, 6-90, 4-90), [](0-16, 7-6, 4-53, 6-86, 5-81, 8-49, 3-90, 2-57, 1-34, 9-56), [](2-69, 8-65, 5-20, 4-15, 1-61, 3-71, 6-71, 9-58, 0-24, 7-71), [](4-84, 5-20, 9-58, 0-55, 8-98, 2-75, 7-46, 3-81, 1-71, 6-46), [](5-6, 6-58, 7-90, 1-54, 9-73, 0-92, 4-39, 3-23, 2-100, 8-18), [](2-32, 5-58, 6-97, 1-49, 3-61, 0-69, 8-2, 4-3, 9-32, 7-46), [](0-78, 7-14, 4-98, 3-26, 8-25, 9-45, 6-12, 2-98, 1-99, 5-69), [](2-50, 1-95, 4-82, 9-25, 0-68, 8-83, 5-36, 7-78, 3-35, 6-27), [](6-29, 7-20, 8-55, 4-14, 2-66, 5-52, 0-75, 9-63, 1-93, 3-64), [](1-11, 0-18, 9-42, 4-81, 7-2, 2-39, 3-83, 6-11, 5-38, 8-52), [](4-11, 8-99, 9-2, 7-10, 3-91, 5-83, 6-61, 0-21, 2-69, 1-8), [](9-11, 7-65, 1-14, 2-85, 3-5, 8-5, 5-11, 4-47, 6-67, 0-41), [](9-60, 7-9, 8-16, 2-4, 5-34, 6-2, 4-30, 1-32, 0-51, 3-51), [](9-31, 2-41, 1-13, 6-28, 5-97, 3-8, 7-42, 4-95, 8-46, 0-93), [](4-1, 6-91, 8-49, 3-75, 1-19, 7-100, 0-58, 2-14, 5-34, 9-82), [](3-28, 5-68, 9-30, 7-68, 1-10, 6-20, 8-47, 4-51, 0-44, 2-32), [](9-86, 3-9, 1-80, 0-89, 5-93, 4-12, 8-13, 7-10, 6-18, 2-4), [](0-22, 5-12, 8-95, 4-24, 3-30, 1-81, 2-21, 7-28, 9-100, 6-27), [](1-87, 0-68, 2-64, 3-33, 7-59, 5-95, 6-1, 9-14, 8-82, 4-43), [](2-14, 6-98, 0-86, 1-85, 8-85, 5-12, 4-99, 7-8, 3-21, 9-7), [](5-47, 9-90, 0-88, 1-52, 8-43, 4-62, 7-33, 3-51, 6-97, 2-22), [](2-59, 7-26, 4-76, 0-26, 3-71, 8-59, 1-73, 9-70, 5-57, 6-10), [](6-92, 2-10, 9-45, 0-11, 1-53, 3-35, 8-76, 4-83, 7-55, 5-79), [](9-96, 4-3, 3-92, 7-67, 6-60, 8-35, 5-70, 0-52, 2-39, 1-94), [](4-65, 0-17, 9-26, 7-46, 5-81, 1-42, 2-64, 6-46, 3-96, 8-59), [](9-6, 3-21, 8-46, 0-82, 2-74, 5-56, 7-94, 6-83, 4-63, 1-21), [](6-89, 5-23, 8-78, 2-33, 9-4, 7-97, 3-60, 1-29, 0-79, 4-93), [](0-46, 1-46, 4-20, 7-91, 2-76, 9-83, 3-14, 6-61, 5-84, 8-76), [](7-82, 8-43, 6-76, 1-36, 0-27, 9-93, 5-71, 4-81, 2-45, 3-62), [](7-51, 9-27, 5-12, 6-52, 4-85, 8-66, 0-100, 3-44, 2-82, 1-36), [](3-75, 7-13, 6-63, 1-78, 4-1, 8-60, 2-24, 5-10, 9-56, 0-3), [](5-48, 4-32, 2-82, 0-1, 1-2, 7-35, 3-16, 9-67, 8-74, 6-39), [](7-24, 0-8, 8-96, 3-59, 2-41, 4-23, 1-37, 9-4, 5-69, 6-27), [](1-23, 9-3, 2-85, 6-93, 5-18, 7-47, 0-96, 8-6, 4-60, 3-3), [](6-99, 2-14, 9-16, 3-81, 8-89, 1-53, 7-86, 4-39, 5-3, 0-87), [](5-67, 8-53, 0-77, 4-69, 2-55, 3-78, 6-95, 1-76, 7-2, 9-71), [](1-5, 6-89, 0-37, 3-88, 7-20, 9-4, 4-77, 8-27, 5-31, 2-47), [](1-66, 2-55, 4-15, 7-35, 3-76, 9-91, 6-35, 5-37, 8-54, 0-33), [](3-79, 5-2, 6-17, 1-65, 7-27, 8-53, 4-52, 9-35, 0-23, 2-59), [](9-100, 0-55, 5-14, 2-86, 4-69, 3-87, 8-46, 1-3, 6-89, 7-100))).
jobshop(swv17, "Storer, Wu, and Vaccari easy 50x10 instance (Table 2, instance 17)", 50, 10, []([](7-9, 2-57, 9-62, 5-34, 6-83, 0-33, 1-80, 4-46, 3-21, 8-89), [](9-82, 1-35, 8-37, 5-26, 6-21, 3-78, 7-64, 4-33, 2-40, 0-21), [](7-14, 5-49, 3-48, 9-34, 4-52, 1-16, 2-78, 0-24, 8-58, 6-43), [](2-94, 3-86, 8-41, 5-27, 7-29, 6-53, 9-5, 0-36, 4-98, 1-37), [](7-55, 1-87, 8-51, 5-29, 9-93, 3-51, 0-54, 6-85, 2-20, 4-29), [](2-88, 1-98, 3-67, 8-41, 6-23, 9-70, 7-26, 4-28, 5-17, 0-87), [](2-78, 0-18, 4-43, 3-86, 9-78, 6-43, 7-62, 8-42, 1-44, 5-9), [](9-37, 4-89, 3-26, 6-59, 0-89, 5-90, 1-91, 8-28, 7-37, 2-51), [](3-82, 2-31, 1-98, 5-25, 0-16, 7-23, 9-92, 4-89, 6-32, 8-12), [](6-66, 1-58, 5-14, 3-42, 0-62, 8-66, 4-46, 7-88, 2-89, 9-97), [](8-94, 9-11, 6-3, 1-86, 2-4, 5-19, 7-93, 4-43, 0-78, 3-11), [](5-22, 1-87, 9-61, 2-2, 3-15, 6-37, 7-81, 0-17, 8-31, 4-73), [](6-28, 0-86, 3-54, 2-68, 4-63, 1-33, 8-22, 5-35, 9-84, 7-15), [](6-18, 1-2, 2-23, 8-49, 7-82, 9-8, 4-73, 5-31, 3-20, 0-1), [](7-49, 5-8, 2-36, 8-31, 6-47, 3-90, 0-7, 9-6, 1-44, 4-51), [](4-43, 1-95, 0-18, 9-99, 7-98, 3-26, 8-99, 5-90, 2-24, 6-91), [](1-49, 6-69, 3-73, 9-52, 0-10, 7-41, 8-42, 5-96, 4-85, 2-76), [](0-5, 1-69, 3-38, 7-35, 5-23, 2-40, 8-17, 4-33, 6-99, 9-82), [](3-42, 1-93, 4-90, 6-88, 2-70, 8-11, 9-54, 7-76, 5-40, 0-94), [](5-88, 9-44, 0-63, 7-92, 1-4, 4-91, 6-92, 8-53, 3-52, 2-38), [](5-83, 3-75, 1-44, 2-79, 7-63, 6-32, 0-10, 4-2, 9-6, 8-56), [](7-71, 0-23, 5-93, 3-44, 6-36, 4-27, 2-96, 1-23, 9-35, 8-21), [](5-42, 2-43, 6-37, 9-98, 0-55, 3-35, 4-45, 1-8, 8-5, 7-100), [](0-40, 8-34, 2-7, 9-17, 5-60, 4-98, 7-34, 6-23, 1-37, 3-58), [](9-87, 2-39, 3-23, 8-48, 6-83, 7-50, 5-9, 1-49, 0-37, 4-42), [](6-60, 5-3, 2-60, 7-40, 0-54, 1-68, 4-49, 8-50, 9-22, 3-34), [](5-22, 1-55, 2-32, 0-83, 8-38, 4-22, 6-29, 7-23, 9-59, 3-90), [](9-51, 2-27, 6-81, 8-87, 0-79, 7-1, 3-14, 5-73, 4-25, 1-14), [](6-88, 1-46, 5-16, 2-62, 9-95, 7-63, 4-78, 0-9, 3-68, 8-37), [](4-77, 2-13, 8-96, 3-61, 0-21, 7-39, 5-12, 6-49, 9-73, 1-86), [](7-91, 5-14, 3-37, 0-17, 9-49, 4-27, 1-68, 2-60, 6-42, 8-15), [](9-13, 4-25, 6-62, 0-4, 1-31, 8-76, 5-3, 7-8, 3-26, 2-95), [](7-45, 5-50, 1-14, 0-69, 9-43, 4-1, 6-73, 8-35, 3-1, 2-61), [](4-57, 1-1, 0-74, 8-1, 6-96, 2-92, 7-85, 5-42, 3-12, 9-38), [](7-49, 5-31, 8-79, 6-83, 1-40, 4-65, 3-34, 2-32, 9-97, 0-25), [](9-24, 5-40, 4-81, 3-10, 6-59, 8-83, 2-66, 1-28, 7-33, 0-31), [](5-33, 4-39, 3-50, 1-96, 7-62, 2-72, 8-42, 6-86, 9-66, 0-80), [](3-88, 7-47, 0-35, 4-69, 1-79, 9-61, 2-25, 8-56, 5-68, 6-96), [](9-23, 6-95, 0-42, 1-84, 8-57, 4-42, 2-2, 5-79, 3-29, 7-90), [](9-96, 8-21, 4-17, 7-12, 1-25, 2-9, 6-7, 5-26, 0-81, 3-51), [](1-63, 7-16, 6-40, 2-22, 9-48, 5-87, 0-15, 8-24, 3-37, 4-55), [](7-95, 0-60, 3-62, 2-7, 9-2, 8-81, 5-83, 4-64, 1-68, 6-66), [](3-24, 7-60, 6-35, 2-77, 1-85, 8-57, 9-29, 5-59, 4-53, 0-14), [](1-24, 6-30, 0-9, 3-89, 8-72, 4-77, 2-7, 5-23, 9-73, 7-35), [](0-66, 8-12, 1-9, 5-50, 2-14, 9-76, 4-90, 3-43, 7-48, 6-63), [](3-97, 1-29, 0-59, 4-64, 9-17, 2-77, 5-60, 7-16, 6-61, 8-40), [](9-5, 4-22, 2-3, 8-63, 5-1, 7-23, 0-1, 3-61, 1-92, 6-19), [](6-91, 8-74, 1-88, 5-2, 7-61, 4-39, 0-35, 2-23, 9-84, 3-27), [](8-87, 5-58, 7-44, 1-6, 6-22, 3-57, 9-78, 4-19, 2-74, 0-6), [](4-6, 1-94, 0-45, 2-54, 9-67, 7-90, 5-19, 8-72, 6-70, 3-58))).
jobshop(swv18, "Storer, Wu, and Vaccari easy 50x10 instance (Table 2, instance 18)", 50, 10, []([](7-35, 6-23, 2-92, 4-5, 5-40, 1-90, 3-30, 9-35, 8-8, 0-86), [](2-60, 3-97, 8-21, 9-70, 7-82, 0-12, 4-3, 5-45, 1-75, 6-69), [](7-96, 2-38, 0-61, 1-55, 4-31, 5-48, 9-79, 3-4, 6-12, 8-29), [](4-83, 7-82, 8-97, 1-43, 0-95, 6-92, 2-18, 3-29, 5-4, 9-67), [](3-46, 9-80, 8-66, 2-38, 4-95, 1-40, 7-89, 0-32, 6-64, 5-1), [](6-57, 4-80, 8-68, 7-27, 0-90, 5-45, 3-98, 9-59, 1-6, 2-94), [](5-50, 0-91, 2-97, 9-63, 7-52, 3-48, 4-4, 8-96, 1-18, 6-100), [](7-23, 6-43, 3-25, 8-83, 2-76, 9-41, 1-88, 0-31, 5-44, 4-13), [](2-20, 3-90, 9-20, 4-42, 8-72, 5-46, 1-27, 0-81, 6-40, 7-34), [](7-80, 5-97, 0-42, 2-49, 9-10, 1-10, 3-71, 4-71, 6-14, 8-98), [](2-79, 3-29, 0-96, 7-66, 1-58, 8-31, 4-47, 5-76, 6-59, 9-88), [](8-93, 6-3, 1-7, 3-27, 5-66, 7-23, 0-60, 4-97, 2-66, 9-55), [](9-12, 8-39, 4-77, 5-79, 0-26, 7-58, 2-98, 6-38, 3-31, 1-28), [](6-8, 9-48, 4-4, 1-87, 3-38, 2-28, 8-10, 0-19, 7-82, 5-83), [](5-6, 9-13, 2-86, 6-19, 3-26, 7-79, 0-55, 1-85, 8-33, 4-30), [](3-37, 8-26, 7-29, 6-74, 9-43, 5-17, 0-45, 2-28, 1-58, 4-15), [](7-15, 3-37, 6-21, 5-47, 2-90, 0-37, 9-33, 1-42, 4-7, 8-62), [](8-49, 4-46, 1-28, 7-18, 6-41, 2-57, 0-75, 3-21, 9-3, 5-32), [](6-98, 1-30, 8-24, 4-91, 9-73, 7-25, 5-49, 0-40, 2-9, 3-4), [](6-33, 3-94, 1-21, 2-90, 9-86, 7-85, 5-29, 0-17, 4-94, 8-90), [](6-3, 4-85, 1-66, 7-61, 8-57, 3-84, 2-5, 9-40, 0-54, 5-70), [](7-81, 1-98, 2-45, 0-18, 6-65, 9-1, 4-98, 3-30, 8-84, 5-82), [](6-40, 7-77, 3-72, 1-97, 5-39, 4-21, 0-59, 8-42, 9-90, 2-26), [](5-57, 3-63, 1-14, 4-64, 6-23, 8-78, 2-54, 0-51, 9-100, 7-96), [](5-61, 1-55, 6-73, 2-87, 4-35, 3-41, 7-96, 0-32, 8-91, 9-60), [](9-19, 5-90, 8-91, 0-45, 3-66, 2-84, 1-61, 7-3, 6-84, 4-100), [](2-33, 9-72, 6-27, 8-14, 3-59, 0-39, 7-20, 5-29, 4-54, 1-88), [](4-45, 0-18, 3-73, 2-26, 8-55, 6-22, 7-27, 1-46, 9-43, 5-77), [](2-57, 9-16, 1-71, 8-25, 7-50, 3-41, 6-58, 5-71, 4-9, 0-32), [](8-48, 9-32, 0-42, 3-73, 1-56, 7-53, 6-3, 5-66, 4-15, 2-44), [](6-69, 7-14, 1-2, 8-40, 4-70, 9-90, 3-38, 2-31, 5-55, 0-50), [](9-100, 8-14, 0-55, 2-5, 5-12, 4-79, 1-68, 3-83, 6-89, 7-78), [](4-26, 5-44, 8-39, 1-84, 7-64, 9-98, 3-38, 2-2, 6-27, 0-18), [](3-98, 2-10, 9-99, 8-50, 0-20, 6-12, 4-7, 1-57, 7-87, 5-89), [](0-64, 8-63, 7-98, 5-31, 1-30, 6-62, 3-11, 4-89, 9-31, 2-34), [](3-26, 6-43, 4-69, 7-27, 8-92, 2-51, 1-10, 5-29, 9-21, 0-37), [](8-21, 5-98, 0-64, 6-38, 2-23, 1-13, 7-89, 9-89, 4-21, 3-27), [](4-39, 7-32, 1-67, 0-33, 5-16, 2-43, 6-62, 3-42, 9-70, 8-90), [](7-73, 9-45, 3-37, 0-45, 2-61, 6-25, 5-15, 4-5, 8-58, 1-98), [](7-94, 0-17, 6-15, 5-81, 9-64, 3-62, 1-2, 8-16, 2-35, 4-40), [](5-32, 6-37, 9-11, 0-25, 1-37, 8-21, 2-76, 7-52, 4-56, 3-87), [](3-23, 2-40, 1-6, 7-31, 6-25, 9-98, 8-29, 4-4, 5-25, 0-33), [](8-96, 9-30, 1-95, 3-2, 6-3, 2-22, 0-62, 4-30, 7-1, 5-99), [](9-54, 5-3, 0-78, 2-43, 6-90, 7-88, 4-1, 8-97, 1-30, 3-96), [](5-29, 6-60, 3-80, 1-94, 2-67, 0-42, 8-17, 9-27, 7-75, 4-86), [](1-17, 5-62, 2-25, 7-80, 6-62, 9-19, 8-81, 3-73, 0-57, 4-90), [](9-31, 3-54, 5-28, 1-19, 4-4, 2-34, 8-64, 6-46, 7-60, 0-27), [](9-95, 7-1, 2-43, 3-6, 4-7, 8-66, 1-45, 5-13, 0-80, 6-1), [](3-20, 7-82, 0-87, 1-65, 6-64, 8-61, 2-21, 5-32, 9-16, 4-37), [](0-49, 3-54, 2-31, 8-69, 1-21, 5-2, 6-73, 9-35, 4-66, 7-82))).
jobshop(swv19, "Storer, Wu, and Vaccari easy 50x10 instance (Table 2, instance 19)", 50, 10, []([](7-74, 1-27, 5-66, 3-89, 6-58, 0-11, 8-77, 9-17, 2-70, 4-97), [](5-10, 0-11, 2-38, 3-60, 1-50, 7-35, 6-94, 9-52, 4-2, 8-20), [](7-17, 0-65, 6-93, 8-62, 9-91, 5-2, 1-51, 2-4, 3-19, 4-10), [](4-87, 3-3, 9-81, 0-17, 6-44, 2-82, 7-16, 5-13, 8-100, 1-85), [](9-18, 6-33, 7-35, 0-78, 2-68, 3-68, 8-3, 5-2, 4-53, 1-25), [](2-36, 8-41, 6-60, 9-43, 0-66, 5-34, 3-24, 7-11, 1-5, 4-55), [](9-52, 4-99, 6-62, 0-50, 1-24, 8-73, 7-19, 3-23, 2-15, 5-2), [](4-85, 9-21, 3-27, 7-53, 0-86, 1-36, 6-35, 5-99, 8-30, 2-43), [](6-43, 5-31, 9-99, 2-12, 0-6, 7-79, 3-81, 1-18, 8-73, 4-55), [](4-90, 6-100, 1-15, 0-40, 7-96, 9-25, 5-43, 8-23, 2-31, 3-7), [](5-61, 4-88, 6-10, 3-48, 0-100, 2-62, 1-83, 8-20, 7-42, 9-19), [](9-35, 7-41, 6-16, 3-58, 0-86, 2-69, 5-58, 1-93, 4-47, 8-77), [](2-61, 0-40, 4-99, 1-51, 7-46, 6-39, 3-43, 9-37, 8-88, 5-9), [](4-15, 8-38, 2-84, 5-98, 6-17, 1-91, 7-91, 9-23, 3-48, 0-98), [](3-26, 2-42, 8-55, 4-24, 0-43, 1-83, 9-27, 7-38, 6-37, 5-58), [](5-21, 8-78, 6-97, 0-77, 9-82, 4-26, 3-22, 1-90, 7-57, 2-31), [](4-3, 9-44, 3-90, 1-64, 5-52, 8-35, 7-18, 2-45, 0-4, 6-14), [](8-60, 6-59, 3-67, 2-85, 0-43, 7-93, 5-44, 4-22, 1-68, 9-38), [](4-77, 8-41, 2-74, 6-99, 0-100, 1-45, 9-14, 3-26, 7-98, 5-77), [](8-38, 9-57, 7-42, 5-64, 1-80, 6-81, 4-70, 3-13, 2-41, 0-65), [](9-36, 4-22, 8-39, 0-76, 1-78, 2-27, 5-55, 3-10, 6-5, 7-71), [](7-70, 9-81, 1-60, 5-85, 3-63, 6-97, 2-61, 8-44, 0-5, 4-35), [](9-38, 0-94, 2-46, 5-20, 8-87, 1-41, 4-41, 3-40, 7-99, 6-48), [](7-30, 6-9, 5-13, 2-79, 8-81, 0-25, 9-93, 4-85, 3-78, 1-76), [](4-6, 8-58, 6-51, 7-48, 2-68, 3-34, 5-78, 9-59, 1-98, 0-36), [](4-90, 6-56, 7-97, 9-37, 0-38, 1-47, 2-56, 3-8, 5-37, 8-7), [](0-66, 8-15, 1-39, 5-89, 7-3, 9-54, 3-24, 2-14, 6-99, 4-73), [](3-12, 9-37, 4-79, 8-95, 0-50, 1-74, 6-1, 5-55, 7-98, 2-49), [](8-99, 9-79, 3-99, 2-87, 0-80, 4-13, 5-99, 6-13, 1-54, 7-61), [](1-51, 9-21, 3-32, 6-20, 0-80, 7-58, 2-91, 5-84, 8-62, 4-91), [](1-11, 8-38, 2-14, 9-12, 3-39, 5-34, 0-37, 6-94, 4-10, 7-2), [](6-76, 9-86, 3-40, 4-30, 2-97, 0-59, 8-100, 7-9, 5-55, 1-86), [](3-33, 1-49, 0-94, 2-17, 6-17, 8-70, 5-17, 7-42, 4-26, 9-24), [](4-75, 1-20, 9-93, 2-58, 3-51, 0-94, 6-24, 7-70, 8-51, 5-82), [](8-59, 1-9, 3-59, 5-62, 9-79, 7-53, 6-48, 4-98, 2-76, 0-71), [](6-90, 2-35, 5-89, 0-59, 9-28, 7-51, 4-69, 3-36, 1-32, 8-27), [](5-10, 6-85, 4-97, 1-3, 0-79, 9-86, 3-10, 7-80, 2-37, 8-39), [](7-60, 0-27, 5-69, 8-58, 6-67, 2-36, 9-31, 3-69, 1-16, 4-22), [](2-27, 5-16, 6-15, 4-40, 8-16, 1-92, 9-60, 7-43, 3-2, 0-7), [](1-79, 7-99, 0-27, 9-56, 5-29, 6-17, 8-67, 4-34, 3-86, 2-61), [](6-57, 7-100, 4-73, 9-17, 8-3, 3-64, 2-99, 0-71, 5-27, 1-90), [](2-80, 5-23, 4-54, 6-39, 9-77, 3-65, 7-59, 0-7, 1-63, 8-32), [](4-98, 6-17, 8-44, 5-1, 3-10, 7-56, 2-95, 9-80, 0-99, 1-64), [](8-60, 7-74, 3-60, 6-30, 0-81, 5-25, 4-89, 9-19, 2-59, 1-21), [](1-67, 0-42, 8-93, 2-47, 5-34, 7-11, 6-100, 9-15, 4-99, 3-2), [](9-35, 3-61, 5-93, 8-83, 7-87, 4-66, 0-96, 2-55, 1-41, 6-61), [](8-22, 5-25, 7-29, 3-70, 6-93, 1-19, 0-49, 9-62, 2-19, 4-73), [](8-11, 4-93, 5-97, 1-28, 2-14, 0-75, 7-41, 3-40, 9-62, 6-66), [](7-76, 6-61, 8-64, 3-90, 0-20, 2-43, 9-50, 1-13, 5-4, 4-47), [](3-38, 4-11, 0-30, 5-37, 7-57, 9-64, 1-68, 8-42, 2-19, 6-79))).
jobshop(swv20, "Storer, Wu, and Vaccari easy 50x10 instance (Table 2, instance 20)", 50, 10, []([](8-100, 7-30, 4-42, 9-11, 2-31, 1-71, 5-41, 0-1, 3-55, 6-94), [](4-81, 6-20, 3-96, 7-39, 8-29, 0-90, 9-61, 2-64, 1-86, 5-47), [](5-80, 0-56, 1-88, 7-19, 2-68, 8-95, 3-44, 4-22, 9-60, 6-80), [](4-86, 6-70, 0-88, 2-15, 7-50, 1-54, 9-88, 3-25, 8-89, 5-33), [](0-48, 1-57, 4-86, 8-60, 3-78, 5-4, 9-60, 7-40, 2-11, 6-25), [](6-23, 7-9, 1-90, 0-51, 2-52, 9-14, 5-30, 4-1, 8-25, 3-83), [](1-30, 4-75, 5-76, 9-100, 7-54, 2-41, 6-50, 8-75, 0-1, 3-28), [](2-46, 3-78, 1-37, 7-12, 6-56, 4-50, 8-66, 5-39, 0-8, 9-72), [](1-24, 6-90, 0-32, 3-6, 2-99, 9-22, 8-12, 4-63, 7-81, 5-52), [](6-62, 3-9, 8-59, 0-66, 4-41, 1-32, 5-29, 7-79, 9-84, 2-4), [](9-57, 5-99, 6-2, 3-17, 0-51, 7-10, 4-14, 1-64, 2-99, 8-27), [](7-81, 0-67, 9-83, 2-30, 5-25, 6-87, 1-29, 3-7, 8-93, 4-1), [](5-65, 8-53, 9-48, 4-28, 7-74, 0-60, 6-77, 2-22, 1-5, 3-98), [](1-97, 5-37, 0-71, 7-49, 6-51, 3-17, 4-38, 9-67, 8-28, 2-31), [](0-20, 8-94, 3-39, 6-73, 9-63, 4-8, 2-57, 1-27, 7-26, 5-42), [](8-77, 1-68, 9-20, 7-100, 4-1, 5-77, 6-17, 3-35, 2-65, 0-86), [](8-68, 6-62, 4-79, 7-84, 1-60, 3-56, 0-10, 9-86, 5-60, 2-30), [](4-71, 2-74, 6-6, 1-56, 3-69, 0-8, 8-50, 9-78, 5-4, 7-89), [](8-29, 5-5, 1-59, 3-96, 0-46, 4-91, 2-48, 7-53, 6-21, 9-82), [](2-19, 9-96, 0-73, 1-39, 5-54, 8-50, 7-60, 3-50, 4-65, 6-78), [](7-68, 4-15, 2-26, 3-26, 0-13, 9-13, 5-96, 8-70, 6-27, 1-93), [](6-41, 8-18, 4-66, 7-9, 1-31, 2-92, 0-3, 3-78, 5-41, 9-53), [](5-9, 0-64, 2-15, 6-73, 4-12, 1-43, 8-89, 7-69, 3-32, 9-22), [](5-93, 6-19, 3-74, 8-81, 0-72, 2-94, 9-19, 1-26, 4-53, 7-7), [](3-48, 2-29, 5-51, 8-72, 7-35, 6-32, 1-38, 0-98, 4-58, 9-54), [](0-94, 9-23, 4-41, 6-53, 2-53, 7-27, 1-62, 3-68, 8-84, 5-49), [](4-4, 1-4, 0-66, 7-90, 9-78, 2-29, 5-2, 6-86, 3-23, 8-46), [](3-78, 5-61, 2-97, 7-68, 8-92, 0-15, 4-12, 6-77, 1-12, 9-22), [](0-100, 7-89, 6-71, 2-70, 8-89, 4-72, 5-78, 3-23, 9-37, 1-2), [](0-91, 3-74, 2-36, 4-72, 6-62, 1-80, 9-20, 7-77, 5-47, 8-80), [](1-44, 0-67, 4-66, 8-99, 6-59, 5-5, 7-15, 2-38, 3-40, 9-19), [](1-69, 9-35, 3-86, 0-7, 2-35, 5-32, 6-66, 4-89, 8-63, 7-52), [](3-3, 4-68, 1-66, 7-27, 6-41, 5-2, 9-77, 0-45, 2-40, 8-39), [](4-66, 3-42, 7-79, 0-55, 6-98, 9-44, 5-6, 8-73, 1-55, 2-1), [](3-80, 8-18, 9-94, 2-27, 5-42, 4-17, 7-74, 0-65, 6-6, 1-27), [](2-73, 4-70, 5-51, 0-84, 8-29, 9-95, 1-97, 7-28, 3-68, 6-89), [](9-85, 6-56, 5-54, 3-76, 2-50, 0-43, 1-8, 7-93, 4-17, 8-65), [](1-1, 3-17, 2-61, 5-38, 4-71, 7-18, 0-40, 9-94, 6-41, 8-74), [](3-30, 8-22, 6-39, 9-56, 5-3, 7-64, 4-74, 2-21, 0-93, 1-1), [](0-17, 8-8, 9-20, 5-38, 3-85, 7-5, 2-63, 1-18, 4-89, 6-88), [](8-87, 5-44, 0-42, 1-34, 9-11, 7-13, 3-71, 4-88, 6-32, 2-12), [](2-39, 1-73, 6-43, 0-48, 9-77, 8-48, 5-23, 7-66, 3-94, 4-68), [](1-98, 7-19, 3-69, 6-5, 8-85, 9-19, 0-30, 2-43, 5-87, 4-70), [](2-45, 1-60, 4-30, 9-71, 5-35, 0-75, 3-75, 6-41, 8-67, 7-37), [](3-63, 7-39, 2-16, 9-69, 1-46, 5-20, 6-57, 4-51, 0-66, 8-40), [](2-7, 7-73, 6-17, 1-21, 0-24, 8-2, 5-68, 4-22, 9-36, 3-60), [](1-20, 4-17, 8-12, 9-29, 5-28, 0-7, 3-38, 6-57, 7-22, 2-75), [](5-53, 4-7, 7-5, 8-27, 9-38, 2-100, 6-48, 0-53, 1-11, 3-18), [](1-49, 7-47, 4-81, 8-9, 0-20, 2-63, 3-15, 6-1, 9-10, 5-5), [](4-49, 6-27, 7-17, 5-64, 2-30, 8-56, 0-42, 3-97, 9-82, 1-34))).
jobshop(yn1, "Yamada and Nakano 20x20 instance (Table 4, instance 1)", 20, 20, []([](17-13, 2-26, 11-35, 4-45, 12-29, 13-21, 7-40, 0-45, 3-16, 15-10, 18-49, 10-43, 14-25, 8-25, 1-40, 6-16, 19-43, 5-48, 9-36, 16-11), [](8-21, 6-22, 14-15, 5-28, 10-10, 2-46, 11-19, 19-13, 13-18, 18-14, 3-11, 4-21, 16-30, 1-29, 0-16, 15-41, 17-40, 12-38, 7-28, 9-39), [](4-39, 3-28, 8-32, 17-46, 0-35, 14-14, 1-44, 10-20, 13-12, 6-23, 18-22, 9-15, 11-35, 7-27, 16-26, 5-27, 15-23, 2-27, 12-31, 19-31), [](4-31, 10-24, 3-34, 6-44, 18-43, 12-32, 2-35, 15-34, 19-21, 7-46, 13-15, 5-10, 9-24, 14-37, 17-38, 1-41, 8-34, 0-32, 16-11, 11-36), [](19-45, 1-23, 5-34, 9-23, 7-41, 16-10, 11-40, 12-46, 14-27, 8-13, 4-20, 2-40, 15-28, 13-44, 17-34, 18-21, 10-27, 0-12, 6-37, 3-30), [](13-48, 2-34, 3-22, 7-14, 12-22, 14-10, 8-45, 19-38, 6-32, 16-38, 11-16, 4-20, 0-12, 5-40, 9-33, 17-35, 1-32, 10-15, 15-31, 18-49), [](9-19, 5-33, 18-32, 16-37, 12-28, 3-16, 2-40, 10-37, 4-10, 11-20, 1-17, 17-48, 6-44, 13-29, 14-44, 15-48, 8-21, 0-31, 7-36, 19-43), [](9-20, 6-43, 1-13, 5-22, 2-33, 7-28, 16-39, 12-16, 13-34, 17-20, 10-47, 18-43, 19-44, 8-29, 15-22, 4-14, 11-28, 14-44, 0-33, 3-28), [](7-14, 12-40, 8-19, 0-49, 13-11, 10-13, 9-47, 18-22, 2-27, 17-26, 3-47, 5-37, 6-19, 15-43, 14-41, 1-34, 11-21, 4-30, 19-32, 16-45), [](16-32, 7-22, 15-30, 6-18, 18-41, 19-34, 9-22, 11-11, 17-29, 10-37, 4-30, 2-25, 1-27, 0-31, 14-16, 13-20, 3-26, 12-14, 5-24, 8-43), [](18-22, 17-22, 12-30, 15-31, 13-15, 4-13, 16-47, 19-18, 6-33, 3-30, 7-46, 2-48, 11-42, 0-18, 1-16, 8-25, 10-43, 5-21, 9-27, 14-14), [](5-48, 1-39, 2-21, 18-18, 13-20, 0-28, 15-20, 8-36, 6-24, 9-35, 7-22, 19-36, 3-39, 14-34, 4-49, 17-36, 11-38, 10-46, 12-44, 16-13), [](14-26, 1-32, 2-11, 15-10, 9-41, 13-10, 6-26, 19-26, 12-13, 11-35, 5-22, 0-11, 7-24, 17-33, 8-11, 10-34, 16-11, 3-22, 4-12, 18-17), [](16-39, 10-24, 17-43, 14-28, 3-49, 15-34, 18-46, 13-29, 6-31, 11-40, 7-24, 1-47, 9-15, 2-26, 8-40, 12-46, 5-18, 19-16, 4-14, 0-21), [](11-41, 19-26, 16-14, 3-47, 0-49, 5-16, 17-31, 9-43, 15-20, 10-25, 14-10, 13-49, 8-32, 6-36, 7-19, 4-23, 2-20, 18-15, 12-34, 1-33), [](11-37, 5-48, 10-31, 7-42, 2-24, 1-13, 9-30, 15-24, 0-19, 13-34, 19-35, 8-42, 3-10, 14-40, 4-39, 6-42, 12-38, 16-12, 18-27, 17-40), [](14-19, 1-27, 8-39, 12-41, 5-45, 11-40, 10-46, 6-48, 7-37, 3-30, 17-31, 4-16, 18-29, 15-44, 0-41, 16-35, 13-47, 9-21, 2-10, 19-48), [](18-38, 0-27, 13-32, 9-30, 7-17, 14-21, 1-14, 4-37, 17-15, 16-31, 5-27, 10-25, 15-41, 11-48, 3-48, 6-36, 2-30, 12-45, 8-26, 19-17), [](1-17, 10-40, 9-16, 5-36, 4-34, 16-47, 19-14, 0-24, 18-10, 6-14, 13-14, 3-30, 12-23, 2-37, 17-11, 11-23, 8-40, 15-15, 14-10, 7-46), [](14-37, 10-28, 13-13, 0-28, 2-18, 1-43, 16-46, 8-39, 3-30, 12-15, 11-38, 17-38, 18-45, 19-44, 9-16, 15-29, 5-33, 6-20, 7-35, 4-34))).
jobshop(yn2, "Yamada and Nakano 20x20 instance (Table 4, instance 2)", 20, 20, []([](17-15, 2-28, 11-10, 4-46, 12-19, 13-13, 7-18, 0-14, 3-11, 15-21, 18-30, 10-29, 14-16, 8-41, 1-40, 6-38, 19-28, 5-39, 9-39, 16-28), [](8-32, 6-46, 14-35, 5-14, 10-44, 2-20, 11-12, 19-23, 13-22, 18-15, 3-35, 4-27, 16-26, 1-27, 0-23, 15-27, 17-31, 12-31, 7-31, 9-24), [](4-34, 3-44, 8-43, 17-32, 0-35, 14-34, 1-21, 10-46, 13-15, 6-10, 18-24, 9-37, 11-38, 7-41, 16-34, 5-32, 15-11, 2-36, 12-45, 19-23), [](4-34, 10-23, 3-41, 6-10, 18-40, 12-46, 2-27, 15-13, 19-20, 7-40, 13-28, 5-44, 9-34, 14-21, 17-27, 1-12, 8-37, 0-30, 16-48, 11-34), [](19-22, 1-14, 5-22, 9-10, 7-45, 16-38, 11-32, 12-38, 14-16, 8-20, 4-12, 2-40, 15-33, 13-35, 17-32, 18-15, 10-31, 0-49, 6-19, 3-33), [](13-32, 2-37, 3-28, 7-16, 12-40, 14-37, 8-10, 19-20, 6-17, 16-48, 11-44, 4-29, 0-44, 5-48, 9-21, 17-31, 1-36, 10-43, 15-20, 18-43), [](9-13, 5-22, 18-33, 16-28, 12-39, 3-16, 2-34, 10-20, 4-47, 11-43, 1-44, 17-29, 6-22, 13-14, 14-28, 15-44, 8-33, 0-28, 7-14, 19-40), [](9-19, 6-49, 1-11, 5-13, 2-47, 7-22, 16-27, 12-26, 13-47, 17-37, 10-19, 18-43, 19-41, 8-34, 15-21, 4-30, 11-32, 14-45, 0-32, 3-22), [](7-30, 12-18, 8-41, 0-34, 13-22, 10-11, 9-29, 18-37, 2-30, 17-25, 3-27, 5-31, 6-16, 15-20, 14-26, 1-14, 11-24, 4-43, 19-22, 16-22), [](16-30, 7-31, 15-15, 6-13, 18-47, 19-18, 9-33, 11-30, 17-46, 4-48, 10-42, 2-18, 1-16, 0-25, 14-43, 13-21, 3-27, 12-14, 5-48, 8-39), [](18-21, 17-18, 12-20, 15-28, 13-20, 4-36, 16-24, 19-35, 7-22, 3-36, 6-39, 10-34, 11-49, 0-36, 1-38, 8-46, 9-44, 5-13, 2-26, 14-32), [](9-11, 1-10, 2-41, 11-10, 13-26, 0-26, 12-13, 10-35, 6-22, 5-11, 7-24, 19-33, 3-11, 14-34, 17-11, 4-22, 18-12, 8-17, 15-39, 16-24), [](1-43, 15-28, 2-49, 14-34, 4-46, 12-29, 18-31, 19-40, 13-24, 11-47, 5-15, 0-26, 7-40, 17-46, 8-18, 10-16, 16-14, 3-21, 9-41, 6-26), [](16-14, 6-47, 17-49, 10-16, 3-31, 12-43, 4-20, 8-25, 14-10, 18-49, 7-32, 0-36, 9-19, 2-23, 15-20, 5-15, 13-34, 19-33, 11-37, 1-48), [](4-31, 11-42, 7-24, 6-13, 0-30, 14-24, 17-19, 19-34, 16-35, 10-42, 15-10, 13-40, 2-39, 8-42, 5-38, 9-12, 1-27, 18-40, 12-19, 3-27), [](6-39, 5-41, 13-45, 15-40, 2-46, 9-48, 7-37, 0-30, 1-31, 12-16, 19-29, 14-44, 3-41, 8-35, 10-47, 11-21, 4-10, 16-48, 18-38, 17-27), [](16-32, 1-30, 8-17, 18-21, 0-14, 17-37, 10-15, 12-31, 7-27, 3-25, 5-41, 4-48, 13-48, 6-36, 2-30, 15-45, 11-26, 9-17, 14-17, 19-40), [](18-16, 17-36, 4-34, 2-47, 10-14, 15-24, 1-10, 3-14, 7-14, 12-30, 5-23, 9-37, 8-11, 14-23, 11-40, 6-15, 16-10, 0-46, 13-37, 19-28), [](17-13, 13-28, 11-18, 16-43, 7-46, 8-39, 3-30, 5-15, 4-38, 2-38, 14-45, 0-44, 10-16, 6-29, 12-33, 1-20, 19-35, 15-34, 9-16, 18-40), [](17-14, 2-30, 0-27, 15-47, 18-43, 3-17, 14-13, 6-43, 7-45, 12-32, 13-13, 16-48, 1-10, 4-14, 10-42, 9-38, 5-43, 19-22, 11-43, 8-23))).
jobshop(yn3, "Yamada and Nakano 20x20 instance (Table 4, instance 3)", 20, 20, []([](13-47, 16-21, 17-27, 8-46, 1-27, 14-39, 19-24, 4-34, 7-27, 3-36, 6-11, 5-32, 0-13, 9-40, 2-40, 15-20, 18-45, 10-23, 12-36, 11-31), [](1-40, 11-20, 12-27, 6-32, 16-26, 13-36, 10-37, 7-26, 3-22, 4-44, 18-18, 2-11, 17-15, 9-27, 15-39, 5-25, 8-16, 14-13, 0-49, 19-25), [](9-40, 8-11, 14-47, 2-35, 13-41, 7-37, 1-37, 18-28, 6-42, 3-23, 10-41, 5-33, 17-25, 0-19, 19-15, 16-42, 12-37, 11-34, 4-10, 15-41), [](2-28, 4-18, 11-42, 5-26, 13-27, 6-24, 12-41, 0-25, 1-27, 7-40, 17-40, 14-49, 10-33, 3-30, 15-34, 16-17, 8-49, 9-21, 18-35, 19-42), [](7-26, 9-27, 4-25, 3-42, 19-28, 15-22, 17-34, 0-15, 6-46, 1-34, 12-47, 2-16, 16-34, 10-31, 14-24, 5-43, 13-45, 11-47, 8-18, 18-15), [](4-30, 8-48, 1-46, 15-13, 9-20, 7-31, 14-20, 2-20, 16-34, 19-38, 18-12, 17-11, 11-47, 5-19, 0-35, 13-17, 10-23, 12-11, 3-22, 6-11), [](3-27, 2-11, 5-17, 0-43, 1-25, 15-24, 18-36, 8-12, 9-21, 13-44, 10-17, 17-41, 16-34, 11-14, 12-45, 7-45, 14-27, 6-47, 4-47, 19-11), [](5-27, 4-41, 17-44, 16-16, 11-42, 10-29, 3-23, 2-15, 0-22, 13-28, 7-16, 14-39, 9-21, 12-15, 18-32, 15-36, 1-29, 8-18, 6-39, 19-33), [](4-44, 19-38, 11-24, 17-21, 13-34, 15-11, 10-16, 8-43, 16-41, 7-45, 3-37, 9-10, 6-36, 18-31, 2-17, 14-28, 12-43, 0-22, 1-25, 5-15), [](7-40, 15-23, 4-37, 2-12, 8-28, 12-19, 10-30, 17-40, 13-20, 18-11, 5-23, 16-46, 3-40, 1-37, 14-17, 0-16, 11-31, 6-15, 9-10, 19-22), [](5-10, 1-37, 15-22, 2-28, 6-10, 9-21, 19-38, 16-35, 7-34, 0-13, 14-33, 11-16, 4-26, 3-20, 17-10, 18-37, 13-21, 8-31, 10-27, 12-23), [](16-32, 6-32, 7-20, 1-14, 0-11, 19-27, 3-21, 18-32, 10-33, 13-13, 17-36, 8-25, 4-32, 5-41, 15-44, 2-32, 14-12, 9-32, 12-10, 11-28), [](7-28, 9-33, 11-35, 17-44, 4-43, 16-35, 12-31, 2-14, 6-48, 8-40, 15-28, 0-31, 3-22, 5-30, 13-27, 10-24, 18-47, 14-38, 1-46, 19-22), [](12-33, 6-33, 14-38, 9-15, 10-16, 13-24, 1-30, 8-18, 7-46, 2-30, 17-37, 11-24, 5-13, 3-14, 18-11, 16-38, 0-31, 4-24, 19-42, 15-30), [](10-15, 16-12, 6-43, 18-27, 0-24, 9-20, 3-41, 2-22, 12-41, 11-30, 5-26, 4-24, 7-45, 13-46, 14-22, 15-11, 8-20, 1-42, 19-11, 17-49), [](4-14, 19-30, 17-15, 7-17, 8-34, 2-48, 3-45, 14-16, 12-23, 16-29, 13-28, 6-28, 18-24, 10-21, 5-37, 1-38, 11-31, 0-29, 9-42, 15-22), [](15-41, 17-19, 5-37, 7-36, 8-47, 12-49, 11-29, 6-18, 9-33, 10-30, 0-49, 16-37, 3-11, 2-46, 14-36, 18-35, 13-45, 1-31, 4-33, 19-18), [](9-42, 4-11, 15-28, 18-48, 6-22, 8-15, 1-37, 11-36, 3-26, 19-21, 2-48, 16-17, 12-30, 10-27, 13-35, 17-20, 0-18, 7-14, 14-20, 5-41), [](19-35, 17-19, 16-20, 15-36, 1-15, 3-46, 4-13, 8-42, 18-19, 5-37, 2-10, 13-44, 10-30, 11-20, 14-42, 6-35, 0-26, 9-29, 7-21, 12-42), [](17-33, 3-11, 7-42, 16-45, 9-29, 0-27, 5-15, 13-37, 2-32, 11-25, 14-21, 8-49, 19-34, 1-31, 15-35, 6-32, 4-20, 18-30, 10-24, 12-29))).
jobshop(yn4, "Yamada and Nakano 20x20 instance (Table 4, instance 4)", 20, 20, []([](16-34, 17-38, 0-21, 6-15, 15-42, 8-17, 7-41, 18-10, 10-26, 11-24, 1-31, 19-25, 14-31, 13-33, 4-35, 9-30, 3-16, 12-16, 5-30, 2-13), [](5-41, 11-33, 6-15, 16-38, 0-40, 14-38, 3-37, 1-20, 13-22, 4-34, 7-16, 17-39, 9-15, 2-19, 10-36, 12-39, 18-26, 8-19, 15-39, 19-34), [](17-34, 1-12, 16-10, 7-47, 13-28, 15-27, 0-19, 6-34, 19-33, 12-40, 9-37, 14-24, 8-15, 10-34, 2-44, 3-37, 18-22, 11-31, 4-39, 5-26), [](5-48, 7-46, 16-47, 10-45, 14-15, 8-25, 0-34, 3-24, 12-35, 18-15, 2-48, 13-19, 11-10, 1-48, 17-16, 15-28, 4-18, 6-17, 9-44, 19-41), [](12-47, 3-23, 9-48, 16-45, 14-39, 6-42, 8-32, 15-11, 13-16, 5-14, 11-19, 1-46, 19-10, 10-17, 7-41, 2-47, 17-32, 4-17, 0-21, 18-17), [](18-14, 16-20, 1-18, 12-14, 13-10, 6-16, 5-24, 4-18, 0-24, 11-18, 15-42, 19-13, 3-23, 14-40, 9-48, 8-12, 2-24, 10-23, 7-45, 17-30), [](0-27, 12-15, 4-26, 13-19, 17-14, 5-49, 7-16, 18-28, 16-16, 8-20, 9-36, 2-21, 14-30, 3-36, 1-17, 15-22, 6-43, 11-32, 10-23, 19-17), [](0-32, 16-15, 17-12, 7-46, 3-37, 18-43, 11-40, 13-43, 9-48, 4-36, 15-24, 8-25, 1-33, 14-32, 5-26, 6-37, 12-24, 10-24, 2-15, 19-22), [](10-34, 6-33, 15-25, 8-46, 0-20, 18-33, 4-19, 13-45, 2-47, 1-32, 3-12, 11-29, 16-29, 5-46, 12-17, 7-48, 14-39, 17-40, 19-41, 9-37), [](13-26, 3-47, 5-44, 6-49, 1-22, 17-12, 10-28, 19-36, 9-27, 4-25, 14-48, 7-11, 16-49, 12-24, 11-48, 2-19, 0-47, 18-49, 8-46, 15-36), [](13-23, 18-48, 14-15, 0-42, 3-36, 8-15, 6-32, 10-18, 1-45, 15-23, 11-45, 2-13, 17-21, 12-32, 7-44, 5-25, 19-34, 16-22, 9-11, 4-43), [](17-37, 7-49, 15-45, 2-28, 9-15, 8-35, 12-29, 13-44, 1-26, 4-25, 5-30, 3-39, 0-15, 14-28, 18-23, 6-42, 11-33, 16-45, 10-10, 19-20), [](0-10, 6-37, 3-15, 13-13, 10-11, 2-49, 1-28, 14-28, 15-13, 8-29, 12-21, 16-32, 11-21, 4-48, 5-11, 17-26, 9-33, 18-22, 7-21, 19-49), [](18-38, 0-41, 4-30, 13-43, 6-11, 2-43, 14-27, 3-26, 9-30, 15-19, 16-36, 1-31, 17-47, 5-41, 10-34, 8-40, 12-32, 7-13, 11-18, 19-27), [](6-24, 5-30, 7-10, 10-35, 8-28, 16-43, 19-12, 9-44, 15-15, 3-15, 2-35, 18-43, 0-38, 4-16, 1-29, 17-40, 14-49, 13-38, 12-16, 11-30), [](3-48, 6-35, 13-43, 2-37, 17-18, 5-27, 9-27, 7-41, 1-22, 15-28, 16-18, 10-37, 18-48, 4-10, 8-14, 11-18, 14-43, 0-48, 12-12, 19-49), [](0-13, 13-38, 7-34, 6-42, 1-36, 5-45, 18-24, 8-35, 14-26, 19-30, 12-47, 16-24, 11-47, 4-40, 10-43, 3-16, 15-10, 2-12, 9-39, 17-22), [](16-30, 13-47, 19-49, 8-20, 4-40, 3-46, 17-21, 14-33, 6-44, 7-23, 9-24, 0-48, 10-43, 15-41, 2-32, 5-29, 11-36, 1-38, 12-47, 18-12), [](13-10, 5-36, 12-18, 16-48, 0-27, 14-43, 10-46, 6-27, 7-46, 19-35, 11-31, 2-18, 8-24, 3-23, 17-29, 18-14, 9-19, 1-40, 15-38, 4-13), [](9-45, 16-44, 0-43, 17-31, 14-35, 13-17, 12-42, 3-14, 18-37, 10-39, 6-48, 7-38, 15-26, 4-49, 2-28, 11-35, 1-42, 5-24, 8-44, 19-38))).


get_bench(Name, Tasks, NRes, EndDate) :-
	jobshop(Name, _Comment, NJobs, NRes, Data),
	(
	    for(I,1,NJobs),
	    count(Ascii,0'a,_),
	    fromto(Tasks, Tasks3, Tasks0, [EndTask]),
	    fromto(LastTasks, [LastTask|LastTasks0], LastTasks0, []),
	    param(NRes,Data)
	do
	    char_code(Letter, Ascii),
	    (
		for(J,1,NRes),
		fromto(Tasks3, [T|Tasks1], Tasks1, Tasks0),
		fromto([], PrevTask, [T], [LastTask]),
		param(I,Letter,Data)
	    do
		concat_atom([Letter,J],TId),
		subscript(Data, [I,J], UsedResNr-Duration),
		RId is UsedResNr+1,	% our resource ids are 1..NRes
		T = task{name:TId,use:RId,duration:Duration,need:PrevTask}
	    )
	),
	% add a dummy end task after all last job tasks
	EndTask = task{name:end,start:EndDate,use:0,duration:0,need:LastTasks}.


%----------------------------------------------------------------------
% Notes
%----------------------------------------------------------------------

/*

1.    Improve disjunctive_bools such that it propagates the booleans settings
    transitively, i.e. when a bool gets set, all resulting ordering bools
    are automatically set.
    
    Currently, fully ordered tasks can still have uninstantiated bools,
    so it is not easy to exclude them from the task intervals.

    However, the only labeling steps are to set all ordering booleans of
    a task in one go, so the propagation may not be so important.

*/

