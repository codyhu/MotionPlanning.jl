immutable RealVectorMetricSpace <: RealVectorStateSpace
    dim::Int
    lo::Vector
    hi::Vector
    dist::Metric
end

immutable GeometricProblem <: ProblemSetup
    init::Vector{Float64}
    goal::Goal
    obs::ObstacleSet
    V0::Vector{Vector{Float64}}
    SS::RealVectorMetricSpace
    config_name::String
end

### Bounded Euclidean State Space

BoundedEuclideanStateSpace(d::Int, lo::Vector, hi::Vector) = RealVectorMetricSpace(d, lo, hi, Euclidean())
UnitHypercube(d::Int) = BoundedEuclideanStateSpace(d, zeros(d), ones(d))

volume(SS::RealVectorMetricSpace) = prod(SS.hi-SS.lo)
steer(SS::RealVectorMetricSpace, v::Vector, w::Vector, eps::Float64, distvw = norm(w - v)) = v + (w - v) * min(eps/distvw, 1)

pairwise_distances{T}(V::Vector{Vector{T}}, SS::RealVectorMetricSpace, r_bound::Float64) = pairwise(SS.dist, hcat(V...))

### ADAPTIVE-SHORTCUT (Hsu 2000)

function shortcut{T}(path::Vector{Vector{T}}, obs::ObstacleSet)
    N = length(path)
    if N == 2
        return path
    end
    if is_free_motion(path[1], path[end], obs)
        return path[[1,end]]
    end
    mid = iceil(N/2)
    return [shortcut(path[1:mid], obs)[1:end-1], shortcut(path[mid:end], obs)]
end

function cut_corner(v1::Vector, v2::Vector, v3::Vector, obs::ObstacleSet)
    m1 = (v1 + v2)/2
    m2 = (v3 + v2)/2
    while ~is_free_motion(m1, m2, obs)
        m1 = (m1 + v2)/2
        m2 = (m2 + v2)/2
    end
    return typeof(v1)[v1, m1, m2, v3]
end

function adaptive_shortcut{T}(path::Vector{Vector{T}}, obs::ObstacleSet, iterations::Int = 10)
    while (short_path = shortcut(path, obs)) != path
        path = short_path
    end
    for i in 1:iterations
        path = [path[1:1], vcat([cut_corner(path[j-1:j+1]..., obs)[2:3] for j in 2:length(path)-1]...), path[end:end]]
        while (short_path = shortcut(path, obs)) != path
            path = short_path
        end
    end
    return path, sum(mapslices(norm, diff(hcat(path...), 2), 1))
end

### NEAREST NEIGHBOR STUFF

abstract MetricNN
type Neighborhood
    inds::Vector{Int}
    ds::Vector{Float64}
end
filter_neighborhood(n::Neighborhood, f::BitVector) = Neighborhood(n.inds[f[n.inds]], n.ds[f[n.inds]])

# immutable EuclideanNNBrute <: MetricNN
#     D::Matrix{Float64}
#     cache::Vector{Vector{Int}}
#     kNNr::Vector{Float64}
# end

immutable MetricNNKDTree <: MetricNN
    V::Vector{Vector{Float64}}
    KDT::KDTree
    cache::Vector{Neighborhood}
    kNNr::Vector{Float64}
end

# ## Brute

# function EuclideanNNBrute(V::Vector{Vector{Float64}})
#     return EuclideanNNBrute(pairwise(Euclidean(), hcat(V...)), fill(Int[], length(V)), zeros(length(V)))
# end

# function nearestr(NN::EuclideanNNBrute, v::Int, r::Float64, usecache::Bool = true)
#     if !usecache || isempty(NN.cache[v])
#         nn_bool = NN.D[:,v] .< r
#         nn_bool[v] = false
#         nn_idx = find(nn_bool)
#         if usecache
#             NN.cache[v] = nn_idx
#         end
#     else
#         nn_idx = NN.cache[v]
#     end
#     return nn_idx, NN.D[nn_idx, v]
# end

# function nearestk(NN::EuclideanNNBrute, v::Int, k::Int, usecache::Bool = true)
#     if !usecache || isempty(NN.cache[v])
#         r = select!(NN.D[:,v], k+1)
#         nn_bool = NN.D[:,v] .<= r
#         nn_bool[v] = false
#         nn_idx = find(nn_bool)
#         if usecache
#             NN.cache[v] = nn_idx
#             NN.kNNr[v] = r
#         end
#     else
#         nn_idx = NN.cache[v]
#     end
#     return nn_idx, NN.D[nn_idx, v]
# end

## KDTree

function MetricNNKDTree{T}(V::Vector{Vector{T}}, dist::Metric)
    return MetricNNKDTree(V,
                          KDTree(hcat(V...), dist),
                          Array(Neighborhood, length(V)),
                          zeros(length(V)))
end

function nearestk(NN::MetricNNKDTree, v::Int, k::Int)
    if !isdefined(NN.cache, v)
        inds, ds = nearest(NN.KDT, NN.V[v], k+1)
        x = findin(inds, v)
        deleteat!(inds, x)
        deleteat!(ds, x)
        NN.cache[v] = Neighborhood(inds, ds)
        NN.kNNr[v] = maximum(ds)
    end
    return NN.cache[v]
end

function nearestr(NN::MetricNNKDTree, v::Int, r::Float64)
    if !isdefined(NN.cache, v)
        inds, ds = inball(NN.KDT, NN.V[v], r)
        x = findin(inds, v)
        deleteat!(inds, x)
        deleteat!(ds, x)
        NN.cache[v] = Neighborhood(inds, ds)
    end
    return NN.cache[v]
end

## Both

nearestr(NN::MetricNN, v::Int, r::Float64, f::BitVector) = filter_neighborhood(nearestr(NN, v, r), f)
nearestk(NN::MetricNN, v::Int, k::Int, f::BitVector) = filter_neighborhood(nearestk(NN, v, k), f)
function mutualnearestk(NN::MetricNN, v::Int, k::Int, f::BitVector)
    n = nearestk(NN, v, k)
    for w in n.inds
        nearestk(NN, w, k)       # to ensure neighbors' respective nearest sets have been computed
    end
    mutual_inds = f[n.inds] & (n.ds .<= NN.kNNr[n.inds])
    return Neighborhood(n.inds[mutual_inds], n.ds[mutual_inds])
end

# ##

# function nearest1(w::Vector{Float64}, V::Vector{Vector{Float64}}, dist::Metric)
#     return findmin(colwise(dist, hcat(V...), w))
# end

# function nearestr(w::Vector{Float64}, V::Vector{Vector{Float64}}, r::Float64, dist::Metric)
#     D = colwise(dist, hcat(V...), w)
#     return D[D .< r], find(D .< r)
# end