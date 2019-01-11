
#
# type EasyMessage
#   pts::Array{Float64,2}
#   bws::Array{Float64,1}
# end

mutable struct NBPMessage <: Singleton
  p::Dict{Int,EasyMessage}
end

mutable struct PotProd
    Xi::Int
    prev::Array{Float64,2}
    product::Array{Float64,2}
    potentials::Array{BallTreeDensity,1}
    potentialfac::Vector{AbstractString}
end
mutable struct CliqGibbsMC
    prods::Array{PotProd,1}
    lbls::Vector{Symbol}
    CliqGibbsMC() = new()
    CliqGibbsMC(a,b) = new(a,b)
end
mutable struct DebugCliqMCMC
    mcmc::Union{Nothing, Array{CliqGibbsMC,1}}
    outmsg::NBPMessage
    outmsglbls::Dict{Symbol, Int}
    priorprods::Vector{CliqGibbsMC} #Union{Nothing, Dict{Symbol, Vector{EasyMessage}}}
    DebugCliqMCMC() = new()
    DebugCliqMCMC(a,b,c,d) = new(a,b,c,d)
end

mutable struct UpReturnBPType
    upMsgs::NBPMessage
    dbgUp::DebugCliqMCMC
    IDvals::Dict{Int, EasyMessage} #Array{Float64,2}
    keepupmsgs::Dict{Symbol, BallTreeDensity}
end

mutable struct DownReturnBPType
    dwnMsg::NBPMessage
    dbgDwn::DebugCliqMCMC
    IDvals::Dict{Int,EasyMessage} #Array{Float64,2}
    keepdwnmsgs::Dict{Symbol, BallTreeDensity}
end

mutable struct ExploreTreeType
  fg::FactorGraph
  bt::BayesTree
  cliq::Graphs.ExVertex
  prnt::Any
  sendmsgs::Array{NBPMessage,1}
end

mutable struct MsgPassType
  fg::FactorGraph
  cliq::Graphs.ExVertex
  vid::Int
  msgs::Array{NBPMessage,1}
  N::Int
end




#global pidx
pidx = 1
pidl = 1
pidA = 1
thxl = nprocs() > 4 ? floor(Int,nprocs()*0.333333333) : 1

# upploc to control processes done local to this machine and separated from other
# highly loaded processes. upploc() should be used for dispatching short and burst
# of high bottle neck computations. Use upp2() for general multiple dispatch.
function upploc()
    global pidl, thxl
    N = nprocs()
    pidl = (thxl > 1 ? ((pidl < thxl && pidl != 0 && thxl > 2) ? (pidl+1)%(thxl+1) : 2) : (N == 1 ? 1 : 2))
    return pidl
end

# upp2() may refer to processes on a different machine. Do not associate upploc()
# with processes on a separate computer -- this will be become more complicated when
# remote processes desire their own short fast 'local' burst computations. We
# don't want all the data traveling back and forth for shorter jobs
function upp2()
  global pidx, thxl
  N = nprocs()
  pidx = (N > 1 ? ((pidx < N && pidx != 0) ? (pidx+1)%(N+1) : thxl+1) : 1) #2 -- thxl+1
  return pidx
end

function uppA()
  global pidA
  N = nprocs()
  pidA = (N > 1 ? ((pidA < N && pidA != 0) ? (pidA+1)%(N+1) : 2) : 1) #2 -- thxl+1
  return pidA
end


function packFromIncomingDensities!(dens::Array{BallTreeDensity,1},
      wfac::Vector{AbstractString},
      vertid::Int,
      inmsgs::Array{NBPMessage,1} )
  #
  for m in inmsgs
    for idx in keys(m.p)
      if idx == vertid
        pdi = m.p[vertid]
        push!(dens, kde!(pdi) ) # kde!(pdi.pts, pdi.bws)
        push!(wfac, "msg")
      end
      # TODO -- we can inprove speed of search for inner loop
    end
  end
  nothing
end

"""
    $(SIGNATURES)

Add all potentials associated with this clique and vertid to dens.
"""
function packFromLocalPotentials!(fgl::FactorGraph,
      dens::Vector{BallTreeDensity},
      wfac::Vector{AbstractString},
      cliq::Graphs.ExVertex,
      vertid::Int,
      N::Int,
      dbg::Bool=false,
      api::DataLayerAPI=localapi  )
  #
  for idfct in cliq.attributes["data"].potentials
    vert = getVert(fgl, idfct, api=api)
    data = getData(vert)
    # skip partials here, will be caught in packFromLocalPartials!
    if length( findall(data.fncargvID .== vertid) ) >= 1 && !data.fnc.partial
      p = findRelatedFromPotential(fgl, vert, vertid, N, dbg )
      push!(dens, p)
      push!(wfac, vert.label)
    end
  end
  nothing
end


function packFromLocalPartials!(fgl::FactorGraph,
      partials::Dict{Int, Vector{BallTreeDensity}},
      cliq::Graphs.ExVertex,
      vertid::Int,
      N::Int,
      dbg::Bool=false,
      api::DataLayerAPI=localapi )
  #

  for idfct in cliq.attributes["data"].potentials
    vert = getVert(fgl, idfct, api=api)
    data = getData(vert)
    if length( findall(data.fncargvID .== vertid) ) >= 1 && data.fnc.partial
      p = findRelatedFromPotential(fgl, vert, vertid, N, dbg)
      pardims = data.fnc.usrfnc!.partial
      for dimnum in pardims
        if haskey(partials, dimnum)
          push!(partials[dimnum], marginal(p,[dimnum]))
        else
          partials[dimnum] = BallTreeDensity[marginal(p,[dimnum])]
        end
      end
    end
  end
  nothing
end


