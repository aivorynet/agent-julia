# AIVory Monitor - Julia Agent

Production exception monitoring and debugging for Julia applications with AI-powered auto-fix capabilities.

## Requirements

- Julia 1.6 or higher
- Internet connectivity to AIVory backend

## Installation

### From Package Manager

```julia
using Pkg
Pkg.add(url="https://github.com/aivory/aivory-monitor-julia")
```

### Development Mode

```julia
using Pkg
Pkg.develop(path="/path/to/monitor-agents/agent-julia")
```

## Usage

### Basic Initialization

Add to your application's entry point:

```julia
using AIVoryMonitor

# Initialize at startup
AIVoryMonitor.init(
    api_key=ENV["AIVORY_API_KEY"],
    environment="production"
)

# Your application code
function main()
    # ... your code ...
end

main()
```

### Manual Exception Capture

```julia
try
    risky_operation()
catch e
    AIVoryMonitor.capture_exception(e)
    rethrow(e)
end
```

### Automatic Capture on Exit

The agent automatically registers an `atexit` hook to capture uncaught exceptions:

```julia
using AIVoryMonitor
AIVoryMonitor.init(api_key=ENV["AIVORY_API_KEY"])

# Uncaught exceptions will be automatically captured and reported
error("This will be captured and sent to AIVory")
```

## Configuration

Configure the agent via environment variables or `init()` parameters:

| Variable | Description | Default |
|----------|-------------|---------|
| `AIVORY_API_KEY` | Agent authentication key | Required |
| `AIVORY_BACKEND_URL` | Backend WebSocket URL | `wss://api.aivory.net` |
| `AIVORY_ENVIRONMENT` | Environment name (production, staging, dev) | `production` |
| `AIVORY_SAMPLING_RATE` | Exception sampling rate (0.0-1.0) | `1.0` |
| `AIVORY_MAX_DEPTH` | Variable capture depth for context | `3` |

### Example with Environment Variables

```bash
export AIVORY_API_KEY="your-api-key-here"
export AIVORY_ENVIRONMENT="staging"
export AIVORY_SAMPLING_RATE="0.5"

julia your_app.jl
```

### Example with Code Configuration

```julia
AIVoryMonitor.init(
    api_key="your-api-key",
    backend_url="wss://api.aivory.net",
    environment="production",
    sampling_rate=1.0,
    max_depth=3
)
```

## How It Works

### Exception Capture

The agent captures exceptions through two mechanisms:

1. **Automatic capture via `Base.atexit`**: Registers a global exit handler that captures uncaught exceptions before the Julia process terminates.

2. **Manual capture via `try/catch`**: Wrap risky code blocks and explicitly call `capture_exception(e)` to report exceptions while continuing execution.

### Communication Protocol

- Uses HTTP.jl for WebSocket communication with the AIVory backend
- Authenticates via API key (query parameter or header)
- Sends exception payloads as JSON with full stack traces
- Captures local variable state at each stack frame (up to `max_depth`)

### Exception Payload

Each captured exception includes:

- Exception type and message
- Full stack trace with file paths and line numbers
- Local variables at each frame (limited by `max_depth`)
- System information (Julia version, OS, hostname)
- Environment name and timestamp
- Correlation IDs for distributed tracing

## Troubleshooting

### Agent Not Connecting

**Problem**: Exceptions are not appearing in the AIVory dashboard.

**Solutions**:
- Verify `AIVORY_API_KEY` is set correctly
- Check network connectivity to `wss://api.aivory.net`
- Enable debug logging: `ENV["AIVORY_DEV_MODE"] = "true"`
- Verify Julia version is 1.6 or higher: `versioninfo()`

### Dependency Conflicts

**Problem**: Package installation fails due to dependency conflicts.

**Solutions**:
- Update Julia packages: `Pkg.update()`
- Check compatibility with `Pkg.status()`
- Use a fresh Julia environment: `Pkg.activate(".")`

### Performance Impact

**Problem**: Agent is slowing down application.

**Solutions**:
- Reduce sampling rate: `AIVORY_SAMPLING_RATE=0.1`
- Decrease capture depth: `AIVORY_MAX_DEPTH=1`
- Only capture specific exceptions manually instead of using the global handler

### Missing Stack Traces

**Problem**: Stack traces are incomplete or missing local variables.

**Solutions**:
- Ensure exceptions are thrown with full context: `throw(ErrorException(...))`
- Increase `max_depth` to capture more variable state
- Check that code is not compiled with optimizations that remove debug info

## License

See LICENSE in the repository root.

## Support

- Documentation: https://aivory.net/monitor/
- Issues: https://github.com/aivory/aivory-monitor/issues
- Email: support@aivory.net
