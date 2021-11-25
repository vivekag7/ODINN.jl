# -*- coding: utf-8 -*-
# ##################################################################
# ##   Functions for PDE solving in staggered grids with UDEs   ####
# ##################################################################

using Zygote
using PaddedViews
using Flux
using Flux: @epochs
using Tullio
include("utils.jl")

# Patch suggested by Michael Abbott needed in order to correctly retrieve gradients
Flux.Optimise.update!(opt, x::AbstractMatrix, Δ::AbstractVector) = Flux.Optimise.update!(opt, x, reshape(Δ, size(x)))

function ref_dataset(temps, gref, H₀, t)
      
    tempn = mean(temps)
    println("Reference simulation with temp ≈ ", tempn)
    glacier_ref = deepcopy(gref)
    H = deepcopy(H₀)
    # Gather simulation parameters
    p = (Δx, Δy, Γ, A, B, temps, C, α) 
    # Perform reference imulation with forward model 
    H, V̂ = iceflow!(H,glacier_ref,p,t,t₁)
    
    #push!(glacier_refs, glacier_ref)
    
    #println("glacier_refs: ", length(glacier_refs))

    ### Glacier ice thickness evolution  ### Not that useful
    # hm11 = heatmap(H₀, c = :ice, title="Ice thickness (t=0)")
    # hm12 = heatmap(H, c = :ice, title="Ice thickness (t=$t₁)")
    # hm1 = Plots.plot(hm11,hm12, layout=2, aspect_ratio=:equal, size=(800,350),
    #     colorbar_title="Ice thickness (m)",
    #     clims=(0,maximum(H₀)), link=:all)
    # display(hm1)

    ###  Glacier ice thickness difference  ###
    lim = maximum( abs.(H .- H₀) )
    hm2 = heatmap(H .- H₀, c = cgrad(:balance,rev=true), aspect_ratio=:equal,
        clim = (-lim, lim),
        title="Variation in ice thickness")
    
    #if x11 
    #    display(hm2) 
    #end
    
    tempn = floor(tempn)
    savefig(hm2,joinpath(root_dir,"plots/references","reference_$tempn.png"))

    return glacier_ref

end


"""
    iceflow_UDE!(H₀,glacier_ref,UA,hyparams,trackers, p,t,t₁)

Hybrid ice flow model solving and optimizing the Shallow Ice Approximation (SIA) PDE using 
Universal Differential Equations (UDEs)
"""
function iceflow_UDE!(H₀,glacier_ref,UA,hyparams,trackers, p,t,t₁)

    # We define an optimizer
    opt = RMSProp(hyparams.η)
    # opt = ADAM(hyparams.η)
    #opt = BFGS(hyparams.η)

    # Train the UDE for a given number of epochs
    hybrid_train!(trackers, hyparams, glacier_ref, UA, opt, H₀, p, t, t₁)
    # @epochs hyparams.epochs hybrid_train!(trackers, glacier_ref, UA, opt, H₀, p, t, t₁)

end

"""
    hybrid_train!(trackers, hyparams, glacier_ref, UA, opt, H₀, p, t, t₁)

Train hybrid ice flow model based on UDEs.
"""
function hybrid_train!(trackers, hyparams, glacier_ref, UA, opt, H₀, p, t, t₁)
    # Retrieve model parameters
    θ = Flux.params(UA)
    # println("Resetting initial H state")
    H = deepcopy(H₀) # Make sure we go back to the original initial state for each epoch

    # println("Forward pass")
    loss_UA, back_UA = Zygote.pullback(() -> loss(H, glacier_ref, UA, p, t, t₁), θ) # with UA

    # Save gradients from current batch
    push!(trackers["grad_batch"], back_UA)
    push!(trackers["losses_batch"], loss_UA)


    # loss_UA, back_UA = Zygote.pullback(A -> loss(H, A, p, t, t₁), A) # inverse problem 

    # ∇_UA = back_UA(one(loss_UA))[1] # inverse problem

    # for ps in θ
    #    println("Gradients ∇_UA[ps]: ", ∇_UA[ps])
    # end
    # println("Gradients ∇_UA: ", ∇_UA)

    # println("Predicted A: ", predict_A̅(UA, [mean(p[6])]'))

    # Only update NN weights after batch completion 
    if(trackers["current_batch"] == hyparams.batchsize)
 
        println("Backpropagation...")
        # We update the weights with the gradients of all tha glaciers in the batch
        # This is equivalent to taking the gradient with respect of the full loss function
        for i in 1:hyparams.batchsize
            back_UA = trackers["grad_batch"][i]
            ∇_UA = back_UA(1)
            println("#$i Updating NN weights")
            Flux.Optimise.update!(opt, θ, ∇_UA) # with UA
        end

        #∇_UA = back_UA(one(mean(trackers["losses_batch"]))) # with UA
        #println("Updating NN weights")
        #Flux.Optimise.update!(opt, θ, ∇_UA) # with UA
        
        # Keep track of the loss function per batch
        push!(trackers["losses"], mean(trackers["losses_batch"]))

        # Clear trackers for current finished batch
        trackers["grad_batch"] = nothing
        trackers["grad_batch"] = []
        trackers["losses_batch"] = nothing
        trackers["losses_batch"] = []

        # Plot progress of the loss function 
        # temp_values = LinRange(-25, 0, 20)'
        # plot(temp_values', A_fake.(temp_values)', label="Fake A")
        # pfunc = scatter!(temp_values', predict_A̅(UA, temp_values)', yaxis="A", xaxis="Air temperature (°C)", label="Trained NN", color="red")
        # ploss = plot(trackers["losses"], title="Loss", xlabel="Epoch", aspect=:equal)
        # display(plot(pfunc, ploss, layout=(2,1)))
  
    end

    # Flux.Optimise.update!(opt, A, ∇_UA) # inverse problem
    # Δx, Δy, Γ, A, B, v, MB, MB_avg, C, α, var_format = p # unpack
    # p = (Δx, Δy, Γ, ŶA, B, v, MB, MB_avg, C, α, var_format) # repack

