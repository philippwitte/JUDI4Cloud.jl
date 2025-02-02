module JUDI4Cloud

import Base.vcat, Base.+

using AzureClusterlessHPC, Reexport, PyCall
@reexport using JUDI

export init_culsterless

_judi_defaults = Dict("_POOL_ID"                => "JudiPool",
                    "_POOL_VM_SIZE"           => "Standard_E4s_v3",
                    "_VERBOSE"                => "0",
                    "_NODE_OS_OFFER"          => "ubuntu-server-container",
                    "_NODE_OS_PUBLISHER"      => "microsoft-azure-batch",
                    "_CONTAINER"              => ENV["CONTAINER_IMAGE"],
                    "_NODE_COUNT_PER_POOL"    => ENV["NODE_COUNT_PER_POOL"],
                    "_NUM_RETRYS"             => "1",
                    "_POOL_COUNT"             => ENV["POOL_COUNT"],
                    "_PYTHONPATH"             => "/usr/local/lib/python3.8/dist-packages",
                    "_JULIA_DEPOT_PATH"       => "/root/.julia",
                    "_OMP_NUM_THREADS"        => "4",
                    "_NODE_OS_SKU"            => "20-04-lts")

"""
Define auto scale formula to avoid idle pools
"""
auto_scale_formula(x) = """// Get pending tasks for the past 15 minutes.
\$samples = \$ActiveTasks.GetSamplePercent(TimeInterval_Minute * 15);
// If we have fewer than 70 percent data points, we use the last sample point, otherwise we use the maximum of last sample point and the history average.
\$tasks = \$samples < 70 ? max(0, \$ActiveTasks.GetSample(1)) : 
max( \$ActiveTasks.GetSample(1), avg(\$ActiveTasks.GetSample(TimeInterval_Minute * 15)));
// If number of pending tasks is not 0, set targetVM to pending tasks, otherwise 25% of current dedicated.
\$targetVMs = \$tasks > 0 ? \$tasks : max(0, \$TargetDedicatedNodes / 4);
// The pool size is capped at NWORKERS, if target VM value is more than that, set it to NWORKERS.
cappedPoolSize = $x;
\$TargetDedicatedNodes = max(0, min(\$targetVMs, cappedPoolSize));
// Set node deallocation mode - keep nodes active only until tasks finish
\$NodeDeallocationOption = taskcompletion;"""


len_vm(s::String) = 1
len_vm(s::Array{String, 1}) = len(s)
len_vm(s) = throw(ArgumentError("`vm_size` must be a String Array{String, 1}"))

function init_culsterless(nworkers=2; credentials=nothing, vm_size="Standard_E8s_v3",
                                      pool_name="JudiPool", verbose=0, nthreads=4,
                                      auto_scale=true, kw...)
    # Check input
    npool = len_vm(vm_size)
    blob_name = lowercase("$(pool_name)tmp")
    # Update verbosity and parameters
    @eval(AzureClusterlessHPC, global __verbose__ =  Bool($verbose))
    global AzureClusterlessHPC.__params__["_NODE_COUNT_PER_POOL"] = "$(nworkers)"
    global AzureClusterlessHPC.__params__["_POOL_ID"] = "$(pool_name)"
    global AzureClusterlessHPC.__params__["_POOL_COUNT"] = "$(npool)"
    global AzureClusterlessHPC.__params__["_POOL_VM_SIZE"] = vm_size
    global AzureClusterlessHPC.__params__["_OMP_NUM_THREADS"] = "$(nthreads)"
    global AzureClusterlessHPC.__params__["_VERBOSE"] = "$(verbose)"
    global AzureClusterlessHPC.__params__["_BLOB_CONTAINER"] = blob_name

    if !isnothing(credentials)
        # reinit everything
        isfile(credentials) || throw(FileNotFoundError(credentials))
        creds = AzureClusterlessHPC.JSON.parsefile(credentials)
        @eval(AzureClusterlessHPC, global __container__ = $blob_name)
        @eval(AzureClusterlessHPC, global __credentials__ = [$creds])
        @eval(AzureClusterlessHPC, global __resources__ = [[] for i=1:length(__credentials__)])
        @eval(AzureClusterlessHPC, global __clients__ = create_clients(__credentials__, batch=true, blob=true))
    end
    # Create pool with idle autoscale. This will be much more efficient with a defined image rather than docker.
    batch = pyimport("azure.batch")
    container_registry = batch.models.ContainerRegistry(
        registry_server = ENV["ACR_REGISTRY_SERVER"],
        user_name = ENV["ACR_USERNAME"],
        password = ENV["ACR_PASSWORD"]
    )
    
    create_pool(container_registry=container_registry)

    # Export JUDI on azure
    eval(macroexpand(JUDI4Cloud, quote @batchdef using Distributed, JUDI end))
    include(joinpath(@__DIR__, "batch_defs.jl"))
    include(joinpath(@__DIR__, "modeling.jl"))
end

"""
    finalize_culsterless()

Finalize the clusterless job and deletes all resources (pool, tmp container, jobs)
"""
function finalize_culsterless()
    delete_all_jobs()
    delete_container()
    try delete_pool() catch; nothing end
end


function __init__()
    merge!(AzureClusterlessHPC.__params__, _judi_defaults)
    atexit(finalize_culsterless)
end

end # module
