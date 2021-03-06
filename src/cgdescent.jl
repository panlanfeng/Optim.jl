#### Conjugate gradient ####
# Syntax:
#    x, fval, fcount, converged = cgdescent(func, x0)
#    x, fval, fcount, converged = cgdescent(func, x0, options)
# Inputs:
#   x0 must be an array, but does not have to be a vector (this is useful
#     if the shape is meaningful to your objective function).
#   func must have syntax
#      val = func(g, x)
#   where g is storage for the gradient (or nothing, if the
#   gradient is not desired)
# Outputs:
#   x is the final setting of your input guess
#   fval is a vector of function values, one per linesearch (the first
#     is the initial function value)
#   fcount is the number of function evaluations
#   converged is true if the algorithm converged to the prescibed
#     tolerance, and false if it terminated due to an excessive number
#     of iterations.

# This is an independent implementation of:
#   W. W. Hager and H. Zhang (2006) Algorithm 851: CG_DESCENT, a
#     conjugate gradient method with guaranteed descent. ACM
#     Transactions on Mathematical Software 32: 113–137.
# Code comments such as "HZ, stage X" or "HZ, eqs Y" are with
# reference to a particular point in this paper.
# Several aspects of the following have also been incorporated:
#   W. W. Hager and H. Zhang (2012) The limited memory conjugate
#     gradient method.
# This paper will be denoted HZ2012 below.
#
# It's worth noting that, in addition to the modified update rule that
# guarantees descent, one of the attractions of this paper is its
# high-quality (and somewhat complex) line search algorithm.
# Naturally, can be used with other minimization routines, and indeed
# a related H&Z paper showed that it can speed the convergence of
# L-BFGS.

# There are some modifications and/or extensions from what's in the
# paper (these may or may not be extensions of the cg_descent code
# that can be downloaded from Hager's site; his code has undergone
# numerous revisions since publication of the paper):
#   cgdescent: the termination condition employs a "unit-correct"
#     expression rather than a condition on gradient
#     components---whether this is a good or bad idea will require
#     additional experience, but preliminary evidence seems to suggest
#     that it makes "reasonable" choices over a wider range of problem
#     types.
#   linesearch: the Wolfe conditions are checked only after alpha is
#     generated either by quadratic interpolation or secant
#     interpolation, not when alpha is generated by bisection or
#     expansion. This increases the likelihood that alpha will be a
#     good approximation of the minimum.
#   linesearch: In step I2, we multiply by psi2 only if the convexity
#     test failed, not if the function-value test failed. This
#     prevents one from going uphill further when you already know
#     you're already higher than the point at alpha=0.
#   both: checks for Inf/NaN function values
#   both: support maximum value of alpha (equivalently, c). This
#     facilitates using these routines for constrained minimization
#     when you can calculate the distance along the path to the
#     disallowed region. (When you can't easily calculate that
#     distance, it can still be handled by returning Inf/NaN for
#     exterior points. It's just more efficient if you know the
#     maximum, because you don't have to test values that won't
#     work.) The maximum should be specified as the largest value for
#     which a finite value will be returned.  See, e.g., limits_box
#     below.  The default value for alphamax is Inf. See alphamaxfunc
#     for cgdescent and alphamax for linesearch_hz.

cgdescent(func::Function, x) = cgdescent(func, x, Options())

