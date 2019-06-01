## Initial setup
# using Revise
using Juno
using IncrementalInference
using RoME
using DistributedFactorGraphs
import DistributedFactorGraphs.GraphsJl
const DFGGraphs = DistributedFactorGraphs.GraphsJl
using Test

dfg = initfg()
addVariable!(dfg, :x1, Pose2)
addVariable!(dfg, :x2, Pose2)
addVariable!(dfg, :x3, Pose2)
addVariable!(dfg, :l1, Pose2)
addVariable!(dfg, :l2, Pose2)

prior = PriorPose2( MvNormal([10; 10; pi/6.0], Matrix(Diagonal([0.1;0.1;0.05].^2))))
addFactor!(dfg, [:x1], prior )

pp = Pose2Pose2(MvNormal([10.0;0;pi/3], Matrix(Diagonal([0.1;0.1;0.1].^2))))
p2br = Pose2Point2BearingRange(Normal(0,0.1),Normal(20.0,1.0))

addFactor!(dfg, [:x1, :x2], deepcopy(pp), autoinit=false)
addFactor!(dfg, [:x2, :x3], deepcopy(pp), autoinit=false)
addFactor!(dfg, [:x1, :l1], deepcopy(p2br), autoinit=false)
# TODO: Ask why it can't resolve here.
addFactor!(dfg, [:x2, :l1], deepcopy(p2br), autoinit=false)
addFactor!(dfg, [:x3, :l2], deepcopy(p2br), autoinit=false)

# Show it
DFGGraphs.toDotFile(dfg, "/tmp/testRmMarg.dot")

# Test with a copy
dfgPrime = deepcopy(dfg)
elimOrder = IncrementalInference.getEliminationOrder(dfgPrime)
elimOrder = [:l1, :l2, :x1, :x2, :x3]

IncrementalInference.buildBayesNet!(dfgPrime, elimOrder)
# Reproduce example
# IncrementalInference.rmVarFromMarg(dfgPrime, lm[1], )
DFGGraphs.toDotFile(dfgPrime, "/tmp/testRmMarg.dot")
# Assert that everything was eliminated and every variable has a BayesNetVertID
@test all(map(v -> getData(v.dfgNode).eliminated, values(dfgPrime.g.vertices)))
@test all(map(v -> getData(v).BayesNetVertID != nothing, DFGGraphs.getVariables(dfgPrime)))
# Assert that we have the expected Bayes tree
expectedBayesOutVertDict = Dict{Symbol, Vector{Symbol}}(:x2 => [:x3], :l1 => [:x1, :x2], :x3 => [], :l2 => [:x3], :x1 => [:x2])
for (vId,linkIds) in expectedBayesOutVertDict
    v = DFGGraphs.getVariable(dfgPrime, vId)
    @test setdiff(getData(v).BayesNetOutVertIDs, linkIds) == []
end

# Now build the tree
# global tree = emptyBayesTree()
# buildTree!(tree, dfgPrime, p)

## End-to-end
@info "...Righto!"
@info "Time to build the Bayes Tree..."
dfgPrime = deepcopy(dfg)


resetFactorGraphNewTree!(dfg)
p = getEliminationOrder(dfg)
tree = buildTreeFromOrdering!(dfg, p, drawbayesnet=false)
# fge = deepcopy(dfg)
# buildBayesNet!(fge, p)
# tree = emptyBayesTree()
# buildTree!(tree, fge, p)
#
#
# cliq = tree.cliques[3] # start at the root
# # IIF.buildCliquePotentials(dfg, tree, cliq);
# @info "Get potentials $(cliq.attributes["label"])"
# IIF.getCliquePotentials!(dfg, tree, cliq)
# IIF.compCliqAssocMatrices!(dfg, tree, cliq)
# # frtl = getCliqFrontalVarIds(cliq)
# # cond = getCliqSeparatorVarIds(cliq)
# # inmsgIDs = IIF.collectSeparators(tree, cliq)
# # potIDs = IIF.cliqPotentialIDs(cliq)

getData(cliq)




getData(DFGGraphs.getFactor(dfg, :x1l1f1)).fncargvID



mat = getCliqMat(cliq)


prepBatchTree!(dfgPrime)


drawTree(tree, show=true)




0

import IncrementalInference: resetFactorGraphNewTree!, resetData!






v = DFGGraphs.getVariables(dfgPrime)[1]
getData(v).BayesNetVertID





# TODO: Nary tests for factors....

###
