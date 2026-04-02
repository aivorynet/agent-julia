"""
Configuration for the AIVory Monitor agent.
"""

mutable struct AgentConfig
    api_key::String
    backend_url::String
    environment::String
    sampling_rate::Float64
    max_capture_depth::Int
    max_string_length::Int
    max_collection_size::Int
    debug::Bool
    hostname::String
    agent_id::String
    custom_context::Dict{String, Any}
    user::Dict{String, Any}
end

function AgentConfig(;
    api_key::String = get(ENV, "AIVORY_API_KEY", ""),
    backend_url::String = get(ENV, "AIVORY_BACKEND_URL", "wss://api.aivory.net/ws/agent"),
    environment::String = get(ENV, "AIVORY_ENVIRONMENT", "production"),
    sampling_rate::Float64 = parse(Float64, get(ENV, "AIVORY_SAMPLING_RATE", "1.0")),
    max_capture_depth::Int = parse(Int, get(ENV, "AIVORY_MAX_DEPTH", "10")),
    max_string_length::Int = parse(Int, get(ENV, "AIVORY_MAX_STRING_LENGTH", "1000")),
    max_collection_size::Int = parse(Int, get(ENV, "AIVORY_MAX_COLLECTION_SIZE", "100")),
    debug::Bool = get(ENV, "AIVORY_DEBUG", "false") == "true"
)
    hostname = gethostname()
    agent_id = "agent-$(string(time_ns(), base=16)[1:12])-$(string(uuid4())[1:8])"

    if debug
        @info "[AIVory Monitor] Backend URL: $backend_url"
    end

    AgentConfig(
        api_key,
        backend_url,
        environment,
        sampling_rate,
        max_capture_depth,
        max_string_length,
        max_collection_size,
        debug,
        hostname,
        agent_id,
        Dict{String, Any}(),
        Dict{String, Any}()
    )
end

function should_sample(config::AgentConfig)::Bool
    if config.sampling_rate >= 1.0
        return true
    end
    if config.sampling_rate <= 0.0
        return false
    end
    return rand() < config.sampling_rate
end

function set_custom_context!(config::AgentConfig, context::Dict)
    config.custom_context = Dict{String, Any}(string(k) => v for (k, v) in context)
end

function get_custom_context(config::AgentConfig)::Dict{String, Any}
    return copy(config.custom_context)
end

function set_user!(config::AgentConfig, id, email, username)
    config.user = Dict{String, Any}()
    id !== nothing && (config.user["id"] = id)
    email !== nothing && (config.user["email"] = email)
    username !== nothing && (config.user["username"] = username)
end

function get_user(config::AgentConfig)::Dict{String, Any}
    return copy(config.user)
end

function get_runtime_info(config::AgentConfig)::Dict{String, String}
    return Dict{String, String}(
        "runtime" => "julia",
        "runtimeVersion" => string(VERSION),
        "platform" => string(Sys.KERNEL),
        "arch" => string(Sys.ARCH)
    )
end