end

"""
    loss(H, glacier_ref, UA, p, t, t₁)

Computes the loss function for a specific batch
"""
# We determine the loss function
function loss(H, glacier_ref, UA, p, t, t₁)
  
    H, V̂ = iceflow!(H, UA, p,t,t₁)

    l_H = sqrt(Flux.Losses.mse(H[H .!= 0.0], glacier_ref["H"][end][H.!= 0.0]; agg=sum))

    # l_V = sqrt(Flux.Losses.mse(V̂[V̂ .!= 0.0], mean(glacier_ref["V"])[V̂ .!= 0.0]; agg=sum))

    println("l_H: ", l_H)
    # println("l_V: ", l_V)

    # Zygote.ignore() do
    # #    hml = heatmap(mean(glacier_ref["V"]) .- V̂, title="Loss error - V")
    #    hml = heatmap(glacier_ref["H"][end] .- H, title="Loss error - H")
    #    display(hml)
    # end

    return l_H
end


"""
    iceflow!(H,p,t,t₁)

Forward ice flow model solving the Shallow Ice Approximation PDE 
"""
function iceflow!(H,glacier_ref::Dict, p,t,t₁)

    println("Running forward PDE ice flow model...\n")

    # Instantiate variables
    let             
    current_year = 0
    total_iter = 0
    ts_i = 1
    temps = p[6]

    # Manual explicit forward scheme implementation
    while t < t₁
        let
        iter = 1
        err = 2 * tolnl
        V = zeros(nx,ny)
        Hold = copy(H)         # hold value of H for the other iteration in the implicit method
        dHdt = zeros(nx, ny)   # we need to define dHdt for iter = 1 for Tullio

        # Get current year for MB and ELA
        year = floor(Int, t) + 1
        if year != current_year

            # println("Year: ", year)
            
            # Predict A with the fake A law
            #println("temps: ", temps)
            temp = temps[year]
            ŶA = A_fake(temp)
            #println("A fake: ", ŶA)

            # Unpack and repack tuple with updated A value
            Δx, Δy, Γ, A, B, temps, C, α = p
            p = (Δx, Δy, Γ, ŶA, B, temps, C, α) 
            current_year = year
        end

        while err > tolnl_ref && iter < itMax_ref + 1
        
            Err = copy(H)

            # Compute the Shallow Ice Approximation in a staggered grid
            F, V, dτ = SIA(H, p)

            # Differentiate H via a Picard iteration method
            @tullio ResH[i,j] := -(H[i,j] - Hold[i,j])/Δt + F[pad(i-1,1,1),pad(j-1,1,1)]
            
            dHdt_ = copy(dHdt)
            @tullio dHdt[i,j] := dHdt_[i,j]*damp + ResH[i,j]
            
            # Update the ice thickness
            H_ = copy(H)
            #@tullio H[i,j] := max(0.0, H_[i,j] + dHdt[i,j]*dτ[pad(i-1,1,1),pad(j-1,1,1)])
            @tullio H[i,j] := max(0.0, H_[i,j] + dHdt[i,j]*dτ)

            if mod(iter, nout) == 0
                # Compute error for implicit method with damping
                Err = Err .- H
                err = maximum(Err)
                # println("error at iter ", iter, ": ", err)

                #if isnan(err)
                #    error("""NaNs encountered.  Try a combination of:
                #                decreasing `damp` and/or `dtausc`, more smoothing steps""")
                #end
                if isnan(err)
                    error("""NaNs encountered.  Try a combination of:
                                decreasing `damp` and/or `dtausc`, more smoothing steps""")
                elseif err>10e8
                    error("""Instability detected""")
                elseif iter == itMax_ref && err > tolnl_ref
                    error("""Desired convergence tolerance not reached. Increase the number of iterations
                                itMax or decrease the tolerance tolnl. Current error after $iter iterations is $err""")            
                end
            end
        
            iter += 1
            total_iter += 1
        end

        #println("iterations: ", iter)

        t += Δt

        # Store timestamps to be used for training of the UDEs
        if ts_i < length(glacier_ref["timestamps"])+1
            if t >= glacier_ref["timestamps"][ts_i]
                println("Saving H at year ", glacier_ref["timestamps"][ts_i])
                push!(glacier_ref["H"], H)
                # Compute average surface velocity field
                V̂ = (V[1].^2 + V[2].^2).^(1/2)
                push!(glacier_ref["V"], V̂)
                ts_i += 1
            end          
        end   
        end # let     
    end   
    end # let
    
    return H, glacier_ref["V"] # final ice thickness and average ice surface velocity
