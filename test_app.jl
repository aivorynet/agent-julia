"""
AIVory Julia Agent Test Application

Usage:
    cd monitor-agents/agent-julia
    AIVORY_API_KEY=ilscipio-dev-2024 AIVORY_BACKEND_URL=ws://localhost:19999/ws/monitor/agent AIVORY_DEBUG=true julia --project=. test_app.jl

First time setup:
    cd monitor-agents/agent-julia
    julia --project=. -e 'using Pkg; Pkg.instantiate()'
"""

# Add parent directory to load path
push!(LOAD_PATH, joinpath(@__DIR__, "src"))

using AIVoryMonitor

struct UserContext
    user_id::String
    email::String
    active::Bool
end

function trigger_exception(iteration::Int)
    # Create local variables to capture
    test_var = "test-value-$iteration"
    count = iteration * 10
    items = ["apple", "banana", "cherry"]
    metadata = Dict(
        "iteration" => iteration,
        "timestamp" => time(),
        "nested" => Dict("key" => "value", "count" => count)
    )
    user = UserContext("user-$iteration", "test@example.com", true)

    local_vars = Dict(
        "test_var" => test_var,
        "count" => count,
        "items" => items,
        "metadata" => metadata,
        "user" => user
    )

    if iteration == 0
        # BoundsError
        println("Triggering BoundsError...")
        arr = [1, 2, 3]
        _ = arr[10]  # BoundsError here
    elseif iteration == 1
        # Custom error
        println("Triggering custom ErrorException...")
        throw(ErrorException("Test error: test_var=$test_var"))
    else
        # DomainError
        println("Triggering DomainError...")
        throw(DomainError(-1, "Cannot take square root of negative number"))
    end

    return local_vars
end

function main()
    println("===========================================")
    println("AIVory Julia Agent Test Application")
    println("Julia version: $VERSION")
    println("===========================================")

    # Initialize the agent
    AIVoryMonitor.init()

    # Set user context
    AIVoryMonitor.set_user(
        id = "test-user-001",
        email = "tester@example.com",
        username = "tester"
    )

    # Wait for agent to connect
    println("Waiting for agent to connect...")
    sleep(3)
    println("Starting exception tests...\n")

    # Generate test exceptions
    for i in 0:2
        println("--- Test $(i + 1) ---")
        try
            trigger_exception(i)
        catch e
            println("Caught: $(typeof(e)) - $(sprint(showerror, e))")

            # Capture with local variables
            AIVoryMonitor.capture_exception(e,
                context = Dict("test_iteration" => i),
                local_vars = Dict(
                    "test_var" => "test-value-$i",
                    "count" => i * 10,
                    "items" => ["apple", "banana", "cherry"]
                )
            )
        end
        println()
        sleep(3)
    end

    println("===========================================")
    println("Test complete. Check database for exceptions.")
    println("===========================================")

    # Keep running briefly to allow final messages to send
    sleep(2)

    # Shutdown cleanly
    AIVoryMonitor.shutdown()
end

main()
