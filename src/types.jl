immutable OptimizationState
    iteration::Int
    value::Float64
    gradnorm::Float64
    metadata::Dict
end

function OptimizationState(i::Integer, f::Real)
    OptimizationState(int(i), float64(f), NaN, Dict())
end

function OptimizationState(i::Integer, f::Real, g::Real)
    OptimizationState(int(i), float64(f), float64(g), Dict())
end

immutable OptimizationTrace
    states::Vector{OptimizationState}
end

OptimizationTrace() = OptimizationTrace(Array(OptimizationState, 0))

abstract OptimizationResults

type MultivariateOptimizationResults{T} <: OptimizationResults
    method::ASCIIString
    initial_x::Vector{T}
    minimum::Vector{T}
    f_minimum::Float64
    iterations::Int
    iteration_converged::Bool
    x_converged::Bool
    xtol::Float64
    f_converged::Bool
    ftol::Float64
    gr_converged::Bool
    grtol::Float64
    trace::OptimizationTrace
    f_calls::Int
    g_calls::Int
end

immutable DifferentiableFunction
    f::Function
    g!::Function
    fg!::Function
end

immutable TwiceDifferentiableFunction
    f::Function
    g!::Function
    fg!::Function
    h!::Function
end

function Base.show(io::IO, t::OptimizationState)
    @printf io "%6d   %14e   %14e\n" t.iteration t.value t.gradnorm
    if !isempty(t.metadata)
        for (key, value) in t.metadata
            @printf io " * %s: %s\n" key value
        end
    end
    return
end

Base.push!(t::OptimizationTrace, s::OptimizationState) = push!(t.states, s)

Base.getindex(t::OptimizationTrace, i::Integer) = getindex(t.states, i)

function Base.setindex!(t::OptimizationTrace,
                        s::OptimizationState,
                        i::Integer)
    setindex!(t.states, s, i)
end

function Base.show(io::IO, t::OptimizationTrace)
    @printf io "Iter     Function value   Gradient norm \n"
    @printf io "------   --------------   --------------\n"
    for state in t.states
        show(io, state)
    end
    return
end

function converged(r::MultivariateOptimizationResults)
    return r.x_converged || r.f_converged || r.gr_converged
end

function Base.show(io::IO, r::MultivariateOptimizationResults)
    @printf io "Results of Optimization Algorithm\n"
    @printf io " * Algorithm: %s\n" r.method
    @printf io " * Starting Point: %s\n" string(r.initial_x)
    @printf io " * Minimum: %s\n" string(r.minimum)
    @printf io " * Value of Function at Minimum: %f\n" r.f_minimum
    @printf io " * Iterations: %d\n" r.iterations
    @printf io " * Convergence: %s\n" converged(r)
    @printf io "   * |x - x'| < %.1e: %s\n" r.xtol r.x_converged
    @printf io "   * |f(x) - f(x')| / |f(x)| < %.1e: %s\n" r.ftol r.f_converged
    @printf io "   * |g(x)| < %.1e: %s\n" r.grtol r.gr_converged
    @printf io "   * Exceeded Maximum Number of Iterations: %s\n" r.iteration_converged
    @printf io " * Objective Function Calls: %d\n" r.f_calls
    @printf io " * Gradient Call: %d" r.g_calls
    return
end

# TODO: Expose ability to do forward and backward differencing
function DifferentiableFunction(f::Function)
    function g!(x::Vector, storage::Vector)
        Calculus.finite_difference!(f, x, storage, :central)
        return
    end
    function fg!(x::Vector, storage::Vector)
        g!(x, storage)
        return f(x)
    end
    return DifferentiableFunction(f, g!, fg!)
end

function DifferentiableFunction(f::Function, g!::Function)
    function fg!(x::Vector, storage::Vector)
        g!(x, storage)
        return f(x)
    end
    return DifferentiableFunction(f, g!, fg!)
end

function TwiceDifferentiableFunction(f::Function)
    function g!(x::Vector, storage::Vector)
        Calculus.finite_difference!(f, x, storage, :central)
        return
    end
    function fg!(x::Vector, storage::Vector)
        g!(x, storage)
        return f(x)
    end
    function h!(x::Vector, storage::Matrix)
        Calculus.finite_difference_hessian!(f, x, storage)
        return
    end
    return TwiceDifferentiableFunction(f, g!, fg!, h!)
end

function TwiceDifferentiableFunction(f::Function,
                                     g!::Function,
                                     h!::Function)
    function fg!(x::Vector, storage::Vector)
        g!(x, storage)
        return f(x)
    end
    return TwiceDifferentiableFunction(f, g!, fg!, h!)
end

# A cache for results from line search methods (to avoid recomputation)
type LineSearchResults{T}
    alpha::Vector{T}
    value::Vector{T}
    slope::Vector{T}
    nfailures::Int
end

LineSearchResults{T}(::Type{T}) = LineSearchResults(T[], T[], T[], 0)

Base.length(lsr::LineSearchResults) = length(lsr.alpha)

function Base.push!{T}(lsr::LineSearchResults{T}, a::T, v::T, d::T)
    push!(lsr.alpha, a)
    push!(lsr.value, v)
    push!(lsr.slope, d)
    return
end

function clear!(lsr::LineSearchResults)
    empty!(lsr.alpha)
    empty!(lsr.value)
    empty!(lsr.slope)
    return
    # nfailures is deliberately not set to 0
end