end  


# predict_Â(UA, MB_avg, year) = UA(vec(MB_avg[year])') .* 1f-16 # Adding units outside the NN


# predict_A̅(UA, temp) = UA(temp)[1] .* 1e-16 # Adding units outside the NN

predict_A̅(UA, temp) = UA(temp) .* 1e-16

# """
#     predict_A(UA, MB_avg, var_format)

# Make a prediction of `A` using the `UA` neural network for either scalar or matrix format. 
# """
# function predict_A(UA, MB_avg, year, var_format)
#     @assert any(var_format .== ["matrix","scalar"]) "Wrong variable format $var_format ! Needs to be `matrix` or `scalar`"
#     ## Predict A with the NN
#     if var_format == "matrix"
#         # Matrix version
#         ŶA = reshape(predict_Â(UA, MB_avg, year), size(MB_avg[year]))

#     elseif var_format == "scalar"
#         ## Scalar version
#         ŶA = predict_A̅(UA, MB_avg, year)
#     end

#     return ŶA
# end



"""
    iceflow!(H,p,t,t₁)

Hybrid forward ice flow model combining the SIA PDE and neural networks with neural networks into an UDE
"""
function iceflow!(H, UA, p,t,t₁)

    # Retrieve input variables  
    let                  
    current_year = 0
    total_iter = 0
    H_    = @zeros(nx  , ny  )
    Hold     = @zeros(nx  , ny  )
    Err      = @zeros(nx  , ny  )
    dτ     = @zeros(nx-2, ny-2)
    ResH     = @zeros(nx-2, ny-2)
    dHdt, dHdt_ = @zeros(nx-2, ny-2), @zeros(nx-2, ny-2)
    F      = @zeros(nx-2, ny-2)
    Fx      = @zeros(nx-1, ny-2)
    Fy      = @zeros(nx-2, ny-1)
    V, Vx, Vx_buff, Vy, Vy_buff = @zeros(nx-1,ny-1),@zeros(nx-1,ny-1),@zeros(nx-1,ny-1),@zeros(nx-1,ny-1),@zeros(nx-1,ny-1)
    S, dSdx, dSdy, ∇S² = @zeros(nx,ny), @zeros(nx-1,ny), @zeros(nx,ny-1), @zeros(nx-2,ny-2)
    D = @zeros(nx-1, ny-1)
    t_step = 0
    temps = p[6]

    # Forward scheme implementation
    while t < t₁
        let
        iter = 1
        err = 2 * tolnl
                       
        #@parallel assign!(Hold, H)
        Hold = copy(H)

        # Get current year for MB and ELA
        year = floor(Int, t) + 1

        if year != current_year

            # println("Year: ", year)
        
            # Predict value of `A`
            temp = [temps[year]]'
                    
            ŶA = predict_A̅(UA, temp)

            # Zygote.ignore() do
            #     println("Current params: ", Flux.params(UA))

            #     println("ŶA: ", ŶA )

            #     display(heatmap(MB_avg[year], title="MB"))
            # end
        
            ## Unpack and repack tuple with updated A value
            Δx, Δy, Γ, A, B, temps, C, α = p
            p = (Δx, Δy, Γ, ŶA, B, temps, C, α)
            current_year = year
        end # if
           
        while err > tolnl && iter < itMax+1
        # while iter < itMax + 1
           
            # Compute the Shallow Ice Approximation in a staggered grid
            SIA!(H, H_, S, dSdx, dSdy, ∇S², D, F, Fx, Fy, Vx, Vy, dτ, ResH, Hold, dHdt, dHdt_, err, p)

            iter += 1
            total_iter += 1

        end # while
          
        t += Δt
        t_step += 1

        # Zygote.ignore() do
        #     @infiltrate
        # end
        
        # Fill buffers to handle Zygote "Mutating arrays" limitation
        Vx_buff = copy(Vx)
        Vy_buff = copy(Vy)

        @tullio Vx[i,j] := Vx_buff[i,j] + V[1][i,j]
        @tullio Vy[i,j] := Vy_buff[i,j] + V[2][i,j]
    
        end # let
    end # while

    # Compute average surface velocity field
    V̂ = ((Vx./t_step).^2 + (Vy./t_step).^2).^(1/2)

    return H, V̂

    end   # let

