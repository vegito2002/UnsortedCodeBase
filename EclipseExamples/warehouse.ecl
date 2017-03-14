%
% Warehouse location problem
% from P. van Hentenryck: Constraint Satisfaction in Logic Programming
%
% A factory has to deliver goods to it customers and has at its disposal
% a finite number of locations where it is possible to build warehouses. 
% For the construction of a warehouse we have a cost, referred to as a
% fixed cost.  Also, there are variable costs for the transportation of
% goods to the customers.  These costs are variable since they are
% dependent on the warehouse locations, because of the distance.  The
% problem is to determine the number and the locations of the warehouses
% that minimize the (fixed and variable) costs.
% 
% Code by Joachim Schimpf, IC-Parc
% This solution uses a set to model the set of the warehouses
% that are actually built.


:- lib(ic).
:- lib(ic_sets).
:- lib(branch_and_bound).
:- import minimize/2 from branch_and_bound.


solve(SuppliedBys, BuiltWarehouses, NumBuiltWarehouses) :-

    % get the data
	setup_cost(SetupCost),
	supply_cost_matrix(SupplyCostMatrix),
	dim(SupplyCostMatrix, [NCustomers, NWareHouses]),
	
    % model
	intset(BuiltWarehouses, 1, NWareHouses),
	#(BuiltWarehouses, NumBuiltWarehouses),

	(
	    for(CustomerId, 1, NCustomers),
	    foreach(SuppliedBy, SuppliedBys),
	    foreach(CustCost, CustCosts),
	    param(BuiltWarehouses,SupplyCostMatrix,NWareHouses)
	do
	    CostTable is SupplyCostMatrix[CustomerId, 1..NWareHouses],
	    element(SuppliedBy, CostTable, CustCost),
	    SuppliedBy in BuiltWarehouses
	),

    % objective
	TotalCost #= NumBuiltWarehouses*SetupCost + sum(CustCosts),

    % search
	order_warehouses(SupplyCostMatrix, CustOrderedWarehouseIds),
	minimize((

	    insetdomain(BuiltWarehouses, increasing, _, _),
	    labeling(SuppliedBys, CustOrderedWarehouseIds),
	    writeln(BuiltWarehouses)

	), TotalCost).



% heuristics: for every customer, order the warehouses in
% order of increasing supply cost

order_warehouses(SupplyCostMatrix, CustOrderedWarehouseIds) :-
	dim(SupplyCostMatrix, [NCustomers, NWareHouses]),
	( for(I,1,NWareHouses), foreach(I,WarehouseIds) do true ),
	( 
	    for(CustomerId, 1, NCustomers),
	    foreach(OrderedWareHouseIds, CustOrderedWarehouseIds),
	    param(SupplyCostMatrix,NWareHouses,WarehouseIds)
	do
	    SupplyCosts is SupplyCostMatrix[CustomerId, 1..NWareHouses],
	    keysort(SupplyCosts, WarehouseIds, OrderedWareHouseIds)
	).


% label the SuppliedBy variables according to the heuristics

labeling(SuppliedBys, CustOrderedWarehouseIds) :-
	(
	    foreach(SuppliedBy, SuppliedBys),
	    foreach(OrderedWarehouseIds, CustOrderedWarehouseIds)
	do
	    member(SuppliedBy, OrderedWarehouseIds)
	).


% auxiliary

keysort(Keys, Values, OrderedValues) :-
	( foreach(K,Keys), foreach(V,Values), foreach(K-V,KeyValues) do true ),
	keysort(KeyValues, OrderedKeyValues),
	( foreach(V,OrderedValues), foreach(_K-V,OrderedKeyValues) do true ).



% sample data with 19 warehouses and 20 customers

