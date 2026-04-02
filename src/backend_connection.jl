"""
WebSocket connection to the AIVory backend.
"""

mutable struct BackendConnection
    config::AgentConfig
    ws::Union{HTTP.WebSockets.WebSocket, Nothing}
    authenticated::Bool
    reconnect_attempts::Int
    max_reconnect_attempts::Int
    message_queue::Vector{String}
    connected::Bool
    receiver_task::Union{Task, Nothing}
    heartbeat_task::Union{Task, Nothing}
    heartbeat_running::Bool
end

function BackendConnection(config::AgentConfig)
    BackendConnection(
        config,
        nothing,
        false,
        0,
        10,
        String[],
        false,
        nothing,
        nothing,
        false
    )
end

"""
    connect!(conn::BackendConnection)

Connects to the backend WebSocket server.
"""
function connect!(conn::BackendConnection)
    if conn.connected
        return
    end

    try
        # Start WebSocket connection in a task
        conn.receiver_task = @async begin
            try
                HTTP.WebSockets.open(conn.config.backend_url;
                    headers = ["Authorization" => "Bearer $(conn.config.api_key)"]) do ws
                    conn.ws = ws
                    conn.connected = true
                    conn.reconnect_attempts = 0

                    if conn.config.debug
                        @info "[AIVory Monitor] WebSocket connected"
                    end

                    # Authenticate
                    authenticate!(conn)

                    # Receive loop - use for loop over WebSocket which handles connection state
                    try
                        for msg in ws
                            if msg !== nothing
                                handle_message!(conn, String(msg))
                            end
                        end
                    catch e
                        if conn.config.debug && !(e isa EOFError || e isa HTTP.WebSockets.WebSocketError)
                            @warn "[AIVory Monitor] Receive error: $e"
                        end
                    end
                end
            catch e
                if conn.config.debug
                    @warn "[AIVory Monitor] Connection error: $e"
                end
            finally
                conn.connected = false
                conn.authenticated = false
                schedule_reconnect!(conn)
            end
        end

        # Wait briefly for connection to establish
        sleep(0.5)

    catch e
        if conn.config.debug
            @error "[AIVory Monitor] Connection error: $e"
        end
        schedule_reconnect!(conn)
    end
end

"""
    disconnect!(conn::BackendConnection)

Disconnects from the backend.
"""
function disconnect!(conn::BackendConnection)
    conn.connected = false
    conn.authenticated = false

    # Cancel heartbeat task
    stop_heartbeat!(conn)

    if conn.ws !== nothing
        try
            close(conn.ws)
        catch
        end
        conn.ws = nothing
    end

    if conn.receiver_task !== nothing
        try
            # Cancel the task if possible
            Base.throwto(conn.receiver_task, InterruptException())
        catch
        end
        conn.receiver_task = nothing
    end

    if conn.config.debug
        @info "[AIVory Monitor] Disconnected"
    end
end

"""
    send_exception!(conn::BackendConnection, capture::Dict)

Sends an exception to the backend.
"""
function send_exception!(conn::BackendConnection, capture::Dict)
    payload = Dict{String, Any}()
    # Copy capture fields
    for (k, v) in capture
        payload[string(k)] = v
    end
    # Add our fields (these take precedence)
    payload["agent_id"] = conn.config.agent_id
    payload["environment"] = conn.config.environment
    payload["runtime"] = "julia"
    payload["runtime_info"] = get_runtime_info(conn.config)

    message = Dict{String, Any}(
        "type" => "exception",
        "payload" => payload,
        "timestamp" => round(Int, time() * 1000)
    )

    if conn.config.debug
        @info "[AIVory Monitor] Sending exception payload with runtime=$(payload["runtime"])"
    end

    send!(conn, JSON3.write(message))
end

"""
    send_breakpoint_hit!(conn::BackendConnection, breakpoint_id::String, data::Dict)

Sends a breakpoint hit event to the backend.
"""
function send_breakpoint_hit!(conn::BackendConnection, breakpoint_id::String, data::Dict)
    payload = Dict{String, Any}()
    for (k, v) in data
        payload[string(k)] = v
    end
    payload["breakpoint_id"] = breakpoint_id
    payload["agent_id"] = conn.config.agent_id
    send!(conn, "breakpoint_hit", payload)
end

function authenticate!(conn::BackendConnection)
    auth_message = Dict{String, Any}(
        "type" => "register",
        "payload" => Dict{String, Any}(
            "api_key" => conn.config.api_key,
            "agent_id" => conn.config.agent_id,
            "hostname" => conn.config.hostname,
            "runtime" => "julia",
            "runtime_version" => string(VERSION),
            "agent_version" => "0.1.2",
            "environment" => conn.config.environment
        ),
        "timestamp" => round(Int, time() * 1000)
    )

    if conn.ws !== nothing && conn.connected
        try
            HTTP.WebSockets.send(conn.ws, JSON3.write(auth_message))
        catch e
            if conn.config.debug
                @warn "[AIVory Monitor] Auth send error: $e"
            end
        end
    end