end

@parallel function compute_dS!(S, dSdx, dSdy, ∇S²)
    @all(dSdx)  = @d_xa(S) / Δx
    @all(dSdy)  = @d_ya(S) / Δy
    @all(∇S²) = @av_ya(dSdx).^2 .+ @av_xa(dSdy).^2
    return
end

@parallel function compute_D!(D, H, ∇S², Γ)
    @all(D) = Γ * @av(H)^(n+2) * @all(∇S²)^((n - 1)/2)
    return
end

@parallel function compute_F!(F, Fx, Fy, D, S)
    @all(Fx)  = -@av_ya(D) * @d_xi(S)/Δx
    @all(Fy)  = -@av_xa(D) * @d_yi(S)/Δy
    
    #  Flux divergence
    @all(F) = -(@d_xa(Fx) / Δx + @d_ya(Fy) / Δy) 

    return
end

@parallel function compute_dHdt!(dτ, ResH, dHdt, dHdt_, D, H, Hold, Fx, Fy, Dmax, dτsc)
    
    # Compute dτ for the implicit method   
    @all(dτ) = dτsc * min(10.0, 1.0/(1.0/Δt + 1.0/(cfl/(ϵ + Dmax))))
    @all(ResH) = -(@inn(H) - @inn(Hold))/Δt -(@d_xa(Fx)/Δx + @d_ya(Fy)/Δy) # + @inn(M) # MB should go here
    @all(dHdt) = @all(dHdt_)*damp + @all(ResH)
    
    return
end

@parallel function compute_H!(H, H_, dHdt, dτ)
    @inn(H) = max(0.0, @inn(H_) + dτ * @all(dHdt) )
    return
end

@parallel function compute_V!(Vx, Vy, D, H, dSdx, dSdy, ϵ)
    @all(Vx) = -@all(D)/(@av(H) + epsi)*@av_ya(dSdx)
    @all(Vy) = -@all(D)/(@av(H) + epsi)*@av_xa(dSdy)
    return
end

"""
    SIA(H, p)

Compute a step of the Shallow Ice Approximation PDE in a forward model
"""

function SIA!(H, H_, S, dSdx, dSdy, ∇S², D, F, Fx, Fy, Vx, Vy, dτ, ResH, Hold, dHdt, dHdt_, err, p)
    Δx, Δy, Γ, A, B, temps, C, α = p

    # Update glacier surface altimetry
    S = B .+ H

    # All grid variables computed in a staggered grid
    # Compute surface gradients on edges
    @parallel compute_dS!(S, dSdx, dSdy, ∇S²)

    Γ = 2 * A * (ρ * g)^n / (n+2) # 1 / m^3 s 
    
    # Compute diffusivity
    @parallel compute_D!(D, H, ∇S², Γ)
    
    # Compute flux 
    @parallel compute_F!(F, Fx, Fy, D, S)
    
    #dτ = dτsc * min.( 10.0 , 1.0./(1.0/Δt .+ 1.0./(cfl./(ϵ .+ avg(D)))))
    Dmax = 3000000
    current_DDmax = maximum(D) 
    if Dmax < current_Dmax
        error("Increase Maximum diffusivity. Required value must be larger than $current_D_max")
    end
    
    @parallel assign!(dHdt_, dHdt)
    @parallel compute_dHdt!(dτ, ResH, dHdt, D, H, Hold, Fx, Fy, Dmax, dτsc)
    
    @parallel assign!(H_, H)
    @parallel compute_H!(H, dHdt, dτ)
    
    @parallel compute_V!(Vx, Vy, D, H, dSdx, dSdy, ϵ)

    Zygote.ignore() do
        if mod(iter, nout) == 0
            # Compute error for implicit method with damping
            Err = copy(H)
            Err = Err .- H
            err = maximum(Err)

            if isnan(err)
                error("""NaNs encountered.  Try a combination of:
                            decreasing `damp` and/or `dtausc`, more smoothing steps""")
            end
        end
    end
    
    # Zygote.ignore() do
    #     @infiltrate
    #     V = (Vx, Vy)
    # end

    return H

