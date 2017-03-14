%
% This is a little "tomography" problem, taken from an old issue
% of Scientific American.
%
% A matrix which contains zeroes and ones gets "x-rayed" vertically and
% horizontally, giving the total number of ones in each row and column.
% The problem is to reconstruct the contents of the matrix from this
% information. Sample run:
%
%	?- go.
%	    0 0 7 1 6 3 4 5 2 7 0 0
%	 0                         
%	 0                         
%	 8      * * * * * * * *    
%	 2      *             *    
%	 6      *   * * * *   *    
%	 4      *   *     *   *    
%	 5      *   *   * *   *    
%	 3      *   *         *    
%	 7      *   * * * * * *    
%	 0                         
%	 0                         
%	
%	
% Eclipse solution by Joachim Schimpf, IC-Parc
%


:- lib(ic).

go :-
	data1(RowSums, ColSums),
	solve(RowSums, ColSums, Board),
	pretty_print(RowSums, ColSums, Board).



solve(RowSums, ColSums, Board) :-
	dim(RowSums, [M]),		% get row and column dimensions
	dim(ColSums, [N]),

	dim(Board, [M,N]),		% make variables
	Board[1..M,1..N] :: 0..1,

	( for(I,1,M), param(Board,RowSums,N) do		% row constraints
	    sum(Board[I,1..N]) #= RowSums[I]
	),

	( for(J,1,N), param(Board,ColSums,M) do		% column constraints
	    sum(Board[1..M,J]) #= ColSums[J]
	).


pretty_print(RowSums, ColSums, Board) :-
	dim(Board, [M,N]),
	write("   "),
	( for(J,1,N), param(ColSums) do
	    ColSum is ColSums[J],
	    printf("%2d", ColSum)
	), nl,
	( for(I,1,M), param(RowSums,Board,N) do
	    RowSum is RowSums[I],
	    printf("%2d ", RowSum),
	    ( for(J,1,N), param(Board,I) do
		X is Board[I,J],
		( X==0 -> write("  ")
		; X==1 -> write(" *")
		;         write(" ?")
		)
	    ), nl
	), nl.


% sample data

data1([](0,0,8,2,6,4,5,3,7,0,0),	% row sums
      [](0,0,7,1,6,3,4,5,2,7,0,0)).	% column sums

data2([](10,4,8,5,6),
      [](5,3,4,0,5,0,5,2,2,0,1,5,1)).

data3([](11,5,4),
      [](3,2,3,1,1,1,1,2,3,2,1)).


