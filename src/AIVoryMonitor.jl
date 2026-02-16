"""
AIVory Monitor Julia Agent

Remote debugging with AI-powered fix generation for Julia runtime.

Usage:
    using AIVoryMonitor

    AIVoryMonitor.init(
        api_key = "your-api-key",
        environment = "production"
    )

    # Manual capture with local variables
    try
        risky_operation()
    catch e
        AIVoryMonitor.capture_exception(e,
            context = Dict("user_id" => "123"),
            local_vars = Dict("x" => x, "y" => y)
        )
        rethrow()
    end
"""
module AIVoryMonitor

using HTTP
using HTTP.WebSockets
using JSON3
using UUIDs
using SHA
using Sockets
using Dates

export init, capture_exception, set_context, set_user, shutdown, is_initialized

include("config.jl")
include("backend_connection.jl")
include("exception_handler.jl")

# Global state
const _config = Ref{Union{AgentConfig, Nothing}}(nothing)
const _connection = Ref{Union{BackendConnection, Nothing}}(nothing)
const _handler = Ref{Union{ExceptionHandler, Nothing}}(nothing)
const _initialized = Ref{Bool}(false)

"""
    init(; kwargs...)

Initializes the AIVory Monitor agent.

# Keyword Arguments
- `api_key::String`: API key for authentication (default: ENV["AIVORY_API_KEY"])
- `backend_url::String`: WebSocket URL (default: ENV["AIVORY_BACKEND_URL"])
- `environment::String`: Environment name (default: "production")
- `sampling_rate::Float64`: Sampling rate 0-1 (default: 1.0)
- `max_capture_depth::Int`: Max depth for variable capture (default: 3)
- `max_string_length::Int`: Max string length (default: 1000)
- `max_collection_size::Int`: Max array/dict size (default: 100)
- `debug::Bool`: Enable debug logging (default: false)
"""
function init(; kwargs...)
    if _initialized[]
        @info "[AIVory Monitor] Agent already initialized"
        return
    end

    _config[] = AgentConfig(; kwargs...)
    config = _config[]

    if isempty(config.api_key)
        @warn "[AIVory Monitor] API key is required. Set AIVORY_API_KEY or pass api_key option."
        return
    end

    _connection[] = BackendConnection(config)
    _handler[] = ExceptionHandler(config, _connection[])

    # Connect to backend
    connect!(_connection[])

    # Install exception handlers
    install!(_handler[])

    _initialized[] = true

    @info "[AIVory Monitor] Agent v1.0.0 initialized (Julia $(VERSION))"
    @info "[AIVory Monitor] Environment: $(config.environment)"
end

"""
    capture_exception(error; context=nothing, local_vars=nothing)

Manually captures an exception.
"""
function capture_exception(error::Exception;
                           context::Union{Dict, Nothing}=nothing,
                           local_vars::Union{Dict, Nothing}=nothing)
    if !_initialized[] || _handler[] === nothing
        @warn "[AIVory Monitor] Agent not initialized"
        return
    end

    capture(_handler[], error, context, local_vars)
end

"""
    set_context(context::Dict)

Sets custom context that will be sent with all captures.
"""
function set_context(context::Dict)
    if !_initialized[] || _config[] === nothing
        @warn "[AIVory Monitor] Agent not initialized"
        return
    end

    set_custom_context!(_config[], context)
end

"""
    set_user(; id=nothing, email=nothing, username=nothing)

Sets the current user for context.
"""
function set_user(; id::Union{String, Nothing}=nothing,
                   email::Union{String, Nothing}=nothing,
                   username::Union{String, Nothing}=nothing)
    if !_initialized[] || _config[] === nothing
        @warn "[AIVory Monitor] Agent not initialized"
        return
    end

    set_user!(_config[], id, email, username)
end

"""
    shutdown()

Shuts down the agent.
"""
function shutdown()
    if !_initialized[]
        return
    end

    @info "[AIVory Monitor] Shutting down agent"

    if _handler[] !== nothing
        uninstall!(_handler[])
    end

    if _connection[] !== nothing
        disconnect!(_connection[])
    end

    _config[] = nothing
    _connection[] = nothing
    _handler[] = nothing
    _initialized[] = false
end

"""
    is_initialized()

Checks if the agent is initialized.
"""
function is_initialized()
    return _initialized[]
end

end # module
