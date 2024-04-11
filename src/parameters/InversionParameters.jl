export InversionParameters

mutable struct InversionParameters{F<:AbstractFloat} <: AbstractParameters
    initial_conditions::Vector{F}
    lower_bound::Vector{F}
    upper_bound::Vector{F}
    regions_split::Vector{Int}
    x_tol::F
    f_tol::F
    solver::Any  
end

"""
    InversionParameters{F<:AbstractFloat}(;
        initial_conditions::Vector{F} = [1.0],
        lower_bound::Vector{F} = [0.0],
        upper_bound::Vector{F} = [Inf],
        regions_split::Vector{Int} = [1, 1],
        x_tol::F = 1.0e-3,
        f_tol::F = 1.0e-3,
        solver = BFGS()
    )

Initialize the parameters for the inversion process.

# Arguments
- `initial_conditions`: Starting point for optimization.
- `lower_bound`: Lower bounds for optimization variables.
- `upper_bound`: Upper bounds for optimization variables.
- `regions_split`: Defines the amount of region split based on altitude and distance to border for the inversion process.
- `x_tol`: Tolerance for variables convergence.
- `f_tol`: Tolerance for function value convergence.
- `solver`: Optimization solver to be used.
"""
function InversionParameters{}(;
        initial_conditions::Vector{F} = [1.0],
        lower_bound::Vector{F} = [0.0],
        upper_bound::Vector{F} = [Inf],
        regions_split::Vector{Int} = [1, 1],
        x_tol::F = 1.0e-3,
        f_tol::F = 1.0e-3,
        solver = BFGS()
    ) where F <: AbstractFloat
    inversionparameters = InversionParameters{F}(initial_conditions, lower_bound, upper_bound, regions_split, x_tol, f_tol, solver)
    
    return inversionparameters
end

Base.:(==)(a::InversionParameters, b::InversionParameters) = 
    a.initial_conditions == b.initial_conditions &&
    a.lower_bound == b.lower_bound &&
    a.upper_bound == b.upper_bound &&
    a.regions_split == b.regions_split &&
    a.x_tol == b.x_tol &&
    a.f_tol == b.f_tol