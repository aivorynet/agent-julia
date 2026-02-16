"""
Exception capture and reporting for Julia runtime.
"""

struct CapturedVariable
    name::String
    type::String
    value::String
    is_null::Bool
    is_truncated::Bool
    children::Union{Dict{String, CapturedVariable}, Nothing}
    array_elements::Union{Vector{CapturedVariable}, Nothing}
    array_length::Union{Int, Nothing}
end

struct StackFrame
    method_name::String
    file_name::Union{String, Nothing}
    file_path::Union{String, Nothing}
    line_number::Union{Int, Nothing}
    is_native::Bool
end

mutable struct ExceptionHandler
    config::AgentConfig
    connection::BackendConnection
    installed::Bool
end

function ExceptionHandler(config::AgentConfig, connection::BackendConnection)
    ExceptionHandler(config, connection, false)
end

"""
    install!(handler::ExceptionHandler)

Installs the exception handler.
Note: Julia doesn't have global exception handlers like other languages.
We rely on manual capture.
"""
function install!(handler::ExceptionHandler)
    if handler.installed
        return
    end

    handler.installed = true

    if handler.config.debug
        @info "[AIVory Monitor] Exception handlers installed"
    end
end

"""
    uninstall!(handler::ExceptionHandler)

Uninstalls the exception handler.
"""
function uninstall!(handler::ExceptionHandler)
    if !handler.installed
        return
    end

    handler.installed = false
end

"""
    capture(handler::ExceptionHandler, error::Exception, context, local_vars)

Manually capture an exception with optional local variables.
"""
function capture(handler::ExceptionHandler, error::Exception,
                 context::Union{Dict, Nothing}=nothing,
                 local_vars::Union{Dict, Nothing}=nothing)
    if !should_sample(handler.config)
        return
    end

    capture_data = create_capture(handler, error, context)

    # Capture provided local variables
    if local_vars !== nothing
        capture_data["local_variables"] = capture_variables(handler, local_vars)
    end

    send_exception!(handler.connection, capture_data)

    if handler.config.debug
        @info "[AIVory Monitor] Captured exception: $(typeof(error))"
    end
end

function create_capture(handler::ExceptionHandler, error::Exception,
                       context::Union{Dict, Nothing}=nothing)::Dict{String, Any}
    stack_trace = parse_stack_trace(error)
    fingerprint = calculate_fingerprint(error, stack_trace)

    merged_context = merge(
        get_custom_context(handler.config),
        context !== nothing ? Dict{String, Any}(string(k) => v for (k, v) in context) : Dict{String, Any}(),
        Dict{String, Any}("user" => get_user(handler.config))
    )

    return Dict{String, Any}(
        "id" => string(uuid4()),
        "exception_type" => string(typeof(error)),
        "message" => sprint(showerror, error),
        "fingerprint" => fingerprint,
        "stack_trace" => [frame_to_dict(f) for f in stack_trace],
        "local_variables" => Dict{String, Any}(),
        "context" => merged_context,
        "captured_at" => Dates.format(now(UTC), "yyyy-mm-ddTHH:MM:SS.sssZ")
    )
end

function frame_to_dict(frame::StackFrame)::Dict{String, Any}
    d = Dict{String, Any}(
        "methodName" => frame.method_name,
        "isNative" => frame.is_native
    )
    frame.file_name !== nothing && (d["fileName"] = frame.file_name)
    frame.file_path !== nothing && (d["filePath"] = frame.file_path)
    frame.line_number !== nothing && (d["lineNumber"] = frame.line_number)
    return d
end

function capture_variables(handler::ExceptionHandler, vars::Dict, depth::Int=0)::Dict{String, Any}
    result = Dict{String, Any}()

    for (name, value) in vars
        result[string(name)] = capture_value_to_dict(handler, string(name), value, depth)
    end

    return result
end