"""
    $(SIGNATURES)

Multiply different dimensions from partial constraints individually.
"""
function productpartials!(pGM::Array{Float64,2},
                          dummy::BallTreeDensity,
                          partials::Dict{Int, Vector{BallTreeDensity}}  )

  #
  for (dimnum,pp) in partials
    dummy2 = marginal(dummy,[dimnum]) # kde!(rand(1,N),[1.0])
    if length(pp) > 1
      pGM[dimnum,:], = prodAppxMSGibbsS(dummy2, pp, Union{}, Union{}, 8)
    else
      pGM[dimnum,:] = getPoints(pp[1])
    end
  end
  nothing
end

"""
    $(SIGNATURES)

Multiply various full and partial dimension constraints.
"""
function prodmultiplefullpartials( dens::Vector{BallTreeDensity},
      partials::Dict{Int, Vector{BallTreeDensity}},
      Ndims::Int, N::Int  )
  #
  dummy = kde!(rand(Ndims,N),[1.0]); # TODO -- reuse memory rather than rand here
  pGM, = prodAppxMSGibbsS(dummy, dens, nothing, nothing, 8) #10
  for (dimnum,pp) in partials
    push!(pp, kde!(pGM[dimnum,:]))
  end
  productpartials!(pGM, dummy, partials)
  return pGM
end

"""
    $(SIGNATURES)

Multiply a single full and several partial dimension constraints.
"""
function prodmultipleonefullpartials( dens::Vector{BallTreeDensity},
      partials::Dict{Int, Vector{BallTreeDensity}},
      Ndims::Int, N::Int  )
  #
  dummy = kde!(rand(Ndims,N),[1.0]) # TODO -- reuse memory rather than rand here
  denspts = getPoints(dens[1])
  pGM = deepcopy(denspts)
  for (dimnum,pp) in partials
    push!(pp, kde!(pGM[dimnum,:]))
  end
  productpartials!(pGM, dummy, partials)
  return pGM
end

function productbelief(fg::FactorGraph,
                       vertid::Int,
                       dens::Vector{BallTreeDensity},
                       partials::Dict{Int, Vector{BallTreeDensity}},
                       N::Int;
                       dbg::Bool=false,
                       api::DataLayerAPI=localapi)
  #

  pGM = Array{Float64,2}(undef, 0,0)
  lennonp, lenpart = length(dens), length(partials)
  if lennonp > 1
    Ndims = Ndim(dens[1])
    @info "[$(lennonp)x$(lenpart)p,d$(Ndims),N$(N)],"
    pGM = prodmultiplefullpartials(dens, partials, Ndims, N)
  elseif lennonp == 1 && lenpart >= 1
    Ndims = Ndim(dens[1])
    @info "[$(lennonp)x$(lenpart)p,d$(Ndims),N$(N)],"
    pGM = prodmultipleonefullpartials(dens, partials, Ndims, N)
  elseif lennonp == 0 && lenpart >= 1
    denspts = getVal(fg,vertid, api=api)
    Ndims = size(denspts,1)
    @info "[$(lennonp)x$(lenpart)p,d$(Ndims),N$(N)],"
    dummy = kde!(rand(Ndims,N), ones(Ndims)) # [1.0] # TODO -- reuse memory rather than rand here
    pGM = deepcopy(denspts)
    productpartials!(pGM, dummy, partials)
  # elseif lennonp == 0 && lenpart == 1
  #   info("[prtl]")
  #   pGM = deepcopy(getVal(fg,vertid,api=localapi) )
  #   for (dimnum,pp) in partials
  #     pGM[dimnum,:] = getPoints(pp)
  #   end
  elseif lennonp == 1 && lenpart == 0
    # @info "[drct]"
    pGM = getPoints(dens[1])
  else
    @warn "Unknown density product on vertid=$(vertid), lennonp=$(lennonp), lenpart=$(lenpart)"
    pGM = Array{Float64,2}(undef, 0,1)
  end

  return pGM
end

function proposalbeliefs!(fgl::FactorGraph,
      destvertid::Int,
      factors::Vector{Graphs.ExVertex},
      dens::Vector{BallTreeDensity},
      partials::Dict{Int, Vector{BallTreeDensity}};
      N::Int=100,
      dbg::Bool=false )
  #
  for fct in factors
    data = getData(fct)
    p = findRelatedFromPotential(fgl, fct, destvertid, N, dbg)
    if data.fnc.partial   # partial density
      pardims = data.fnc.usrfnc!.partial
      for dimnum in pardims
        if haskey(partials, dimnum)
          push!(partials[dimnum], marginal(p,[dimnum]))
        else
          partials[dimnum] = BallTreeDensity[marginal(p,[dimnum])]
        end
      end
    else # full density
      push!(dens, p)
    end
  end
  nothing
end

function predictbelief(fgl::FactorGraph,
                       destvert::ExVertex,
                       factors::Vector{Graphs.ExVertex};
                       N::Int=0,
                       dbg::Bool=false )
  #
  destvertid = destvert.index
  dens = Array{BallTreeDensity,1}()
  partials = Dict{Int, Vector{BallTreeDensity}}()

  # determine number of particles to draw from the marginal
  nn = N != 0 ? N : size(getVal(destvert),2)

  # get proposal beliefs
  proposalbeliefs!(fgl, destvertid, factors, dens, partials, N=nn, dbg=dbg)

  # take the product
  pGM = productbelief(fgl, destvertid, dens, partials, nn, dbg=dbg )

  return pGM
end

function predictbelief(fgl::FactorGraph,
                       destvertsym::Symbol,
                       factorsyms::Vector{Symbol};
                       N::Int=0,
                       dbg::Bool=false,
                       api::DataLayerAPI=IncrementalInference.localapi  )
  #
  factors = Graphs.ExVertex[]
  for fsym in factorsyms
    push!(factors, getVert(fgl, fgl.fIDs[fsym], api=api))
  end
  vert = getVert(fgl, destvertsym, api=api)

  # determine the number of particles to draw from the marginal
  nn = N != 0 ? N : size(getVal(vert),2)

  # do the belief prediction
  predictbelief(fgl, vert, factors, N=nn, dbg=dbg)
end