function cgdescent{T}(func::Function, x::Array{T}, ops::Options)
    # Type declarations
    eta::T
    alpha::T
    tol::T
    # Default settings
    @defaults ops eta=0.4 display=0 alpha=nan(T) itermax=typemax(Int) fcountmax=typemax(Int) nfailuresmax=1000 iterfinitemax=20 tol=eps(T)^(2/3) alphamaxfunc=(x,d)->inf(T) reportfunc=val->val P=nothing precondprep=(P,x)->nothing
    # Don't modify inputs
    x = copy(x)
    ops = copy(ops)
    # Allocation of temporaries
    xtmp = similar(x)
    g = similar(x)
    pg = similar(x)    # preconditioned gradient
    d = similar(x)
    gold = similar(g)
    y = similar(g)
    N = length(x)
    iter = 1
    fcount = 1

    val::T = func(g, x)
    fval = [reportfunc(val)]
    if !isfinite(val)
        error("Must have finite starting value")
    end
    if !all(isfinite(g))
        @show g
        @show find(!isfinite(g))
        error("Gradient must have all finite values at starting point")
    end
    if display & ITER > 0
        # FIXME ndigits (6->width based on itermax & fcountmax)
        @printf("Iter     Evals    Function value   |step|\n")
        @printf("------   ------   --------------   --------------\n")
        @printf("%6d   %6d   %14e\n", iter, fcount, val)
    end

    precondprep(P, x)
    precondfwd(d, P, g)     # first iteration store the preconditioned gradient in d
    negate!(d)               # d -> -d
    copy!(gold, g)
    phi0 = val              # value at alpha=0
    dphi0 = dot(g, d)       # derivative at alpha=0
    if dphi0 == 0
        # We started at the minimum, return
        return x, fval, fcount, true
    end
    @assert dphi0 < 0
    alpha = cg_alphainit(alpha, x, g, val, ops)
    alphamax = alphamaxfunc(x, d)
    alpha = min(alphamax, alpha)
    @set_options ops alphamax=alphamax
    mayterminate = false
    converged = false
    # Define the line search function
    phi = (galpha, alpha) -> cg_linefunc(galpha, alpha, func, x, d, xtmp, g)
    lsr = LineSearchResults(T)
    push!(lsr, zero(T), phi0, dphi0)
    absstep = zero(T)
    while true
        valold = val   # save the previous value (avoiding reportfunc)
        if display & PARAMETERS > 0
            println("x: ", x)
        end
        if display & GRADIENT > 0
            println("gradient:   ", g)
        end
        if display & SEARCHDIR > 0
            println("search:     ", d)
        end
        alpha, val = cg_linesearch_hz(phi, lsr, alpha, mayterminate, ops)
        @assert isfinite(val)
        if display & ALPHA > 0
            println("alpha: ", alpha)
        end
        # xtmp contains the new point, g contains the gradient at that point
        copy!(x, xtmp)
        push!(fval, reportfunc(val))
        iter += 1
        fcount += length(lsr)-1
        # Test for termination (this differs from HZ eq 30; at least
        # here, it seems to make sense to be "unit-correct", i.e., to
        # make the criterion respect the possibility that different
        # parameters have different scaling/physical units)
        absstep = alpha*sum(abs(g.*d)) # has units of the function value
        if display & ITER > 0
            @printf("%6d   %6d   %14e %14e\n", iter, fcount, reportfunc(val), absstep)
        end
        fsum = abs(val) + abs(valold)
        if absstep <= tol*fsum/N || abs(val) < eps(max(max(abs(x)), max(abs(g))))
#        if norm2(g) <= tol^2
            converged = true
            break
        end
        if iter > itermax || fcount > fcountmax || lsr.nfailures > nfailuresmax
            break
        end
        # Calculate the beta factor (HZ2012)
        precondprep(P, x)
        dPd = precondinvdot(d, P, d)
        etak::T = eta*dot(d, gold)/dPd
        for i = 1:N
            y[i] = g[i]-gold[i]
        end
        copy!(gold, g)
        ydotd = dot(y, d)
        precondfwd(pg, P, g)
        betak = (dot(y, pg) - precondfwddot(y, P, y)*dot(d,g)/ydotd)/ydotd
        beta = max(betak, etak)
        if display & BETA > 0
            println("beta: ", beta)
        end
        # Generate the new search direction
        update_d!(d, beta, pg)  # for some reason this needs a separate function to be optimized
        # Define the new line search function
        phi = (galpha, alpha) -> cg_linefunc(galpha, alpha, func, x, d, xtmp, g)
        phi0 = val              # value at alpha=0
        dphi0 = dot(g, d)     # derivative at alpha=0
        if !(dphi0 < 0)
            for i = 1:N
                d[i] = -g[i]  # reset
            end
            dphi0 = dot(g, d)     # derivative at alpha=0
            if !(dphi0 < 0)
                println(dphi0)
            end
            @assert dphi0 < 0
        end
        clear!(lsr)
        push!(lsr, zero(T), phi0, dphi0)
        # Pick the initial step size (HZ #I1-I2)
        alphamax = alphamaxfunc(x, d)
        ops[:alphamax] = alphamax
        if !(alphamax > 0)
            println("An edge point has been reached (alphamax = ", alphamax, ") and no further progress can be achieved, because the search direction points out of the valid region.")
            break
        end
        alpha, mayterminate = cg_alphatry(alpha, phi, lsr, ops)
        fcount += 1
    end
    if display & FINAL > 0
        if converged
            print("Converged")
        else
            print("Did not converge")
        end
        println(" after ", length(fval), " iterations, final function value = ", fval[end], ", last |step| = ", absstep)
    end
    if lsr.nfailures > 0 && display > 0
        println("There were ", lsr.nfailures, " function evaluations that failed to produce a finite result.")
    end
    @check_used ops
    return x, fval, fcount, converged