end

"""
    C_fake(MB, ∇S)

Fake law to determine the sliding rate factor 
"""
# TODO: to be updated in order to make it depend on the surrounding
# ice surface velocity pattern
function C_fake(MB, ∇S)
    MB[MB .> 0] .= 0
    MB[MB .< -20] .= 0
    #println("∇S max: ", maximum(∇S))
    #println("((MB).^2)/4) max: ", maximum(((MB).^2)/4))

    return ((avg(MB).^2)./6) .* 3e-13
    #return ((avg(MB).^2)./6) 

end

"""
    A_fake(ELA)

Fake law to determine A in the SIA
"""
function A_fake(temp)
    # Matching point MB values to A values
    maxA = 8e-16
    minA = 3e-17

    maxT = 1
    minT = -25

    #temp_range = -25:0.01:1

    #A_step = (maxA-minA)/length(temp_range)
    #A_range = sigmoid.(Flux.normalise(minA:A_step:maxA).*1.5e14).*1.5e-18 # add nonlinear relationship

    #A = A_range[closest_index(temp_range, temp)]

    return minA + (maxA - minA) * ((temp-minT)/(maxT-minT) )^2
    #return A
end

# function A_fake(MB_buffer, shape, var_format)
#     # Matching point MB values to A values
#     maxA = 3e-16
#     minA = 1e-17

#     if var_format == "matrix"
#         MB_range = reverse(-15:0.01:8)
#     elseif var_format == "scalar"
#         MB_range = reverse(-3:0.01:0)
#     end

#     A_step = (maxA-minA)/length(MB_range)
#     A_range = sigmoid.(Flux.normalise(minA:A_step:maxA).*2.5f11).*5f-16 # add nonlinear relationship

#     if var_format == "matrix"
#         A = []
#         for MB_i in MB_buffer
#             push!(A, A_range[closest_index(MB_range, MB_i)])
#         end
#         A = reshape(A, shape)
#     elseif var_format == "scalar"
#         A = A_range[closest_index(MB_range, nanmean(MB_buffer))]
#     end

#     return A
# end

"""
    create_NNs()

Generates the hyperaparameters and the neural networks needed for the training of UDEs
"""
function create_NNs()
    ######### Define the network  ############
    # We determine the hyperameters for the training
    hyparams = Hyperparameters()

    # Leaky ReLu as activation function
    leakyrelu(x, a=0.01) = max(a*x, x)

    # Constraints A within physically plausible values
    minA = 0.3
    maxA = 8
    rangeA = minA:1e-3:maxA
    stdA = std(rangeA)*2
    relu_A(x) = min(max(minA, x), maxA)
    #relu_A(x) = min(max(minA, 0.00001 * x), maxA)
    sigmoid_A(x) = minA + (maxA - minA) / ( 1 + exp(-x) )

    A_init(custom_std, dims...) = randn(Float32, dims...) .* custom_std
    A_init(custom_std) = (dims...) -> A_init(custom_std, dims...)

    #UA = Chain(
    #    Dense(1,10), 
    #    #Dense(10,10, x->tanh.(x), init = A_init(stdA)), 
    #    Dense(10,10, x->tanh.(x)), #init = A_init(stdA)), 
    #    #Dense(10,5, x->tanh.(x), init = A_init(stdA)), 
    #    Dense(10,5, x->tanh.(x)), #init = A_init(stdA)), 
    #    Dense(5,1, sigmoid_A)
    #)

    UA = Chain(
        Dense(1,3, x->tanh.(x)),
        Dense(3,10, x->tanh.(x)),
        Dense(10,3, x->tanh.(x)),
        Dense(3,1, sigmoid_A)
    )

    return hyparams, UA
end

"""
    callback(l)

Callback to track evolution of the neural network's training. 
"""
# Callback to show the loss during training
callback(l) = begin
    # Container to track the losses
    losses = Float64[]
    push!(losses, l)
    if length(losses)%50==0
        println("Current loss after $(length(losses)) iterations: $(losses[end])")
    end
    false
end