function predictbelief(fgl::FactorGraph,
                       destvertsym::Symbol,
                       factorsyms::Colon;
                       N::Int=0,
                       dbg::Bool=false,
                       api::DataLayerAPI=IncrementalInference.localapi  )
  #
  predictbelief(fgl, destvertsym, ls(fgl, destvertsym, api=api), N=N, api=api, dbg=dbg )
end

"""
    $(SIGNATURES)

Using factor graph object `fg`, project belief through connected factors
(convolution with conditional) to variable `sym` followed by a approximate functional product.

Return: product belief, full proposals, partial dimension proposals, labels
"""
function localProduct(fgl::FactorGraph,
                      sym::Symbol;
                      N::Int=100,
                      dbg::Bool=false,
                      api::DataLayerAPI=IncrementalInference.dlapi  )
  # TODO -- converge this function with predictbelief for this node
  # TODO -- update to use getVertId
  destvertid = fgl.IDs[sym] #destvert.index
  dens = Array{BallTreeDensity,1}()
  partials = Dict{Int, Vector{BallTreeDensity}}()
  lb = String[]
  fcts = Vector{Graphs.ExVertex}()
  cf = ls(fgl, sym, api=api)
  for f in cf
    vert = getVert(fgl,f, nt=:fnc, api=api)
    push!(fcts, vert)
    push!(lb, vert.label)
  end

  # get proposal beliefs
  proposalbeliefs!(fgl, destvertid, fcts, dens, partials, N=N, dbg=dbg)

  # take the product
  pGM = productbelief(fgl, destvertid, dens, partials, N, dbg=dbg )
  pp = kde!(pGM)

  return pp, dens, partials, lb
end
localProduct(fgl::FactorGraph, lbl::T; N::Int=100, dbg::Bool=false) where {T <: AbstractString} = localProduct(fgl, Symbol(lbl), N=N, dbg=dbg)


"""
    $(SIGNATURES)

Initialize the belief of a variable node in the factor graph struct.
"""
function initializeNode!(fgl::FactorGraph,
        sym::Symbol;
        N::Int=100,
        api::DataLayerAPI=IncrementalInference.dlapi )
  #

  vert = getVert(fgl, sym, api=api)
  # TODO -- this localapi is inconsistent, but get internal error due to problem with ls(fg, api=dlapi)
  belief,b,c,d  = localProduct(fgl, sym, api=localapi)
  pts = getPoints(belief)
  @show "initializing", sym, size(pts), Statistics.mean(pts,2), Statistics.std(pts,2)
  setVal!(vert, pts)
  api.updatevertex!(fgl, vert)

  nothing
end

"""
    $(SIGNATURES)

Perform one step of the minibatch clique Gibbs operation for solving the Chapman-Kolmogov trasit integral -- here involving separate approximate functional convolution and product operations.
"""
function cliqGibbs(fg::FactorGraph,
                   cliq::Graphs.ExVertex,
                   vertid::Int,
                   inmsgs::Array{NBPMessage,1},
                   N::Int,
                   dbg::Bool,
                   api::DataLayerAPI=localapi  )
  #
  # several optimizations can be performed in this function TODO

  # consolidate NBPMessages and potentials
  dens = Array{BallTreeDensity,1}()
  partials = Dict{Int, Vector{BallTreeDensity}}()
  wfac = Vector{AbstractString}()
  packFromIncomingDensities!(dens, wfac, vertid, inmsgs)
  packFromLocalPotentials!(fg, dens, wfac, cliq, vertid, N, api)
  packFromLocalPartials!(fg, partials, cliq, vertid, N, dbg)

  potprod = !dbg ? nothing : PotProd(vertid, getVal(fg,vertid, api=api), Array{Float64}(undef, 0,0), dens, wfac)
  pGM = productbelief(fg, vertid, dens, partials, N, dbg=dbg, api=api )
  if dbg  potprod.product = pGM  end

  # @info " "
  return pGM, potprod
end

"""
    $(SIGNATURES)

Iterate successive approximations of clique marginal beliefs by means
of the stipulated proposal convolutions and products of the functional objects
for tree clique `cliq`.
"""
function fmcmc!(fgl::FactorGraph,
                cliq::Graphs.ExVertex,
                fmsgs::Vector{NBPMessage},
                IDs::Vector{Int},
                N::Int,
                MCMCIter::Int,
                dbg::Bool=false,
                api::DataLayerAPI=dlapi )
  #
    @info "---------- successive fnc approx ------------$(cliq.attributes["label"])"
    # repeat several iterations of functional Gibbs sampling for fixed point convergence
    if length(IDs) == 1
        MCMCIter=1
    end
    mcmcdbg = Array{CliqGibbsMC,1}()

    for iter in 1:MCMCIter
      # iterate through each of the variables, KL-divergence tolerence would be nice test here
      @info "#$(iter)\t -- "
      dbgvals = !dbg ? nothing : CliqGibbsMC([], Symbol[])
      for vertid in IDs
        vert = getVert(fgl, vertid, api=api)
        if !getData(vert).ismargin
          # we'd like to do this more pre-emptive and then just execute -- just point and skip up only msgs
          densPts, potprod = cliqGibbs(fgl, cliq, vertid, fmsgs, N, dbg) #cliqGibbs(fg, cliq, vertid, fmsgs, N)
          if size(densPts,1)>0
            updvert = getVert(fgl, vertid, api=api)  # TODO --  can we remove this duplicate getVert?
            setValKDE!(updvert, densPts)
            # Go update the datalayer TODO -- excessive for general case, could use local and update remote at end
            api.updatevertex!(fgl, updvert)
            # fgl.v[vertid].attributes["val"] = densPts
            if dbg
              push!(dbgvals.prods, potprod)
              push!(dbgvals.lbls, Symbol(updvert.label))
            end
          end
        end
      end
      !dbg ? nothing : push!(mcmcdbg, dbgvals)
      # @info ""
    end

    # populate dictionary for return NBPMessage in multiple dispatch
    # TODO -- change to EasyMessage dict
    d = Dict{Int,EasyMessage}() # Array{Float64,2}
    for vertid in IDs
      vert = dlapi.getvertex(fgl,vertid)
      pden = getKDE(vert)
      bws = vec(getBW(pden)[:,1])
      d[vertid] = EasyMessage(getVal(vert), bws)
      # d[vertid] = getVal(dlapi.getvertex(fgl,vertid)) # fgl.v[vertid]
    end
    @info "fmcmc! -- finished on $(cliq.attributes["label"])"

    return mcmcdbg, d