end
export cgdescent

function update_d!(d, beta, pg)
    for i = 1:length(d)
        d[i] = beta*d[i] - pg[i]
    end
end

# Generate initial guess for step size (HZ, stage I0)
function cg_alphainit{T}(alpha, x::Array{T}, g, val, ops)
    psi0::T
    @defaults ops psi0=0.01
    if isnan(alpha)
        alpha = 1
        gmax = max(abs(g))
        if gmax != 0
            xmax = max(abs(x))
            if xmax != 0
                alpha = psi0*xmax/gmax
            elseif val != 0
                alpha = psi0*abs(val)/norm2(g)
            end
        end
    end
    @check_used ops
    return alpha
end

function cg_alphatry{T}(alpha::T, phi::Function, lsr::LineSearchResults, ops::Options)
    psi1::T
    psi2::T
    psi3::T
    alphamax::T
    @defaults ops psi1=0.2 psi2=2 psi3=0.1 iterfinitemax=iceil(-log2(eps(T))) alphamax=Inf display=0
    phi0 = lsr.value[1]
    dphi0 = lsr.slope[1]
    alphatest = psi1*alpha
    alphatest = min(alphatest, alphamax)
    phitest = phi(nothing, alphatest)
    iterfinite = 1
    while !isfinite(phitest)
        alphatest = psi3*alphatest
        phitest = phi(nothing, alphatest)
        lsr.nfailures += 1
        iterfinite += 1
        if iterfinite >= iterfinitemax
            error("Failed to achieve finite test value")
        end
    end
    a = (phitest - alphatest*dphi0 - phi0)/alphatest^2 # quadratic fit
    if display & ALPHAGUESS > 0
        println("quadfit: alphatest = ", alphatest, ", phi0 = ", phi0, ", phitest = ", phitest, ", quadcoef = ", a)
    end
    mayterminate = false
    if a > 0 && phitest <= phi0
        alpha = -dphi0/2/a  # if convex, choose minimum of quadratic
        if alpha == 0
            error("alpha is zero. dphi0 = ", dphi0, ", a = ", a)
        end
        if alpha <= alphamax
            mayterminate = true
        else
            alpha = alphamax
            mayterminate = false
        end
        if display & ALPHAGUESS > 0
            println("alpha guess (quadratic): ", alpha, ", (mayterminate = ", mayterminate, ")")
        end
    else
        if phitest > phi0
            alpha = alphatest
        else
            alpha *= psi2       # if not convex, expand the interval
        end
    end
    alpha = min(alphamax, alpha)
    if display & ALPHAGUESS > 0
        println("alpha guess (expand): ", alpha)
    end
    @check_used ops
    return alpha, mayterminate
end


