## Environment and packages
using Distributed
const processes = 4

if nprocs() < processes
    addprocs(processes - nprocs(); exeflags="--project")
end

println("Number of cores: ", nprocs())
println("Number of workers: ", nworkers())

@everywhere begin 
using Statistics
using LinearAlgebra
using Random 
using OrdinaryDiffEq
using DiffEqFlux
using Flux
using Distributed
using Tullio
using RecursiveArrayTools
using Infiltrator
using Plots

const t₁ = 5                 # number of simulation years 
const ρ = 900f0                     # Ice density [kg / m^3]
const g = 9.81f0                    # Gravitational acceleration [m / s^2]
const n = 3f0                       # Glen's flow law exponent
const maxA = 8f-16
const minA = 3f-17
const maxT = 1f0
const minT = -25f0
A = 1.3f-24 #2e-16  1 / Pa^3 s
A *= Float32(60 * 60 * 24 * 365.25) # [1 / Pa^3 yr]
C = 0
α = 0

@views avg(A) = 0.25 .* ( A[1:end-1,1:end-1] .+ A[2:end,1:end-1] .+ A[1:end-1,2:end] .+ A[2:end,2:end] )
@views avg_x(A) = 0.5 .* ( A[1:end-1,:] .+ A[2:end,:] )
@views avg_y(A) = 0.5 .* ( A[:,1:end-1] .+ A[:,2:end] )
@views diff_x(A) = (A[begin + 1:end, :] .- A[1:end - 1, :])
@views diff_y(A) = (A[:, begin + 1:end] .- A[:, 1:end - 1])
@views inn(A) = A[2:end-1,2:end-1]
end # @everything 

function generate_ref_dataset(temp_series, H₀, ensemble=ensemble)
    # Compute reference dataset in parallel
    H = deepcopy(H₀)
    
    # Initialize all matrices for the solver
    S, dSdx, dSdy = zeros(Float32,nx,ny),zeros(Float32,nx-1,ny),zeros(Float32,nx,ny-1)
    dSdx_edges, dSdy_edges, ∇S = zeros(Float32,nx-1,ny-2),zeros(Float32,nx-2,ny-1),zeros(Float32,nx-1,ny-1)
    D, dH, Fx, Fy = zeros(Float32,nx-1,ny-1),zeros(Float32,nx-2,ny-2),zeros(Float32,nx-1,ny-2),zeros(Float32,nx-2,ny-1)
    V, Vx, Vy = zeros(Float32,nx-1,ny-1),zeros(Float32,nx-1,ny-1),zeros(Float32,nx-1,ny-1)
    
    # Gather simulation parameters
    current_year = 0
    context = ArrayPartition([A], B, S, dSdx, dSdy, D, copy(temp_series[5]), dSdx_edges, dSdy_edges, ∇S, Fx, Fy, Vx, Vy, V, C, α, [current_year])

    function prob_iceflow_func(prob, i, repeat, context, temp_series) # closure
        
        println("Processing temp series #$i ≈ ", mean(temp_series[i]))
        context.x[7] .= temp_series[i] # We set the temp_series for the ith trajectory

        # iceflow_PDE_batch!(dH, H, p, t) = iceflow!(dH, H, context, t) # closure
        return remake(prob, p=context)
    end

    prob_func(prob, i, repeat) = prob_iceflow_func(prob, i, repeat, context, temp_series) # closure

    # Perform reference simulation with forward model 
    println("Running forward PDE ice flow model...\n")
    iceflow_prob = ODEProblem(iceflow!,H,(0.0,t₁),context)
    ensemble_prob = EnsembleProblem(iceflow_prob, prob_func = prob_func)
    iceflow_sol = solve(ensemble_prob, BS3(), ensemble, trajectories = length(temp_series), 
                        pmap_batch_size=length(temp_series), reltol=1e-6, 
                        progress=true, saveat=1.0, progress_steps = 50)

    return Float32.(iceflow_sol)  
end

function train_iceflow_UDE(H₀, UA, H_refs, temp_series)
    H = deepcopy(H₀)
    current_year = 0f0
    θ = initial_params(UA)
    # Tuple with all the temp series and H_refs
    context = (B, H, current_year, temp_series)
    loss(θ) = loss_iceflow(θ, context, UA, H_refs) # closure

    # @infiltrate
    println("Gradients: ", gradient(loss, θ))

    # println("Training iceflow UDE...")
    # iceflow_trained = DiffEqFlux.sciml_train(loss, θ, RMSProp(0.01f0), cb=callback, maxiters = 10)

    # return iceflow_trained
end