end

function upPrepOutMsg!(d::Dict{Int,EasyMessage}, IDs::Array{Int,1}) #Array{Float64,2}
  @info "Outgoing msg density on: "
  len = length(IDs)
  m = NBPMessage(Dict{Int,EasyMessage}())
  for id in IDs
    m.p[id] = d[id]
  end
  return m
end

"""
    $(SIGNATURES)

Calculate a fresh---single step---approximation to the variable `sym` in clique `cliq` as though during the upward message passing.  The full inference algorithm may repeatedly calculate successive apprimxations to the variable based on the structure of variables, factors, and incoming messages to this clique.
Which clique to be used is defined by frontal variable symbols (`cliq` in this case) -- see `whichCliq(...)` for more details.  The `sym` symbol indicates which symbol of this clique to be calculated.  **Note** that the `sym` variable must appear in the clique where `cliq` is a frontal variable.
"""
function treeProductUp(fg::FactorGraph, tree::BayesTree, cliq::Symbol, sym::Symbol; N::Int=100, dbg::Bool=false )
  cliq = whichCliq(tree, cliq)
  cliqdata = getData(cliq)
  # IDS = [cliqdata.frontalIDs; cliqdata.conditIDs]

  # get the local variable id::Int identifier
  vertid = fg.IDs[sym]

  # get all the incoming (upward) messages from the tree cliques
  # convert incoming messages to Int indexed format (semi-legacy format)
  upmsgssym = NBPMessage[]
  for cl in childCliqs(tree, cliq)
    msgdict = upMsg(cl)
    dict = Dict{Int, EasyMessage}()
    for (dsy, btd) in msgdict
      dict[fg.IDs[dsy]] = convert(EasyMessage, btd)
    end
    push!( upmsgssym, NBPMessage(dict) )
  end

  # perform the actual computation
  pGM, potprod = cliqGibbs( fg, cliq, vertid, upmsgssym, N, dbg )

  return pGM, potprod
end


"""
    $(SIGNATURES)

Calculate a fresh---single step---approximation to the variable `sym` in clique `cliq` as though during the downward message passing.  The full inference algorithm may repeatedly calculate successive apprimxations to the variable based on the structure of variables, factors, and incoming messages to this clique.
Which clique to be used is defined by frontal variable symbols (`cliq` in this case) -- see `whichCliq(...)` for more details.  The `sym` symbol indicates which symbol of this clique to be calculated.  **Note** that the `sym` variable must appear in the clique where `cliq` is a frontal variable.
"""
function treeProductDwn(fg::FactorGraph,
                        tree::BayesTree,
                        cliq::Symbol,
                        sym::Symbol;
                        N::Int=100,
                        dbg::Bool=false  )
  #
  cliq = whichCliq(tree, cliq)
  cliqdata = getData(cliq)

  # get the local variable id::Int identifier
  vertid = fg.IDs[sym]

  # get all the incoming (upward) messages from the tree cliques
  # convert incoming messages to Int indexed format (semi-legacy format)
  cl = parentCliq(tree, cliq)
  msgdict = dwnMsg(cl[1])
  dict = Dict{Int, EasyMessage}()
  for (dsy, btd) in msgdict
      dict[fg.IDs[dsy]] = convert(EasyMessage, btd)
  end
  dwnmsgssym = NBPMessage[NBPMessage(dict);]

  # perform the actual computation
  pGM, potprod = cliqGibbs( fg, cliq, vertid, dwnmsgssym, N, dbg )

  return pGM, potprod, vertid, dwnmsgssym
end


"""
    $(SIGNATURES)

Perform computations required for the upward message passing during belief propation on the Bayes (Junction) tree.
This function is usually called as part via remote_call for multiprocess dispatch.
"""
function upGibbsCliqueDensity(inp::ExploreTreeType,
                              N::Int=200,
                              dbg::Bool=false,
                              api::DataLayerAPI=dlapi  )
    #
    @info "up w $(length(inp.sendmsgs)) msgs"
    # Local mcmc over belief functions
    # this is so slow! TODO Can be ignored once we have partial working
    # loclfg = nprocs() < 2 ? deepcopy(inp.fg) : inp.fg

    # TODO -- some weirdness with: d,. = d = ., nothing
    mcmcdbg = Array{CliqGibbsMC,1}()
    d = Dict{Int,EasyMessage}()

    priorprods = Vector{CliqGibbsMC}()

    cliqdata = getData(inp.cliq) #inp.cliq.attributes["data"]

    # use nested structure for more fficient Chapman-Kolmogorov solution approximation
    if false
      IDS = [cliqdata.frontalIDs;cliqdata.conditIDs] #inp.cliq.attributes["frontalIDs"]
      mcmcdbg, d = fmcmc!(inp.fg, inp.cliq, inp.sendmsgs, IDS, N, 3, dbg, api)
    else
      dummy, d = fmcmc!(inp.fg, inp.cliq, inp.sendmsgs, cliqdata.directFrtlMsgIDs, N, 1, dbg, api)
      if length(cliqdata.msgskipIDs) > 0
        dummy, dd = fmcmc!(inp.fg, inp.cliq, inp.sendmsgs, cliqdata.msgskipIDs, N, 1, dbg, api)
        for md in dd d[md[1]] = md[2]; end
      end
      # NOTE -- previous mistake, must iterate over directsvarIDs also
      if length(cliqdata.itervarIDs) > 0
        mcmcdbg, ddd = fmcmc!(inp.fg, inp.cliq, inp.sendmsgs, cliqdata.itervarIDs, N, 3, dbg, api)
        for md in ddd d[md[1]] = md[2]; end
      end
      if length(cliqdata.directPriorMsgIDs) > 0
        doids = setdiff(cliqdata.directPriorMsgIDs, cliqdata.msgskipIDs)
        priorprods, dddd = fmcmc!(inp.fg, inp.cliq, inp.sendmsgs, doids, N, 1, dbg, api)
        for md in dddd d[md[1]] = md[2]; end
      end
    end

    #m = upPrepOutMsg!(inp.fg, inp.cliq, inp.sendmsgs, condids, N)
    m = upPrepOutMsg!(d, cliqdata.conditIDs)

    outmsglbl = Dict{Symbol, Int}()
    if dbg
      for (ke, va) in m.p
        outmsglbl[Symbol(inp.fg.g.vertices[ke].label)] = ke
      end
    end

    upmsgs = Dict{Symbol, BallTreeDensity}()
    for (ke, va) in m.p
      msgsym = Symbol(inp.fg.g.vertices[ke].label)
      upmsgs[msgsym] = convert(BallTreeDensity, va)
    end
    setUpMsg!(inp.cliq, upmsgs)

    # Copy frontal variables back
    # for id in inp.cliq.attributes["frontalIDs"]
    #     inp.fg.v[id].attributes["val"] = loclfg.v[id].attributes["val"] # inp.
    # end
    # @show getVal(inp.fg.v[1])
    mdbg = !dbg ? DebugCliqMCMC() : DebugCliqMCMC(mcmcdbg, m, outmsglbl, priorprods)
    return UpReturnBPType(m, mdbg, d, upmsgs)
