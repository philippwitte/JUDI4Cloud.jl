
sum(A::Array{BlobFuture}) = fetchreduce(A; op=+, remote=true, num_restart=0)
vcat(A::NTuple{N, BlobFuture}) where N = vcat(fetch(collect(A))...)
reduce(f, A::Array{BlobFuture}) = fetchreduce(A; op=+, remote=true, num_restart=0)

function JUDI.time_modeling(model::Model, srcGeometry, srcData, recGeometry, recData, dm, srcnum::UnitRange{Int64}, op::Char, mode::Int64, options)

    # Broadcast common parameters
    _model = @bcast model
    _dm = isnothing(dm) ? dm : @bcast dm
    opts = make_opt([model, dm, op, srcGeometry])
    # Run on azure
    results = @batchexec pmap(sx -> time_modeling_azure(_model, subsample(srcGeometry,sx), subsample(srcData, sx),
                                                        subsample(recGeometry, sx), subsample(recData, sx), _dm,
                                                        op, mode, subsample(options, sx)), srcnum) opts
    # Gather results
    if op=='F' || (op=='J' && mode==1)
        argout1 = vcat(fetch(results)...)
    elseif op=='J' && mode==-1
        argout1 = fetchreduce(results; op=+, remote=false)
    else
        error("operation no defined")
    end
    return argout1
end

# FWI
function JUDI.fwi_objective(model::Model, source::judiVector, dObs::judiVector; options=JUDI.Options())
    # fwi_objective function for multiple sources. The function distributes the sources and the input data amongst the available workers.
    # Broadcast common parameters
    _model = @bcast model
    opts = make_opt([model, dObs, source])
    results = @batchexec pmap(j -> fwi_objective_azure(_model, source[j], dObs[j], subsample(options, j)), 1:dObs.nsrc) opts
    
    # Collect and reduce gradients
    obj, gradient = fetchreduce(results; op=+)

    # first value corresponds to function value, the rest to the gradient
    return obj, gradient
end

# lsrtm

function JUDI.lsrtm_objective(model::Model, source::judiVector, dObs::judiVector, dm; options=JUDI.Options(), nlind=false)
    # lsrtm_objective function for multiple sources. The function distributes the sources and the input data amongst the available workers.

    # Broadcast common parameters
    _model = @bcast model
    _dm = isnothing(dm) ? dm : @bcast dm
    opts = make_opt([model, dObs, source, dm])
    results = @batchexec pmap(j -> lsrtm_objective_azure(_model, source[j], dObs[j], _dm, subsample(options, j); nlind=nlind), 1:dObs.nsrc) opts
    # Collect and reduce gradients
    obj, gradient = fetchreduce(results; op=+)

    # first value corresponds to function value, the rest to the gradient
    return obj, gradient
end


# Make options for unique batch ids
make_opt(a::Array) = AzureClusterlessHPC.Options(;task_name="task_$(objectid(a))")