callback = function (θ,l) # callback function to observe training
    @show l
    false
  end

function loss_iceflow(θ, context, UA, H_refs) 
    H_preds = predict_iceflow(θ, UA, context)

    A_pred = predict_A̅(UA, θ, [mean(temp_series[5])])
    A_ref = A_fake(mean(temp_series[5]))
    println("Predicted A: ", A_pred)
    println("True A: ", A_ref)

    # Zygote.ignore() do 
    #     @infiltrate
    # end

    H = H_preds.u[end]
    H_ref = H_refs[5][end]

    l_H_avg = Flux.Losses.mse(H[H .!= 0.0], H_ref[H.!= 0.0]; agg=mean)

    # # Compute loss function for the full batch
    # l_H = 0.0
    # for (H_pred, H_ref) in zip(H_preds, H_refs)
    #     H = H_pred.u[end]
    #     l_H += Flux.Losses.mse(H[H .!= 0.0], H_ref[end][H.!= 0.0]; agg=mean)
    # end

    # l_H_avg = l_H/length(H_preds)
    
    return l_H_avg
end


function predict_iceflow(θ, UA, context, ensemble=ensemble)

    function prob_iceflow_func(prob, i, repeat, context, UA) # closure
        # B, H, current_year, temp_series)  
        temp_series = context[4]
    
        println("Processing temp series #$i ≈ ", mean(temp_series[i]))
        # We add the ith temperature series 
        iceflow_UDE_batch!(dH, H, θ, t) = iceflow_NN!(dH, H, θ, t, context, temp_series[i], UA) # closure
        
        return remake(prob, f=iceflow_UDE_batch!)
    end

    prob_func(prob, i, repeat) = prob_iceflow_func(prob, i, repeat, context, UA)

    # (B, H, current_year, temp_series, batch_idx)
    H = context[2]
    tspan = (0.0,t₁)

    iceflow_UDE!(dH, H, θ, t) = iceflow_NN!(dH, H, θ, t, context, temp_series[5], UA) # closure
    iceflow_prob = ODEProblem(iceflow_UDE!,H,tspan,θ)
    ensemble_prob = EnsembleProblem(iceflow_prob, prob_func = prob_func)

    # H_pred = solve(ensemble_prob, BS3(), ensemble, trajectories = length(temp_series), 
    #                 pmap_batch_size=length(temp_series), u0=H, p=θ, reltol=1e-6, 
    #                 sensealg = InterpolatingAdjoint(autojacvec=ZygoteVJP()), save_everystep=false, 
    #                 progress=true, progress_steps = 50)

    H_pred = solve(iceflow_prob, BS3(), u0=H, p=θ, reltol=1e-6, 
                    sensealg = InterpolatingAdjoint(autojacvec=ZygoteVJP()), save_everystep=false, 
                    progress=true, progress_steps = 50)

    return H_pred
end

function iceflow!(dH, H, context,t)
    # Unpack parameters
    #A, B, S, dSdx, dSdy, D, temps, dSdx_edges, dSdy_edges, ∇S, Fx, Fy, Vx, Vy, V, C, α, current_year 
    current_year = Ref(context.x[18])
    A = Ref(context.x[1])
    
    # Get current year for MB and ELA
    year = floor(Int, t) + 1
    if year != current_year[] && year <= t₁
        temp = Ref{Float32}(context.x[7][year])
        A[] .= A_fake(temp[])
        current_year[] .= year
    end

    # Compute the Shallow Ice Approximation in a staggered grid
    SIA!(dH, H, context)
end    

function iceflow_NN!(dH, H, θ, t, context, temps, UA)
    # ArrayPartition(B, H, current_year, temp_series, batch_idx) 

    # year = floor(Int, t) + 1
    # if year <= t₁
    #     temp = temps[year]
    # else
    #     temp = temps[year-1]
    # end
    temp = temps[1]

    A = predict_A̅(UA, θ, [temp]) # FastChain prediction requires explicit parameters

    # Compute the Shallow Ice Approximation in a staggered grid
    dH .= SIA(dH, H, A, context)
    # println("dH: ", maximum(dH))
end  

"""
    SIA(H, p)

Compute a step of the Shallow Ice Approximation PDE in a forward model
"""