function cg_linesearch_hz{T}(phi::Function, lsr::LineSearchResults{T}, c::T, mayterminate::Bool, ops::Options)
    # Type declarations
    delta::T
    sigma::T
    alphamax::T
    rho::T
    epsilon::T
    gamma::T
    psi3::T
    @defaults ops delta=DEFAULTDELTA sigma=DEFAULTSIGMA alphamax=inf(T) rho=5 epsilon=1e-6 gamma=0.66 linesearchmax=50 psi3=0.1 iterfinitemax=iceil(-log2(eps(T))) display=0
    phi0 = lsr.value[1]
    dphi0 = lsr.slope[1]
    philim = phi0 + epsilon*abs(phi0)
    gphi = Array(T, 1)
    @assert c > 0
    @assert isfinite(c) && c <= alphamax
    phic = phi(gphi, c)
    iterfinite = 1
    while !isfinite(phic) && iterfinite < iterfinitemax
        mayterminate = false
        lsr.nfailures += 1
        iterfinite += 1
        c *= psi3
        phic = phi(gphi, c)
    end
    if !isfinite(phic)
        println("Warning: failed to achieve finite new evaluation point, using alpha=0")
        @check_used ops
        return zero(T), phi0
    end
    dphic = gphi[1]
    push!(lsr, c, phic, dphic)
    # If c was generated by quadratic interpolation, check whether it
    # satisfies the Wolfe conditions
    if mayterminate && cg_satisfies_wolfe(c, phic, dphic, phi0, dphi0, philim, delta, sigma)
        if display & LINESEARCH > 0
            println("Wolfe condition satisfied on point alpha = ", c)
        end
        @check_used ops
        return c, phic
    end
    # Initial bracketing step (HZ, stages B0-B3)
    isbracketed = false
    ia = 1
    ib = 2
    @assert length(lsr) == 2
    iter = 1
    cold = -one(T)
    while !isbracketed && iter < linesearchmax
        if display & BRACKET > 0
            println("bracketing: ia = ", ia, ", ib = ", ib, ", c = ", c, ", phic = ", phic, ", dphic = ", dphic)
        end
        if dphic >= 0
            # We've reached the upward slope, so we have b; examine
            # previous values to find a
            ib = length(lsr)
            for i = ib-1:-1:1
                if lsr.value[i] <= philim
                    ia = i
                    break
                end
            end
            isbracketed = true
        elseif lsr.value[end] > philim
            # The value is higher, but the slope is downward, so we must
            # have crested over the peak. Use bisection.
            ib = length(lsr)
            ia = ib-1
            if c != lsr.alpha[ib] || lsr.slope[ib] >= 0
                error("c = ", c, ", lsr = ", lsr)
            end
            ia, ib = cg_bisect(phi, lsr, ia, ib, philim, ops)
            isbracketed = true
        else
            # We'll still going downhill, expand the interval and try again
            cold = c
            c *= rho
            if c > alphamax
                if display & BRACKET > 0
                    println("bracket: exceeding alphamax, truncating")
                end
                c = alphamax
            end
            phic = phi(gphi, c)
            iterfinite = 1
            while !isfinite(phic) && c > cold && iterfinite < iterfinitemax
                lsr.nfailures += 1
                iterfinite += 1
                if display & BRACKET > 0
                    println("bracket: non-finite value, bisection")
                end
                c = (cold+c)/convert(T, 2)
                phic = phi(gphi, c)
            end
            dphic = gphi[1]
            if (dphic < 0 && c == alphamax) || !isfinite(phic)
                # We're on the edge of the allowed region, and the
                # value is still decreasing. This can be due to
                # roundoff error in barrier penalties, a barrier
                # coefficient being so small that being eps() away
                # from it still doesn't turn the slope upward, or
                # mistakes in the user's function.
                if iterfinite >= iterfinitemax
                    println("Warning: failed to expand interval to bracket with finite values. If this happens frequently, check your function and gradient.")
                    println("c = ", c, ", alphamax = ", alphamax, ", phic = ", phic, ", dphic = ", dphic)
                end
                ic = length(lsr)
                while !isfinite(phic)
                    ic -= 1
                    c = lsr.alpha[ic]
                    phic = lsr.value[ic]
                    if isfinite(phic)
                        println("Using c = ", c, ", phic = ", phic)
                    end
                    # Re-evaluate at current position. This is important if
                    # reportfunc makes use of cached storage, and that cache
                    # has been corrupted by NaN/Inf
                    phic = phi(gphi, c)
                end
                @check_used ops
                return c, phic
            end
            push!(lsr, c, phic, dphic)
        end
        iter += 1
    end
    while iter < linesearchmax
        a = lsr.alpha[ia]
        b = lsr.alpha[ib]        
        @assert b>a
        if display & LINESEARCH > 0
            println("linesearch: ia = ", ia, ", ib = ", ib, ", a = ", a, ", b = ", b, ", phi(a) = ", lsr.value[ia], ", phi(b) = ", lsr.value[ib])
        end
        if b-a <= eps(b)
            @check_used ops
            return a, lsr.value[ia]
        end
        iswolfe, iA, iB = cg_secant2(phi, lsr, ia, ib, philim, ops)
        if iswolfe
            @check_used ops
            return lsr.alpha[iA], lsr.value[iA]
        end
        A = lsr.alpha[iA]
        B = lsr.alpha[iB]
        @assert B>A
        if B-A < gamma*(b-a)
            if display & LINESEARCH > 0
                println("Linesearch: secant succeeded")
            end
            ia = iA
            ib = iB
        else
            # Secant is converging too slowly, use bisection
            if display & LINESEARCH > 0
                println("Linesearch: secant failed, using bisection")
            end
            c = (A+B)/convert(T, 2)
            phic = phi(gphi, c)
            @assert isfinite(phic)
            dphic = gphi[1]
            push!(lsr, c, phic, dphic)
            ia, ib = cg_update(phi, lsr, iA, iB, length(lsr), philim, ops)
        end
        iter += 1
    end
    error("Linesearch failed to converge")