function capture_value_to_dict(handler::ExceptionHandler, name::String, value, depth::Int)::Dict{String, Any}
    config = handler.config

    captured = Dict{String, Any}(
        "name" => name,
        "type" => string(typeof(value)),
        "value" => "",
        "isNull" => value === nothing,
        "isTruncated" => false
    )

    if value === nothing
        captured["value"] = "nothing"
        return captured
    end

    if value isa Bool || value isa Number
        captured["value"] = string(value)
    elseif value isa AbstractString
        if length(value) > config.max_string_length
            captured["value"] = value[1:config.max_string_length]
            captured["isTruncated"] = true
        else
            captured["value"] = value
        end
    elseif value isa Function
        captured["type"] = "Function"
        captured["value"] = "[Function: $(nameof(value))]"
    elseif value isa Symbol
        captured["type"] = "Symbol"
        captured["value"] = string(value)
    elseif value isa AbstractArray
        captured["type"] = "Array"
        captured["arrayLength"] = length(value)
        captured["value"] = "$(typeof(value))($(length(value)))"

        if depth < config.max_capture_depth && length(value) <= config.max_collection_size
            elements = CapturedVariable[]
            for (i, item) in enumerate(value[1:min(length(value), config.max_collection_size)])
                push!(elements, capture_value(handler, "[$i]", item, depth + 1))
            end
            captured["arrayElements"] = [var_to_dict(e) for e in elements]
        end
    elseif value isa Dict
        captured["type"] = "Dict"
        captured["value"] = "Dict($(length(value)) entries)"

        if depth < config.max_capture_depth
            children = Dict{String, Any}()
            for (k, v) in Iterators.take(value, config.max_collection_size)
                children[string(k)] = capture_value_to_dict(handler, string(k), v, depth + 1)
            end
            if !isempty(children)
                captured["children"] = children
            end
        end
    elseif value isa Exception
        captured["type"] = string(typeof(value))
        captured["value"] = sprint(showerror, value)
    else
        # Struct or other complex type
        captured["type"] = string(typeof(value))
        captured["value"] = repr(value; context=:limit=>true)

        if depth < config.max_capture_depth && isstructtype(typeof(value))
            children = Dict{String, Any}()
            for field in fieldnames(typeof(value))
                try
                    field_val = getfield(value, field)
                    children[string(field)] = capture_value_to_dict(handler, string(field), field_val, depth + 1)
                catch
                end
            end
            if !isempty(children)
                captured["children"] = children
            end
        end
    end

    return captured
end

function capture_value(handler::ExceptionHandler, name::String, value, depth::Int)::CapturedVariable
    dict = capture_value_to_dict(handler, name, value, depth)

    CapturedVariable(
        dict["name"],
        dict["type"],
        dict["value"],
        dict["isNull"],
        dict["isTruncated"],
        get(dict, "children", nothing),
        get(dict, "arrayElements", nothing),
        get(dict, "arrayLength", nothing)
    )
end

function var_to_dict(v::CapturedVariable)::Dict{String, Any}
    d = Dict{String, Any}(
        "name" => v.name,
        "type" => v.type,
        "value" => v.value,
        "isNull" => v.is_null,
        "isTruncated" => v.is_truncated
    )
    v.children !== nothing && (d["children"] = Dict(k => var_to_dict(c) for (k, c) in v.children))
    v.array_elements !== nothing && (d["arrayElements"] = [var_to_dict(e) for e in v.array_elements])
    v.array_length !== nothing && (d["arrayLength"] = v.array_length)
    return d
end

function parse_stack_trace(error::Exception)::Vector{StackFrame}
    frames = StackFrame[]

    try
        bt = catch_backtrace()
        if isempty(bt)
            bt = backtrace()
        end

        for frame in stacktrace(bt)
            func_name = string(frame.func)
            file = string(frame.file)
            line = frame.line

            # Determine if native
            is_native = startswith(file, "boot.jl") ||
                       startswith(file, "loading.jl") ||
                       contains(file, "julia/base")

            push!(frames, StackFrame(
                func_name,
                basename(file),
                file,
                line,
                is_native
            ))

            if length(frames) >= 50
                break
            end
        end
    catch e
        # Fallback: create minimal frame
        push!(frames, StackFrame(
            string(typeof(error)),
            nothing,
            nothing,
            nothing,
            false
        ))
    end

    return frames
end

function calculate_fingerprint(error::Exception, stack_trace::Vector{StackFrame})::String
    parts = [string(typeof(error))]

    added = 0
    for frame in stack_trace
        if added >= 5
            break
        end
        if frame.is_native
            continue
        end

        line_num = frame.line_number !== nothing ? frame.line_number : 0
        push!(parts, "$(frame.method_name):$(line_num)")
        added += 1
    end

    return bytes2hex(sha256(join(parts, ":")))[1:16]
end