end
# else
#   rr = Array{Future,1}(4)
#   rr[1] = remotecall(upp2(), fmcmc!, inp.fg, inp.cliq, inp.sendmsgs, inp.cliq.attributes["directFrtlMsgIDs"], N, 1)
#   rr[2] = remotecall(upp2(), fmcmc!, inp.fg, inp.cliq, inp.sendmsgs, inp.cliq.attributes["msgskipIDs"], N, 1)
#   rr[3] = remotecall(upp2(), fmcmc!, inp.fg, inp.cliq, inp.sendmsgs, inp.cliq.attributes["itervarIDs"], N, 3)
#   rr[4] = remotecall(upp2(), fmcmc!, inp.fg, inp.cliq, inp.sendmsgs, inp.cliq.attributes["directvarIDs"], N, 1)
#   dummy, d = fetch(rr[1])
#   dummy, dd = fetch(rr[2])
#   mcmcdbg, ddd = fetch(rr[3])
#   dummy, dddd = fetch(rr[4])
#
#   for md in dd d[md[1]] = md[2]; end
#   for md in ddd d[md[1]] = md[2]; end
#   for md in dddd d[md[1]] = md[2]; end

function dwnPrepOutMsg(fg::FactorGraph, cliq::Graphs.ExVertex, dwnMsgs::Array{NBPMessage,1}, d::Dict{Int, EasyMessage}) #Array{Float64,2}
    # pack all downcoming conditionals in a dictionary too.
    if cliq.index != 1
      @info "Dwn msg keys $(keys(dwnMsgs[1].p))"
    end # ignore root, now incoming dwn msg
    @info "Outgoing msg density on: "
    m = NBPMessage(Dict{Int,EasyMessage}())
    i = 0
    for vid in cliq.attributes["data"].frontalIDs
      m.p[vid] = deepcopy(d[vid]) # TODO -- not sure if deepcopy is required
      # outp = kde!(d[vid], "lcv") # need to find new down msg bandwidths
      # # i+=1
      # # outDens[i] = outp
      # bws = vec((getBW(outp))[:,1])
      # m.p[vid] = EasyMessage(  deepcopy(d[vid]) , bws  )
    end
    for cvid in cliq.attributes["data"].conditIDs
        i+=1
        # TODO -- convert to points only since kde replace by rkhs in future
        # outDens[i] = cdwndict[cvid]
        # @info ""
        # info("Looking for cvid=$(cvid)")
        m.p[cvid] = deepcopy(dwnMsgs[1].p[cvid]) # TODO -- maybe this can just be a union(,)
    end
    return m
end

function downGibbsCliqueDensity(fg::FactorGraph,
                                cliq::Graphs.ExVertex,
                                dwnMsgs::Array{NBPMessage,1},
                                N::Int=200,
                                MCMCIter::Int=3,
                                dbg::Bool=false  )
    #
    # TODO standardize function call to have similar stride to upGibbsCliqueDensity
    @info "dwn"
    mcmcdbg, d = fmcmc!(fg, cliq, dwnMsgs, cliq.attributes["data"].frontalIDs, N, MCMCIter, dbg)
    m = dwnPrepOutMsg(fg, cliq, dwnMsgs, d)

    outmsglbl = Dict{Symbol, Int}()
    if dbg
      for (ke, va) in m.p
        outmsglbl[Symbol(fg.g.vertices[ke].label)] = ke
      end
    end

    # Always keep dwn messages in cliq data
    dwnkeepmsgs = Dict{Symbol, BallTreeDensity}()
    for (ke, va) in m.p
      msgsym = Symbol(fg.g.vertices[ke].label)
      dwnkeepmsgs[msgsym] = convert(BallTreeDensity, va)
    end
    setDwnMsg!(cliq, dwnkeepmsgs)

    mdbg = !dbg ? DebugCliqMCMC() : DebugCliqMCMC(mcmcdbg, m, outmsglbl, CliqGibbsMC[])
    return DownReturnBPType(m, mdbg, d, dwnkeepmsgs)
end

