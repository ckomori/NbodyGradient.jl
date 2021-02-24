import NbodyGradient: InitialConditions

#========== Integrator ==========#
abstract type AbstractIntegrator end

"""
    Integrator{T<:AbstractFloat}

Integrator. Used as a functor to integrate a [`State`](@ref).

# Fields
- `scheme::Function` : The integration scheme to use.
- `h::T` : Step size.
- `t0::T` : Initial time.
- `tmax::T` : Final time.
"""
mutable struct Integrator{T<:AbstractFloat} <: AbstractIntegrator
    scheme::Function
    h::T
    t0::T
    tmax::T
end

Integrator(h::T,t0::T) where T<:AbstractFloat = Integrator(ah18!,h,t0,t0+h)
Integrator(scheme::Function,h::Real,t0::Real,tmax::Real) = Integrator(scheme,promote(h,t0,tmax)...)

# Default to ah18!
Integrator(h::T,t0::T,tmax::T) where T<:AbstractFloat = Integrator(ah18!,h,t0,tmax)

#========== State ==========#
abstract type AbstractState end

"""
    State{T<:AbstractFloat} <: AbstractState

Current state of simulation.

# Fields (relevant to the user)
- `x::Matrix{T}` : Positions of each body [dimension, body].
- `v::Matrix{T}` : Velocities of each body [dimension, body].
- `t::Vector{T}` : Current time of simulation.
- `m::Vector{T}` : Masses of each body.
- `jac_step::Matrix{T}` : Current Jacobian.
- `dqdt::Vector{T}` : Derivative with respect to time.
"""
struct State{T<:AbstractFloat} <: AbstractState
    x::Matrix{T}
    v::Matrix{T}
    t::Vector{T}
    m::Vector{T}
    jac_step::Matrix{T}
    dqdt::Vector{T}
    jac_init::Matrix{T}
    xerror::Matrix{T}
    verror::Matrix{T}
    dqdt_error::Vector{T}
    jac_error::Matrix{T}
    n::Int64

    rij::Vector{T}
    a::Matrix{T}
    aij::Vector{T}
    x0::Vector{T}
    v0::Vector{T}
    input::Vector{T}
    delxv::Vector{T}
    rtmp::Vector{T}
end

"""
    State(ic)

Constructor for [`State`](@ref) type.

# Arguments
- `ic::InitialConditions{T}` : Initial conditions for the system.
"""
function State(ic::InitialConditions{T}) where T<:AbstractFloat
    x,v,jac_init = init_nbody(ic)
    n = ic.nbody
    xerror = zeros(T,size(x))
    verror = zeros(T,size(v))
    jac_step = Matrix{T}(I,7*n,7*n)
    dqdt = zeros(T,7*n)
    dqdt_error = zeros(T,size(dqdt))
    jac_error = zeros(T,size(jac_step))

    rij = zeros(T,3)
    a = zeros(T,3,n)
    aij = zeros(T,3)
    x0 = zeros(T,3)
    v0 = zeros(T,3)
    input = zeros(T,8)
    delxv = zeros(T,6)
    rtmp = zeros(T,3)
    return State(x,v,[ic.t0],ic.m,jac_step,dqdt,jac_init,xerror,verror,dqdt_error,jac_error,ic.nbody,
    rij,a,aij,x0,v0,input,delxv,rtmp)
end

function set_state!(s_old::State,s_new::State)
    fields = setdiff(fieldnames(State),[:m,:n])
    for fn in fields
        f_new = getfield(s_new,fn)
        f_old = getfield(s_old,fn)
        f_old .= f_new
    end
    return
end

"""Shows if the positions, velocities, and Jacobian are finite."""
Base.show(io::IO,::MIME"text/plain",s::State{T}) where {T} = begin
    println(io,"State{$T}:");
    println(io,"Positions  : ", all(isfinite.(s.x)) ? "finite" : "infinite!");
    println(io,"Velocities : ", all(isfinite.(s.v)) ? "finite" : "infinite!");
    println(io,"Jacobian   : ", all(isfinite.(s.jac_step)) ? "finite" : "infinite!");
    return
end

#========== Running Methods ==========#

"""
    (::Integrator)(s, time; grad=true)

Callable [`Integrator`](@ref) method. Integrate to specific time.

# Arguments
- `s::State{T}` : The current state of the simulation.
- `time::T` : Time to integrate to.

### Optional
- `grad::Bool` : Choose whether to calculate gradients. (Default = true)
"""
function (intr::Integrator)(s::State{T},time::T;grad::Bool=true) where T<:AbstractFloat
    t0 = s.t[1]

    # Calculate number of steps
    nsteps = abs(round(Int64,(time - t0)/intr.h))

    # Step either forward or backward
    h = intr.h * check_step(t0,time)

    # Calculate last step (if needed)
    #while t0 + (h * nsteps) <= time; nsteps += 1; end
    tmax = t0 + (h * nsteps)

    # Preallocate struct of arrays for derivatives (and pair)
    if grad; d = Derivatives(T,s.n); end
    pair = zeros(Bool,s.n,s.n)

    @timeit to "ah18 loop" begin
    for i in 1:nsteps
        # Take integration step and advance time
        if grad
            intr.scheme(s,d,h,pair)
        else
            intr.scheme(s,h,pair)
        end
    end
    end

    # Do last step (if needed)
    if nsteps == 0; hf = time; end
    if tmax != time
        hf = time - tmax
        if grad
            intr.scheme(s,d,hf,pair)
        else
            intr.scheme(s,hf,pair)
        end
    end

    s.t[1] = time
    return
end

"""
    (::Integrator)(s, N; grad=true)

Callable [`Integrator`](@ref) method. Integrate for N steps.

# Arguments
- `s::State{T}` : The current state of the simulation.
- `N::Int64` : Number of steps.

### Optional
- `grad::Bool` : Choose whether to calculate gradients. (Default = true)
"""
function (intr::Integrator)(s::State{T},N::Int64;grad::Bool=true) where T<:AbstractFloat
    s2 = zero(T) # For compensated summation

    # Preallocate struct of arrays for derivatives (and pair)
    if grad; d = Derivatives(T,s.n); end
    pair = zeros(Bool,s.n,s.n)

    # check to see if backward step
    if N < 0; intr.h *= -1; N *= -1; end
    h = intr.h

    for n in 1:N
        # Take integration step and advance time
        if grad
            intr.scheme(s,d,h,pair)
        else
            intr.scheme(s,h,pair)
        end
        s.t[1],s2 = comp_sum(s.t[1],s2,intr.h)
    end

    # Return time step to forward if needed
    if intr.h < 0; intr.h *= -1; end
    return
end

"""
    (::Integrator)(s; grad=true)

Callable [`Integrator`](@ref) method. Integrate to `tmax` -- specified in constructor.

# Arguments
- `s::State{T}` : The current state of the simulation.

### Optional
- `grad::Bool` : Choose whether to calculate gradients. (Default = true)
"""
(intr::Integrator)(s::State{T};grad::Bool=true) where T<:AbstractFloat = intr(s,intr.tmax,grad=grad)

function check_step(t0::T,tmax::T) where T<:AbstractFloat
    if abs(tmax) > abs(t0)
        return sign(tmax)
    else
        if sign(tmax) != sign(t0)
            return sign(tmax)
        else
            return -1 * sign(tmax)
        end
    end
end



#========== Includes  ==========#
const ints = ["ah18"]
for i in ints; include(joinpath(i,"$i.jl")); end

const ints_no_grad = ["ah18","dh17"]
for i in ints_no_grad; include(joinpath(i,"$(i)_no_grad.jl")); end