end

# Check Wolfe & approximate Wolfe
cg_satisfies_wolfe{T<:Number}(c::T, phic, dphic, phi0, dphi0, philim, delta, sigma) = (delta*dphi0 >= (phic - phi0)/c && dphic >= sigma*dphi0) || ((2*delta-1)*dphi0 >= dphic >= sigma*dphi0 && phic <= philim)

# HZ, stages S1-S4
cg_secant(a, b, dphia, dphib) = (a*dphib - b*dphia)/(dphib - dphia)
cg_secant(lsr::LineSearchResults, ia::Int, ib::Int) = cg_secant(lsr.alpha[ia], lsr.alpha[ib], lsr.slope[ia], lsr.slope[ib])
function cg_secant2{T}(phi::Function, lsr::LineSearchResults{T}, ia::Int, ib::Int, philim, ops::Options)
    @defaults ops delta=DEFAULTDELTA sigma=DEFAULTSIGMA display=0
    phi0 = lsr.value[1]
    dphi0 = lsr.slope[1]
    a = lsr.alpha[ia]
    b = lsr.alpha[ib]
    dphia = lsr.slope[ia]
    dphib = lsr.slope[ib]
    @assert dphia < 0
    @assert dphib >= 0
    c = cg_secant(a, b, dphia, dphib)
    if display & SECANT2 > 0
        println("secant2: a = ", a, ", b = ", b, ", c = ", c)
    end
    @assert isfinite(c)
    tmpc = Array(T, 1)
    phic = phi(tmpc, c)
    @assert isfinite(phic)
    dphic = tmpc[1]
    push!(lsr, c, phic, dphic)
    ic = length(lsr)
    if satisfies_wolfe(c, phic, dphic, phi0, dphi0, philim, delta, sigma)
        if display & SECANT2 > 0
            println("secant2: first c satisfied Wolfe conditions")
        end
        return true, ic, ic
    end
    iA, iB = cg_update(phi, lsr, ia, ib, ic, philim, ops)
    if display & SECANT2 > 0
        println("secant2: iA = ", iA, ", iB = ", iB, ", ic = ", ic)
    end
    a = lsr.alpha[iA]
    b = lsr.alpha[iB]
    doupdate = false
    if iB == ic
        # we updated b, make sure we also update a
        c = cg_secant(lsr, ib, iB)
    elseif iA == ic
        # we updated a, do it for b too
        c = cg_secant(lsr, ia, iA)
    end
    if a <= c <= b
        if display & SECANT2 > 0
            println("secant2: second c = ", c)
        end
        phic = phi(tmpc, c)
        @assert isfinite(phic)
        dphic = tmpc[1]
        push!(lsr, c, phic, dphic)
        ic = length(lsr)
        if cg_satisfies_wolfe(c, phic, dphic, phi0, dphi0, philim, delta, sigma)
            if display & SECANT2 > 0
                println("secant2: second c satisfied Wolfe conditions")
            end
            return true, ic, ic
        end
        iA, iB = cg_update(phi, lsr, iA, iB, ic, philim, ops)
    end
    if display & SECANT2 > 0
        println("secant2 output: a = ", lsr.alpha[iA], ", b = ", lsr.alpha[iB])
    end
    return false, iA, iB
end