"""
    $(SIGNATURES)

Update cliq `cliqID` in Bayes (Juction) tree `bt` according to contents of `ddt` -- intended use is to update main clique after a downward belief propagation computation has been completed per clique.
"""
function updateFGBT!(fg::FactorGraph,
                     bt::BayesTree,
                     cliqID::Int,
                     ddt::DownReturnBPType;
                     dbg::Bool=false,
                     fillcolor::String="",
                     api::DataLayerAPI=dlapi  )
    # if dlapi.cgEnabled
    #   return nothing
    # end
    cliq = bt.cliques[cliqID]
    if dbg
      cliq.attributes["debugDwn"] = deepcopy(ddt.dbgDwn)
    end
    setDwnMsg!(cliq, ddt.keepdwnmsgs)
    if fillcolor != ""
      cliq.attributes["fillcolor"] = fillcolor
      cliq.attributes["style"] = "filled"
    end
    for dat in ddt.IDvals
      #TODO -- should become an update call
        updvert = api.getvertex(fg,dat[1])
        setValKDE!(updvert, deepcopy(dat[2])) # TODO -- not sure if deepcopy is required
        # updvert.attributes["latestEst"] = Statistics.mean(dat[2],2)
        api.updatevertex!(fg, updvert, updateMAPest=true)
    end
    nothing
end

"""
    $(SIGNATURES)

Update cliq `cliqID` in Bayes (Juction) tree `bt` according to contents of `urt` -- intended use is to update main clique after a upward belief propagation computation has been completed per clique.
"""
function updateFGBT!(fg::FactorGraph,
                     bt::BayesTree,
                     cliqID::Int,
                     urt::UpReturnBPType;
                     dbg::Bool=false,
                     fillcolor::String="",
                     api::DataLayerAPI=dlapi  )
# TODO -- use Union{} for two types, rather than separate functions
    # if dlapi.cgEnabled
    #   return nothing
    # end
    cliq = bt.cliques[cliqID]
    cliq = bt.cliques[cliqID]
    if dbg
      cliq.attributes["debug"] = deepcopy(urt.dbgUp)
    end
    setUpMsg!(cliq, urt.keepupmsgs)
    if fillcolor != ""
      cliq.attributes["fillcolor"] = fillcolor
      cliq.attributes["style"] = "filled"
    end
    for dat in urt.IDvals
      updvert = api.getvertex(fg,dat[1])
      setValKDE!(updvert, deepcopy(dat[2])) # (fg.v[dat[1]], ## TODO -- not sure if deepcopy is required
      api.updatevertex!(fg, updvert, updateMAPest=true)
    end
    @info "updateFGBT! up -- finished updating $(cliq.attributes["label"])"
    nothing
end

"""
    $(SIGNATURES)

Pass NBPMessages back down the tree -- pre order tree traversal.
"""
function downMsgPassingRecursive(inp::ExploreTreeType; N::Int=200, dbg::Bool=false, drawpdf::Bool=false)
    @info "====================== Clique $(inp.cliq.attributes["label"]) ============================="

    mcmciter = inp.prnt != Union{} ? 3 : 0; # skip mcmc in root on dwn pass
    rDDT = downGibbsCliqueDensity(inp.fg, inp.cliq, inp.sendmsgs, N, mcmciter, dbg) #dwnMsg
    updateFGBT!(inp.fg, inp.bt, inp.cliq.index, rDDT, dbg=dbg, fillcolor="pink")
    drawpdf ? drawTree(inp.bt) : nothing

    # rr = Array{Future,1}()
    pcs = procs()

    ddt=Union{}
    for child in out_neighbors(inp.cliq, inp.bt.bt)
        ett = ExploreTreeType(inp.fg, inp.bt, child, inp.cliq, [rDDT.dwnMsg])#inp.fg
        ddt = downMsgPassingRecursive( ett , N=N, dbg=dbg )
    end

    # return modifications to factorgraph to calling process
    return ddt
end

# post order tree traversal and build potential functions
function upMsgPassingRecursive(inp::ExploreTreeType; N::Int=200, dbg::Bool=false, drawpdf::Bool=false) #upmsgdict = Dict{Int, Array{Float64,2}}()
    @info "Start Clique $(inp.cliq.attributes["label"]) ============================="
    childMsgs = Array{NBPMessage,1}()

    len = length(out_neighbors(inp.cliq, inp.bt.bt))
    for child in out_neighbors(inp.cliq, inp.bt.bt)
        ett = ExploreTreeType(inp.fg, inp.bt, child, inp.cliq, NBPMessage[]) # ,Union{})
        @info "upMsgRec -- calling new recursive on $(ett.cliq.attributes["label"])"
        newmsgs = upMsgPassingRecursive(  ett, N=N, dbg=dbg ) # newmsgs
        @info "upMsgRec -- finished with $(ett.cliq.attributes["label"]), w $(keys(newmsgs.p)))"
        push!(  childMsgs, newmsgs )
    end

    @info "====================== Clique $(inp.cliq.attributes["label"]) ============================="
    ett = ExploreTreeType(inp.fg, inp.bt, inp.cliq, Union{}, childMsgs)

    urt = upGibbsCliqueDensity(ett, N, dbg) # upmsgdict
    updateFGBT!(inp.fg, inp.bt, inp.cliq.index, urt, dbg=dbg, fillcolor="lightblue")
    drawpdf ? drawTree(inp.bt) : nothing
    @info "End Clique $(inp.cliq.attributes["label"]) ============================="
    urt.upMsgs
end


function downGibbsCliqueDensity(inp::ExploreTreeType, N::Int=200, dbg::Bool=false)
  @info "=================== Iter Clique $(inp.cliq.attributes["label"]) ==========================="
  mcmciter = inp.prnt != Union{} ? 3 : 0
  return downGibbsCliqueDensity(inp.fg, inp.cliq, inp.sendmsgs, N, mcmciter, dbg)
end

