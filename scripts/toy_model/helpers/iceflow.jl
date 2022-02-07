
@everywhere begin
@views avg(A) = 0.25 .* ( A[1:end-1,1:end-1] .+ A[2:end,1:end-1] .+ A[1:end-1,2:end] .+ A[2:end,2:end] )
@views avg_x(A) = 0.5 .* ( A[1:end-1,:] .+ A[2:end,:] )
@views avg_y(A) = 0.5 .* ( A[:,1:end-1] .+ A[:,2:end] )
@views diff_x(A) = (A[begin + 1:end, :] .- A[1:end - 1, :])
@views diff_y(A) = (A[:, begin + 1:end] .- A[:, 1:end - 1])
@views inn(A) = A[2:end-1,2:end-1]
end # @everywhere 

@everywhere begin
function prob_iceflow_PDE(H, temps, context) 
        
    println("Processing temp series ≈ ", mean(temps))
    context.x[7] .= temps # We set the temp_series for the ith trajectory

    iceflow_prob = ODEProblem(iceflow!,H,(0.0,t₁),context)
    iceflow_sol = solve(iceflow_prob, solver,
                    reltol=1e-6, save_everystep=false, 
                    progress=true, progress_steps = 10)

    V̄x, V̄y = context[13]./length(iceflow_sol.t), context[14]./length(iceflow_sol.t)

    return iceflow_sol, V̄x, V̄y 
end
end # @everywhere

function generate_ref_dataset(temp_series, H₀)
    # Compute reference dataset in parallel
    H = deepcopy(H₀)
    
    # Initialize all matrices for the solver
    S, dSdx, dSdy = zeros(Float64,nx,ny),zeros(Float64,nx-1,ny),zeros(Float64,nx,ny-1)
    dSdx_edges, dSdy_edges, ∇S = zeros(Float64,nx-1,ny-2),zeros(Float64,nx-2,ny-1),zeros(Float64,nx-1,ny-1)
    D, dH, Fx, Fy = zeros(Float64,nx-1,ny-1),zeros(Float64,nx-2,ny-2),zeros(Float64,nx-1,ny-2),zeros(Float64,nx-2,ny-1)
    V, Vx, Vy = zeros(Float64,nx-1,ny-1),zeros(Float64,nx-1,ny-1),zeros(Float64,nx-1,ny-1)
    A = 2e-16
    α = 0                       # Weertman-type basal sliding (Weertman, 1964, 1972). 1 -> sliding / 0 -> no sliding
    C = 15e-14                  # Sliding factor, between (0 - 25) [m⁸ N⁻³ a⁻¹]
    
    # Gather simulation parameters
    current_year = 0
    context = ArrayPartition([A], B, S, dSdx, dSdy, D, copy(temp_series[5]), dSdx_edges, dSdy_edges, ∇S, Fx, Fy, Vx, Vy, V, C, α, [current_year])

    # Perform reference simulation with forward model 
    println("Running forward PDE ice flow model...\n")
    # Train batches in parallel
    iceflow_sol, V̄x_refs, V̄y_refs  = @showprogress pmap(temps -> prob_iceflow_PDE(H, temps, context), temp_series)

    # Save only matrices
    idx = 1
    H_refs = [] 
    for result in iceflow_sol
        if idx == 1
            H_refs = result.u[end]
        else
            @views H_refs = cat(H_refs, result.u[end], dims=3)
        end
        idx += 1
    end

    return H_refs, V̄x_refs, V̄y_refs
end

function train_iceflow_UDE(H₀, UA, θ, train_settings, H_refs, temp_series)
    H = deepcopy(H₀)
    optimizer = train_settings[1]
    epochs = train_settings[2]
    # Tuple with all the temp series and H_refs
    context = (B, H)
    loss(θ) = loss_iceflow(θ, context, UA, H_refs, temp_series) # closure

    println("Training iceflow UDE...")
    # println("Using solver: ", solver)
    iceflow_trained = DiffEqFlux.sciml_train(loss, θ, optimizer, cb=callback, maxiters = epochs)

    return iceflow_trained
end

@everywhere begin 