supply_cost_matrix([](
    [](68948, 68948, 68948, 68948, 35101, 68948, 24524, 24524, 35101, 68948, 26639, 35101, 68948, 68948, 68948, 68948, 68948, 26639, 35101),
    [](15724, 8634, 17850, 17850, 23520, 16433, 46200, 46200, 23520, 17850, 46200, 46200, 17850, 17850, 17850, 15724, 16433, 17850, 23520),
    [](24300, 24300, 12600, 24300, 60300, 24300, 60300, 60300, 60300, 60300, 60300, 60300, 31500, 31500, 31500, 24300, 24300, 60300, 60300),
    [](4852, 4852, 4852, 2817, 4852, 6104, 10486, 10486, 10486, 10486, 10486, 10486, 4852, 10486, 6104, 4852, 4539, 6104, 4852),
    [](40950, 40950, 78390, 31590, 16380, 40950, 40950, 31590, 40950, 78390, 31590, 31590, 29250, 78390, 40950, 31590, 40950, 29250, 28080),
    [](66330, 66330, 66330, 66330, 34650, 66330, 13860, 24750, 26730, 34650, 26730, 34650, 34650, 66330, 34650, 34650, 66330, 26730, 34650),
    [](39698, 39698, 39698, 39698, 15998, 39698, 14813, 8295, 20738, 39698, 14813, 15998, 20738, 39698, 20738, 20738, 39698, 15998, 15998),
    [](45895, 23975, 45895, 45895, 23975, 45895, 18495, 23975, 9590, 18495, 23975, 45895, 45895, 23975, 18495, 23975, 45895, 18495, 45895),
    [](5519, 4387, 9481, 9481, 9481, 4387, 5519, 9481, 4387, 2547, 9481, 9481, 5519, 4104, 4387, 4387, 5519, 5519, 9481),
    [](53433, 53433, 53433, 53433, 21533, 53433, 21533, 19938, 27913, 53433, 11165, 19938, 27913, 53433, 53433, 53433, 53433, 21533, 21533),
    [](47235, 47235, 47235, 47235, 19035, 47235, 24675, 19035, 47235, 47235, 17625, 9870, 24675, 47235, 47235, 47235, 47235, 24675, 19035),
    [](13125, 13125, 14175, 18375, 18375, 7350, 35175, 35175, 35175, 14175, 35175, 35175, 18375, 14175, 14175, 14175, 14175, 18375, 35175),
    [](138176, 159783, 181390, 181390, 239008, 166985, 469480, 469480, 239008, 239008, 469480, 469480, 181390, 181390, 181390, 166985, 166985, 239008, 239008),
    [](106993, 123723, 140454, 140454, 185069, 129300, 363528, 363528, 185069, 140454, 363528, 363528, 140454, 140454, 140454, 129300, 129300, 185069, 185069),
    [](55408, 47915, 62900, 62900, 82880, 57905, 162800, 162800, 82880, 82880, 162800, 162800, 62900, 62900, 62900, 57905, 57905, 62900, 82880),
    [](55786, 93864, 106556, 106556, 140403, 98095, 275792, 275792, 140403, 140403, 275792, 275792, 106556, 106556, 106556, 98095, 98095, 140403, 140403),
    [](16847, 16847, 19125, 19125, 25200, 17607, 49500, 49500, 25200, 19125, 49500, 49500, 19125, 19125, 19125, 17607, 19125, 25200, 25200),
    [](27780, 24308, 31253, 31253, 31253, 28938, 77553, 77553, 40513, 40513, 77553, 77553, 31253, 31253, 31253, 28938, 28938, 31253, 40513),
    [](4278, 3983, 4573, 4573, 4573, 4573, 5753, 5753, 5753, 4573, 9883, 9883, 4573, 4573, 4278, 2655, 4573, 4573, 5753),
    [](9672, 9005, 12340, 12340, 9672, 9672, 12340, 12340, 9672, 9672, 22345, 22345, 9672, 9672, 8671, 8671, 9672, 9672, 12340)
)).

setup_cost(50000).