function prepDwnPreOrderStack!(bt::BayesTree, parentStack::Array{Graphs.ExVertex,1})
  # dwn message passing function
  nodedata = Union{}
  tempStack = Array{Graphs.ExVertex,1}()
  push!(tempStack, parentStack[1])

  while ( length(tempStack) != 0 || nodedata != Union{} )
    if nodedata != Union{}
      for child in out_neighbors(nodedata, bt.bt) #nodedata.cliq, nodedata.bt.bt
          ## TODO -- don't yet have the NBPMessage results to propagate belief
          ## should only construct ett during processing
          push!(parentStack, child) #ett
          push!(tempStack, child) #ett
      end
      nodedata = Union{} # its over but we still need to complete computation in each of the leaves of the tree
    else
      nodedata = tempStack[1]
      deleteat!(tempStack, 1)
    end
  end
  nothing
end

function findVertsAssocCliq(fgl::FactorGraph, cliq::Graphs.ExVertex)

  cliqdata = getData(cliq)
  IDS = [cliqdata.frontalIDs; cliqdata.conditIDs] #inp.cliq.attributes["frontalIDs"]


  @error "findVertsAssocCliq -- not completed yet"
  nothing
end

function partialExploreTreeType(pfg::FactorGraph, pbt::BayesTree, cliqCursor::Graphs.ExVertex, prnt, pmsgs::Array{NBPMessage,1})
    # info("starting pett")
    # TODO -- expand this to grab only partial subsection from the fg and bt data structures


    if length(pmsgs) < 1
      return ExploreTreeType(pfg, pbt, cliqCursor, prnt, NBPMessage[])
    else
      return ExploreTreeType(pfg, pbt, cliqCursor, prnt, pmsgs)
    end
    nothing
end

function dispatchNewDwnProc!(fg::FactorGraph,
                             bt::BayesTree,
                             parentStack::Array{Graphs.ExVertex,1},
                             stkcnt::Int,
                             refdict::Dict{Int,Future};
                             N::Int=200,
                             dbg::Bool=false,
                             drawpdf::Bool=false  )
  #
  cliq = parentStack[stkcnt]
  while !haskey(refdict, cliq.index) # nodedata.cliq
    sleep(0.25)
  end

  rDDT = fetch(refdict[cliq.index]) #nodedata.cliq
  delete!(refdict,cliq.index) # nodedata

  if rDDT != Union{}
    updateFGBT!(fg, bt, cliq.index, rDDT, dbg=dbg, fillcolor="lightblue")
    drawpdf ? drawTree(bt) : nothing
  end

  emptr = BayesTree(Union{}, 0, Dict{Int,Graphs.ExVertex}(), Dict{String,Int}());

  for child in out_neighbors(cliq, bt.bt) # nodedata.cliq, nodedata.bt.bt
      haskey(refdict, child.index) ? error("dispatchNewDwnProc! -- why you already have dwnremoteref?") : nothing
      ett = partialExploreTreeType(fg, emptr, child, cliq, [rDDT.dwnMsg]) # bt
      refdict[child.index] = remotecall(downGibbsCliqueDensity, upp2() , ett, N) # Julia 0.5 swapped order
  end
  nothing
end

function processPreOrderStack!(fg::FactorGraph,
                               bt::BayesTree,
                               parentStack::Array{Graphs.ExVertex,1},
                               refdict::Dict{Int,Future};
                               N::Int=200,
                               dbg::Bool=false,
                               drawpdf::Bool=false )
  #
    # dwn message passing function for iterative tree exploration
    stkcnt = 0

    @sync begin
      sendcnt = 1:length(parentStack) # separate memory for remote calls
      for i in 1:sendcnt[end]
          @async dispatchNewDwnProc!(fg, bt, parentStack, sendcnt[i], refdict, N=N, dbg=dbg, drawpdf=drawpdf) # stkcnt ##pidxI,nodedata
      end
    end
    nothing
end

function downMsgPassingIterative!(startett::ExploreTreeType;
                                  N::Int=200,
                                  dbg::Bool=false,
                                  drawpdf::Bool=false  )
  #
  # this is where we launch the downward iteration process from
  parentStack = Array{Graphs.ExVertex,1}()
  refdict = Dict{Int,Future}()

  # start at the given clique in the tree -- shouldn't have to be the root.
  pett = partialExploreTreeType(startett.fg, startett.bt, startett.cliq,
                                        startett.prnt, startett.sendmsgs)
  refdict[startett.cliq.index] = remotecall(downGibbsCliqueDensity, upp2(), pett, N)  # for Julia 0.5

  push!(parentStack, startett.cliq ) # r

  prepDwnPreOrderStack!(startett.bt, parentStack)
  processPreOrderStack!(startett.fg, startett.bt, parentStack, refdict, N=N, dbg=dbg, drawpdf=drawpdf )

  @info "dwnward leftovers, $(keys(refdict))"
  nothing
end

function prepPostOrderUpPassStacks!(bt::BayesTree,
                                    parentStack::Array{Graphs.ExVertex,1},
                                    childStack::Array{Graphs.ExVertex,1}  )
  # upward message passing preparation
  while ( length(parentStack) != 0 )
      #2.1 Pop a node from first stack and push it to second stack
      cliq = parentStack[end]
      deleteat!(parentStack, length(parentStack))
      push!(childStack, cliq )

      #2.2 Push left and right children of the popped node to first stack
      for child in out_neighbors(cliq, bt.bt) # nodedata.cliq, nodedata.bt.bt
          push!(parentStack, child )
      end
  end
  for child in childStack
    @show child.attributes["label"]
  end
  nothing
end