# HZ, stages U0-U3
# Given a third point, pick the best two that retain the bracket
# around the minimum (as defined by HZ, eq. 29)
# b will be the upper bound, and a the lower bound
function cg_update(phi::Function, lsr::LineSearchResults, ia::Int, ib::Int, ic::Int, philim, ops::Options)
    @defaults ops display=0
    a = lsr.alpha[ia]
    b = lsr.alpha[ib]
    # Debugging (HZ, eq. 4.4):
    @assert lsr.slope[ia] < 0
    @assert lsr.value[ia] <= philim
    @assert lsr.slope[ib] >= 0
    @assert b>a
    c = lsr.alpha[ic]
    phic = lsr.value[ic]
    dphic = lsr.slope[ic]
    if display & UPDATE > 0
        println("update: ia = ", ia, ", a = ", a, ", ib = ", ib, ", b = ", b, ", c = ", c, ", phic = ", phic, ", dphic = ", dphic)
    end
    if c < a || c > b
        return ia, ib  # it's out of the bracketing interval
    end
    if dphic >= 0
        return ia, ic  # replace b with a closer point
    end
    # We know dphic < 0. However, phi may not be monotonic between a
    # and c, so check that the value is also smaller than phi0.  (It's
    # more dangerous to replace a than b, since we're leaving the
    # secure environment of alpha=0; that's why we didn't check this
    # above.)
    if phic <= philim
        return ic, ib  # replace a
    end
    # phic is bigger than phi0, which implies that the minimum
    # lies between a and c. Find it via bisection.
    cg_bisect(phi, lsr, ia, ic, philim, ops)
end

# HZ, stage U3 (with theta=0.5)
function cg_bisect{T}(phi::Function, lsr::LineSearchResults{T}, ia::Int, ib::Int, philim, ops::Options)
    @defaults ops display=0
    gphi = Array(T, 1)
    a = lsr.alpha[ia]
    b = lsr.alpha[ib]
    # Debugging (HZ, conditions shown following U3)
    @assert lsr.slope[ia] < 0
    @assert lsr.value[ia] <= philim
    @assert lsr.slope[ib] < 0       # otherwise we wouldn't be here
    @assert lsr.value[ib] > philim
    @assert b>a
    while b-a > eps(b)
        if display & BISECT > 0
            println("bisect: a = ", a, ", b = ", b, ", b-a = ", b-a)
        end
        d = (a+b)/convert(T, 2)
        phid = phi(gphi, d)
        @assert isfinite(phid)
        dphid = gphi[1]
        push!(lsr, d, phid, dphid)
        id = length(lsr)
        if dphid >= 0
#            @check_used ops  # no need to check, since others are using it
            return ia, id  # replace b, return
        end
        if phid <= philim
            a = d  # replace a, but keep bisecting until dphib > 0
            ia = id
        else
            b = d
            ib = id
        end
    end
    return ia, ib
end

# Define one-parameter function for line searches
function cg_linefunc(gphi, alpha, func, x, d, xtmp, g)
    calc_grad = !(gphi === nothing)
    for i = 1:length(x)
        xtmp[i] = x[i] + alpha*d[i]
    end
    if calc_grad
        val = func(g, xtmp)
        if isfinite(val)
            gtmp = g[1]*d[1]
            for i = 2:length(g)
                gtmp += g[i]*d[i]
            end
            gphi[1] = gtmp
        else
            gphi[1] = nan(eltype(gphi))
        end
    else
        val = func(nothing, xtmp)
    end
    return val
end

function negate!(A::Array)
    for i = 1:length(A)
        A[i] = -A[i]
    end
end

## Preconditioners
# Empty preconditioner
precondfwd(out::Array, P::Nothing, A::Array) = copy!(out, A)
precondfwddot(A::Array, P::Nothing, B::Array) = dot(A, B)
precondinvdot(A::Array, P::Nothing, B::Array) = dot(A, B)

# Diagonal preconditioner
function precondfwd(out::Array, p::Vector, A::Array)
    for i = 1:length(A)
        out[i] = p[i]*A[i]
    end
    out
end
function precondfwddot(A::Array, p::Vector, B::Array)
    s = zero(eltype(A))
    for i = 1:length(A)
        s += A[i]*p[i]*B[i]
    end
    s
end
function precondinvdot(A::Array, p::Vector, B::Array)
    s = zero(eltype(A))
    for i = 1:length(A)
        s += A[i]*B[i]/p[i]
    end
    s
end