end

function handle_message!(conn::BackendConnection, data::String)
    try
        message = JSON3.read(data)

        if conn.config.debug
            @info "[AIVory Monitor] Received: $(get(message, :type, "unknown"))"
        end

        msg_type = get(message, :type, nothing)

        if msg_type == "registered"
            conn.authenticated = true
            if conn.config.debug
                @info "[AIVory Monitor] Agent registered"
            end
            flush_queue!(conn)
            start_heartbeat!(conn)
        elseif msg_type == "error"
            payload = get(message, :payload, Dict())
            error_code = get(payload, :code, "")
            @error "[AIVory Monitor] Backend error: $(get(payload, :message, "unknown"))"

            # Auth errors are not recoverable - stop reconnecting
            if error_code == "auth_error" || error_code == "invalid_api_key"
                @error "[AIVory Monitor] Authentication failed, disabling reconnect"
                conn.max_reconnect_attempts = 0
                disconnect!(conn)
            end
        end
    catch e
        if conn.config.debug
            @error "[AIVory Monitor] Failed to parse message: $e"
        end
    end
end

function send!(conn::BackendConnection, msg_type::String, payload::Dict)
    message = Dict{String, Any}(
        "type" => msg_type,
        "payload" => payload,
        "timestamp" => round(Int, time() * 1000)
    )
    send!(conn, JSON3.write(message))
end

function send!(conn::BackendConnection, message::String)
    if conn.ws !== nothing && conn.connected && conn.authenticated
        try
            HTTP.WebSockets.send(conn.ws, message)
            if conn.config.debug
                @info "[AIVory Monitor] Sent message"
            end
        catch e
            if conn.config.debug
                @warn "[AIVory Monitor] Send error: $e"
            end
            # Queue for later
            push!(conn.message_queue, message)
            if length(conn.message_queue) > 1000
                popfirst!(conn.message_queue)
            end
        end
    else
        # Queue message for later
        push!(conn.message_queue, message)
        if length(conn.message_queue) > 1000
            popfirst!(conn.message_queue)
        end
    end
end

function flush_queue!(conn::BackendConnection)
    while !isempty(conn.message_queue) && conn.ws !== nothing && conn.connected
        message = popfirst!(conn.message_queue)
        try
            HTTP.WebSockets.send(conn.ws, message)
        catch
            pushfirst!(conn.message_queue, message)
            break
        end
    end
end

"""
    start_heartbeat!(conn::BackendConnection)

Starts an async heartbeat task that sends a heartbeat every 30 seconds.
Cancels any existing heartbeat before starting a new one.
"""
function start_heartbeat!(conn::BackendConnection)
    # Cancel old heartbeat before starting new one
    stop_heartbeat!(conn)

    conn.heartbeat_running = true
    conn.heartbeat_task = @async begin
        try
            while conn.heartbeat_running && conn.connected
                sleep(30)
                if !conn.heartbeat_running || !conn.connected
                    break
                end
                payload = Dict{String, Any}(
                    "timestamp" => round(Int, time() * 1000),
                    "agent_id" => conn.config.agent_id
                )
                send!(conn, "heartbeat", payload)
                if conn.config.debug
                    @info "[AIVory Monitor] Heartbeat sent"
                end
            end
        catch e
            if conn.config.debug && !(e isa InterruptException)
                @warn "[AIVory Monitor] Heartbeat error: $e"
            end
        end
    end

    if conn.config.debug
        @info "[AIVory Monitor] Heartbeat started (30s interval)"
    end
end

"""
    stop_heartbeat!(conn::BackendConnection)

Stops the heartbeat task.
"""
function stop_heartbeat!(conn::BackendConnection)
    conn.heartbeat_running = false
    if conn.heartbeat_task !== nothing
        try
            Base.throwto(conn.heartbeat_task, InterruptException())
        catch
        end
        conn.heartbeat_task = nothing
    end
end

function schedule_reconnect!(conn::BackendConnection)
    if conn.reconnect_attempts >= conn.max_reconnect_attempts
        if conn.config.debug
            @warn "[AIVory Monitor] Max reconnect attempts reached"
        end
        return
    end

    delay = min(2^conn.reconnect_attempts, 60)
    conn.reconnect_attempts += 1

    if conn.config.debug
        @info "[AIVory Monitor] Reconnecting in $(delay)s (attempt $(conn.reconnect_attempts))"
    end

    @async begin
        sleep(delay)
        connect!(conn)
    end
end
