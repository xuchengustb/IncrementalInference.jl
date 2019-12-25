# originates from sisue #458

# using Revise

using Test
using IncrementalInference


@testset "Test clique factors, #458 Example 1" begin

fg = initfg()

addVariable!(fg, :x0, ContinuousScalar)
addVariable!(fg, :x1, ContinuousScalar)
addVariable!(fg, :x2, ContinuousScalar)
addVariable!(fg, :x3, ContinuousScalar)
addVariable!(fg, :x4, ContinuousScalar)

addVariable!(fg, :l0, ContinuousScalar)
addVariable!(fg, :l1, ContinuousScalar)

lc = LinearConditional(Normal())
lp = Prior(Normal())
addFactor!(fg, [:x0;:x1], lc, autoinit=false)
addFactor!(fg, [:x1;:x2], lc, autoinit=false)
addFactor!(fg, [:x2;:x3], lc, autoinit=false)
addFactor!(fg, [:x3;:x4], lc, autoinit=false)

addFactor!(fg, [:x0;:l0], lc, autoinit=false)
addFactor!(fg, [:x2;:l0], lc, autoinit=false)

addFactor!(fg, [:x0;:l1], lc, autoinit=false)
addFactor!(fg, [:x2;:l1], lc, autoinit=false)

addFactor!(fg, [:x0;], lp, autoinit=false)
addFactor!(fg, [:l0;], lp, autoinit=false)

vo = Symbol[:x2, :x0, :l0, :x3, :x1, :l1, :x4]
# getSolverParams(fg).dbg = true
# tree, smt, hist = solveTree!(fg, variableOrder=vo)


tree = resetBuildTreeFromOrder!(fg, vo)
# drawTree(tree, show=true)


# check that frontal variables only show up once
frontals = getCliqFrontalVarIds.((x->getCliq(tree, x)).([:x0; :l0; :x4]))

@test intersect(frontals[1], frontals[2]) |> length == 0
@test intersect(frontals[2], frontals[3]) |> length == 0
@test intersect(frontals[1], frontals[3]) |> length == 0

# check that all variables exist as frontals
lsvars = ls(fg)
@test intersect(union(frontals...), lsvars) |> length == lsvars |> length



## Now check if factors in cliques are okay

C3_fg = buildCliqSubgraph(fg, tree, getCliq(tree, :x0) )
# drawGraph(C3_fg, show=true)

C3_fcts = [:x0l0f1;:x0l1f1;:x0x1f1;:x0f1]

@test intersect(ls(C3_fg), [:x0; :x1; :l0; :l1]) |> length == 4
@test intersect(lsf(C3_fg), C3_fcts) |> length == length(C3_fcts)


C2_fg = buildCliqSubgraph(fg, tree, getCliq(tree, :l0) )
# drawGraph(C2_fg, show=true)

C2_fcts = [:x1x2f1; :x2x3f1; :x2l0f1; :x2l1f1; :l0f1]

@test intersect(ls(C2_fg), [:x3; :x2; :x1; :l0; :l1]) |> length == 5
@test intersect(lsf(C2_fg), C2_fcts) |> length == length(C2_fcts)


C1_fg = buildCliqSubgraph(fg, tree, getCliq(tree, :x4) )
# drawGraph(C1_fg, show=true)

C1_fcts = [:x3x4f1;]

@test intersect(ls(C1_fg), [:x3; :x4; :x1; :l1]) |> length == 4
@test intersect(lsf(C1_fg), C1_fcts) |> length == length(C1_fcts)

# check that all factors are counted
allCliqFcts = union(C1_fcts, C2_fcts, C3_fcts)

@test length(intersect(lsf(fg), allCliqFcts)) == length(allCliqFcts)


end



@testset "Test clique factors, #458 Example 1" begin

@warn "Test for Example 2 from 458 must still be coded."

end



#