# for up message passing -- per clique
function asyncProcessPostStacks!(fgl::FactorGraph,
                                 bt::BayesTree,
                                 chldstk::Vector{Graphs.ExVertex},
                                 stkcnt::Int,
                                 refdict::Dict{Int,Future};
                                 N::Int=200,
                                 dbg::Bool=false,
                                 drawpdf::Bool=false  )
  #
  if stkcnt == 0
    @info "asyncProcessPostStacks! ERROR stkcnt=0"
    error("asyncProcessPostStacks! stkcnt=0")
  end
  cliq = chldstk[stkcnt]
  gomulti = true
  @info "Start Clique $(cliq.attributes["label"]) ============================="
  childMsgs = Array{NBPMessage,1}()
  ur = nothing
  for child in out_neighbors(cliq, bt.bt)
      @info "asyncProcessPostStacks -- $(stkcnt), cliq=$(cliq.attributes["label"]), start on child $(child.attributes["label"]) haskey=$(haskey(child.attributes, "remoteref"))"

        # TODO make use proper conditional wait rather than sleep
        while !haskey(refdict, child.index)
          # info("Sleeping $(cliq.attributes["label"]) on lack of remoteref from $(child.attributes["label"])")
          # @show child.index, keys(refdict)
          sleep(0.25)
        end

      if gomulti
        ur = fetch(refdict[child.index])
      else
        ur = child.attributes["remoteref"]
      end
      updateFGBT!( fgl, bt, child.index, ur, dbg=dbg, api=localapi ) # new
      updateFGBT!( fgl, bt, child.index, ur, dbg=dbg, fillcolor="pink", api=dlapi ) # deep copies happen in the update function
      drawpdf ? drawTree(bt) : nothing
      #delete!(child.attributes, "remoteref")

      push!(childMsgs, ur.upMsgs)

  end
  @info "====================== Clique $(cliq.attributes["label"]) ============================="
  emptr = BayesTree(Union{}, 0, Dict{Int,Graphs.ExVertex}(), Dict{String,Int}());
  pett = partialExploreTreeType(fgl, emptr, cliq, Union{}, childMsgs) # bt   # parent cliq pointer is not needed here, fix Graphs.jl first

  if haskey(cliq.attributes, "remoteref")
      @info "asyncProcessPostStacks! -- WHY YOU ALREADY HAVE REMOTEREF?"
  end

  newprocid = upp2()
  if gomulti
    refdict[cliq.index] = remotecall( upGibbsCliqueDensity, newprocid, pett, N, dbg, localapi ) # swap order for Julia 0.5
  else
    # bad way to do non multi test
    cliq.attributes["remoteref"] = upGibbsCliqueDensity(pett, N, dbg)
  end

  # delete as late as possible, but could happen sooner
  for child in out_neighbors(cliq, bt.bt)
      # delete!(child.attributes, "remoteref")
      delete!(refdict, child.index)
  end

  @info "End Clique $(cliq.attributes["label"]) ============================="
  nothing
end


# upward belief propagation message passing function
function processPostOrderStacks!(fg::FactorGraph,
                                 bt::BayesTree,
                                 childStack::Array{Graphs.ExVertex,1};
                                 N::Int=200,
                                 dbg::Bool=false,
                                 drawpdf::Bool=false  )
  #

  refdict = Dict{Int,Future}()

  stkcnt = length(childStack)
  @sync begin
    sendcnt = stkcnt:-1:1 # separate stable memory
    for i in 1:stkcnt
        @async asyncProcessPostStacks!(fg, bt, childStack, sendcnt[i], refdict, N=N, dbg=dbg, drawpdf=drawpdf ) # deepcopy(stkcnt)
    end
  end
  @info "processPostOrderStacks! -- THIS ONLY HAPPENS AFTER SYNC"
  # we still need to fetch the root node computational output
  if true
    # blocking fetch on Future object
    ur = fetch(refdict[childStack[1].index])
  else
    ur = childStack[1].attributes["remoteref"]
  end
  # delete!(childStack[1].attributes, "remoteref") # childStack[1].cliq
  delete!(refdict, childStack[1].index)

  @info "upward leftovers, $(keys(refdict))"

  updateFGBT!(fg, bt, childStack[1].index, ur, dbg=dbg, api=localapi ) # new
  updateFGBT!(fg, bt, childStack[1].index, ur, dbg=dbg, fillcolor="pink", api=dlapi ) # nodedata
  drawpdf ? drawTree(bt) : nothing
  nothing
end

function upMsgPassingIterative!(startett::ExploreTreeType; N::Int=200, dbg::Bool=false, drawpdf::Bool=false)
  #http://www.geeksforgeeks.org/iterative-postorder-traversal/
  # this is where we launch the downward iteration process from
  parentStack = Array{Graphs.ExVertex,1}()
  childStack = Array{Graphs.ExVertex,1}()
  #Loop while first stack is not empty
  push!(parentStack, startett.cliq )
  # Starting at the root means we have a top down view of the tree
  prepPostOrderUpPassStacks!(startett.bt, parentStack, childStack)
  processPostOrderStacks!(startett.fg, startett.bt, childStack, N=N, dbg=dbg, drawpdf=drawpdf)
  nothing
end


function inferOverTree!(fgl::FactorGraph, bt::BayesTree; N::Int=200, dbg::Bool=false, drawpdf::Bool=false)
    @info "Ensure all nodes are initialized"
    ensureAllInitialized!(fgl)
    @info "Do multi-process inference over tree"
    cliq = bt.cliques[1]
    upMsgPassingIterative!(ExploreTreeType(fgl, bt, cliq, Union{}, NBPMessage[]),N=N, dbg=dbg, drawpdf=drawpdf);
    cliq = bt.cliques[1]
    downMsgPassingIterative!(ExploreTreeType(fgl, bt, cliq, Union{}, NBPMessage[]),N=N, dbg=dbg, drawpdf=drawpdf);
    nothing
end

function inferOverTreeR!(fgl::FactorGraph, bt::BayesTree; N::Int=200, dbg::Bool=false, drawpdf::Bool=false)
    @info "Ensure all nodes are initialized"
    ensureAllInitialized!(fgl)
    @info "Do recursive inference over tree"
    cliq = bt.cliques[1]
    upMsgPassingRecursive(ExploreTreeType(fgl, bt, cliq, Union{}, NBPMessage[]), N=N, dbg=dbg, drawpdf=drawpdf);
    cliq = bt.cliques[1]
    downMsgPassingRecursive(ExploreTreeType(fgl, bt, cliq, Union{}, NBPMessage[]), N=N, dbg=dbg, drawpdf=drawpdf);
    nothing
end