callback = function (θ,l) # callback function to observe training
    println("Epoch #$current_epoch - Loss H: ", l)

    pred_A = predict_A̅(UA, θ, collect(-20.0:0.0)')
    pred_A = [pred_A...] # flatten
    true_A = A_fake(-20.0:0.0, noise)

    scatter(-20.0:0.0, true_A, label="True A")
    plot_epoch = plot!(-20.0:0.0, pred_A, label="Predicted A", 
                        xlabel="Long-term air temperature (°C)",
                        ylabel="A", ylims=(2e-17,8e-16),
                        legend=:topleft)
    savefig(plot_epoch,joinpath(root_plots,"training","epoch$current_epoch.png"))
    global current_epoch += 1

    false
end

function loss_iceflow(θ, context, UA, H_refs, temp_series) 
    H_preds = predict_iceflow(θ, UA, context, temp_series)
    
    # Compute loss function for the full batch
    l_H = 0.0

    for i in 1:length(H_preds)
        H_ref = H_refs[:,:,i]
        H = H_preds[i].u[end] 
        l_H += Flux.Losses.mse(H[H .!= 0.0], H_ref[H.!= 0.0]; agg=mean)
    end

    l_H_avg = l_H/length(H_preds)

    return l_H_avg
end

function predict_iceflow(θ, UA, context, temp_series)

    # (B, H, current_year)
    H = context[2]

    # Train UDE in parallel
    H_preds = pmap(temps -> prob_iceflow_UDE(θ, H, temps, context, UA), temp_series)

    return H_preds
end

function prob_iceflow_UDE(θ, H, temps, context, UA) 
        
    # println("Processing temp series ≈ ", mean(temps))
    iceflow_UDE_batch(H, θ, t) = iceflow_NN(H, θ, t, context, temps, UA) # closure
    iceflow_prob = ODEProblem(iceflow_UDE_batch,H,(0.0,t₁),θ)
    iceflow_sol = solve(iceflow_prob, solver, u0=H, p=θ,
                    reltol=1e-6, save_everystep=false, 
                    progress=true, progress_steps = 10)

    return iceflow_sol 
end

function iceflow!(dH, H, context,t)
    # Unpack parameters
    #A, B, S, dSdx, dSdy, D, temps, dSdx_edges, dSdy_edges, ∇S, Fx, Fy, Vx, Vy, V, C, α, current_year 
    current_year = Ref(context.x[18])
    A = Ref(context.x[1])
    
    # Get current year for MB and ELA
    year = floor(Int, t) + 1
    if year != current_year[] && year <= t₁
        temp = Ref{Float64}(context.x[7][year])
        A[] .= A_fake(temp[], noise)
        current_year[] .= year
    end

    # Compute the Shallow Ice Approximation in a staggered grid
    SIA!(dH, H, context)
end    

function iceflow_NN(H, θ, t, context, temps, UA)

    year = floor(Int, t) + 1
    if year <= t₁
        temp = temps[year]
    else
        temp = temps[year-1]
    end

    A = predict_A̅(UA, θ, [temp]) # FastChain prediction requires explicit parameters

    # Compute the Shallow Ice Approximation in a staggered grid
    return SIA(H, A, context)
end  

"""
    SIA!(dH, H, context)

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
    Vx = context.x[13]
    Vy = context.x[14]
    # V = context.x[15]
    
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
    dSdx_edges .= diff_x(S[:,2:end - 1]) / Δx
    dSdy_edges .= diff_y(S[2:end - 1,:]) / Δy
    Fx .= .-avg_y(D) .* dSdx_edges
    Fy .= .-avg_x(D) .* dSdy_edges 

    # Compute cumulative velocities. They will be averaged afterwards
    Vx .= Vx .+ -D./(avg(H) .+ ϵ).*avg_y(dSdx)
    Vy .= Vy .+ -D./(avg(H) .+ ϵ).*avg_x(dSdy)

    #  Flux divergence
    inn(dH) .= .-(diff_x(Fx) / Δx .+ diff_y(Fy) / Δy) # MB to be added here 
end

# Function without mutation for Zygote, with context as an ArrayPartition
function SIA(H, A, context)
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
    dSdx_edges = diff_x(S[:,2:end - 1]) / Δx
    dSdy_edges = diff_y(S[2:end - 1,:]) / Δy
    Fx = .-avg_y(D) .* dSdx_edges
    Fy = .-avg_x(D) .* dSdy_edges 

    #  Flux divergence
    @tullio dH[i,j] := -(diff_x(Fx)[pad(i-1,1,1),pad(j-1,1,1)] / Δx + diff_y(Fy)[pad(i-1,1,1),pad(j-1,1,1)] / Δy) # MB to be added here 

    return dH
end


function A_fake(temp, noise=false)
    A = @. minA + (maxA - minA) * ((temp-minT)/(maxT-minT) )^2
    if noise
        A = A .+ randn(rng_seed(), length(temp)).*4e-17
    end

    return A
end

predict_A̅(UA, θ, temp) = UA(temp, θ) .* 1e-16

function fake_temp_series(t, means=Array{Float64}([0,-2.0,-3.0,-5.0,-10.0,-12.0,-14.0,-15.0,-20.0]))
    temps, norm_temps, norm_temps_flat = [],[],[]
    for mean in means
       push!(temps, mean .+ rand(t).*1e-1) # static
       append!(norm_temps_flat, mean .+ rand(t).*1e-1) # static
    end

    # Normalise temperature series
    norm_temps_flat = Flux.normalise([norm_temps_flat...]) # requires splatting

    # Re-create array of arrays 
    for i in 1:t₁:length(norm_temps_flat)
        push!(norm_temps, norm_temps_flat[i:i+(t₁-1)])
    end

    return temps, norm_temps
end

end # @everywhere 