function SIA!(dH, H, context)
    # Retrieve parameters
    #A, B, S, dSdx, dSdy, D, norm_temps, dSdx_edges, dSdy_edges, ∇S, Fx, Fy, Vx, Vy, V, C, α, current_year, H_ref, H, UA, θ
    A = context.x[1]
    B = context.x[2]
    S = context.x[3]
    dSdx = context.x[4]
    dSdy = context.x[5]
    D = context.x[6]
    dSdx_edges = context.x[8]
    dSdy_edges = context.x[9]
    ∇S = context.x[10]
    Fx = context.x[11]
    Fy = context.x[12]
    
    # Update glacier surface altimetry
    S .= B .+ H

    # All grid variables computed in a staggered grid
    # Compute surface gradients on edges
    dSdx .= diff_x(S) / Δx
    dSdy .= diff_y(S) / Δy
    ∇S .= (avg_y(dSdx).^2 .+ avg_x(dSdy).^2).^((n - 1)/2) 

    Γ = 2 * A * (ρ * g)^n / (n+2) # 1 / m^3 s 
    D .= Γ .* avg(H).^(n + 2) .* ∇S

    # Compute flux components
    dSdx_edges .= diff(S[:,2:end - 1], dims=1) / Δx
    dSdy_edges .= diff(S[2:end - 1,:], dims=2) / Δy
    Fx .= .-avg_y(D) .* dSdx_edges
    Fy .= .-avg_x(D) .* dSdy_edges 

    #  Flux divergence
    inn(dH) .= .-(diff(Fx, dims=1) / Δx .+ diff(Fy, dims=2) / Δy) # MB to be added here 
end

# Function without mutation for Zygote, with context as an ArrayPartition
function SIA(dH, H, A, context)
    # Retrieve parameters
    B = context[1]

    # Update glacier surface altimetry
    S = B .+ H

    # All grid variables computed in a staggered grid
    # Compute surface gradients on edges
    dSdx = diff_x(S) / Δx
    dSdy = diff_y(S) / Δy
    ∇S = (avg_y(dSdx).^2 .+ avg_x(dSdy).^2).^((n - 1)/2) 

    Γ = 2 * A * (ρ * g)^n / (n+2) # 1 / m^3 s 
    D = Γ .* avg(H).^(n + 2) .* ∇S

    # Compute flux components
    dSdx_edges = diff(S[:,2:end - 1], dims=1) / Δx
    dSdy_edges = diff(S[2:end - 1,:], dims=2) / Δy
    Fx = .-avg_y(D) .* dSdx_edges
    Fy = .-avg_x(D) .* dSdy_edges 

    #  Flux divergence
    @tullio dH[i,j] := -(diff(Fx, dims=1)[pad(i-1,1,1),pad(j-1,1,1)] / Δx + diff(Fy, dims=2)[pad(i-1,1,1),pad(j-1,1,1)] / Δy) # MB to be added here 

    return dH
end


function A_fake(temp)
    return @. minA + (maxA - minA) * ((temp-minT)/(maxT-minT) )^2
end

predict_A̅(UA, θ, temp) = UA(temp, θ)[1] .* 1e-16

function fake_temp_series(t, means=Array{Float32}([0,-2.0,-3.0,-5.0,-10.0,-12.0,-14.0,-15.0,-20.0]))
    temps, norm_temps, norm_temps_flat = [],[],[]
    for mean in means
       push!(temps, mean .+ rand(t).*1f-1) # static
       append!(norm_temps_flat, mean .+ rand(t).*1f-1) # static
    end

    # Normalise temperature series
    norm_temps_flat = Flux.normalise([norm_temps_flat...]) # requires splatting

    # Re-create array of arrays 
    for i in 1:t₁:length(norm_temps_flat)
        push!(norm_temps, norm_temps_flat[i:i+(t₁-1)])
    end

    return temps, norm_temps
end

##################################################
#### Generate reference dataset ####
##################################################
@everywhere begin
nx = ny = 100
const B = zeros(Float32, (nx, ny))
const σ = 1000
H₀ = Matrix{Float32}([ 250 * exp( - ( (i - nx/2)^2 + (j - ny/2)^2 ) / σ ) for i in 1:nx, j in 1:ny ])    
Δx = Δy = 50 #m   
ensemble = EnsembleSerial()
end # @everywhere

const temp_series, norm_temp_series =  fake_temp_series(t₁)
const H_refs = generate_ref_dataset(temp_series, H₀)

# Train UDE
minA_out = 0.3
maxA_out = 8
sigmoid_A(x) = minA_out + (maxA_out - minA_out) / ( 1 + exp(-x) )
UA = FastChain(
        FastDense(1,3, x->tanh.(x)),
        FastDense(3,10, x->tanh.(x)),
        FastDense(10,3, x->tanh.(x)),
        FastDense(3,1, sigmoid_A)
    )

# Train iceflow UDE with in parallel
train_iceflow_UDE(H₀, UA, H_refs, temp_series)
