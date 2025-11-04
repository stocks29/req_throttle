# ReqThrottle

A Req plugin for rate limiting and throttling HTTP requests to external services.

ReqThrottle provides a flexible, pluggable rate limiting solution that works with any rate limiter implementation. It supports both blocking (with retries) and error modes.

## Features

- **Pluggable rate limiters** - Use any module with a `hit/1` function or an anonymous function
- **Flexible key generation** - Rate limit by host, path, URL, or custom logic
- **Two modes**:
  - **Blocking mode** (default) - Automatically retries until a slot becomes available
  - **Error mode** - Immediately returns an error when the limit is reached
- **Simple interface** - Rate limiters handle their own scale and limit configuration

## Installation

Add `req_throttle` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:req_throttle, "~> 0.1.0"}
  ]
end
```

## Usage

### Basic Usage

```elixir
# Blocking mode (default) - using atom shortcut
Req.new()
|> ReqThrottle.attach(
  rate_limiter: MyApp.RateLimiter,
  key_generator: :host
)
|> Req.get("https://api.example.com/data")
```

### Error Mode

```elixir
# Error mode - returns an exception immediately when rate limit is exceeded
Req.new()
|> ReqThrottle.attach(
  rate_limiter: MyApp.RateLimiter,
  mode: :error
)
|> Req.get("https://api.example.com/data")
```

### Using Hammer

First, add Hammer to your dependencies:

```elixir
def deps do
  [
    {:req_throttle, "~> 0.1.0"},
    {:hammer, "~> 7.0"}
  ]
end
```

Set up Hammer in your application:

```elixir
defmodule MyApp.RateLimiter do
  use Hammer, backend: :ets
end

# In your application supervision tree
defmodule MyApp.Application do
  def start(_type, _args) do
    children = [
      MyApp.RateLimiter
      # ... other children
    ]
    Supervisor.start_link(children, strategy: :one_for_one)
  end
end
```

Then use it with ReqThrottle:

```elixir
Req.new()
|> ReqThrottle.attach(
  rate_limiter: MyApp.RateLimiter,
  key_generator: :host
)
|> Req.get("https://api.example.com/data")
```

Note: Hammer's `hit/3` function takes `(key, scale, limit)`, but ReqThrottle only calls it with `hit(key)`. You'll need to create a wrapper that handles the scale and limit configuration:

```elixir
defmodule MyApp.RateLimiter do
  use Hammer, backend: :ets

  @scale :timer.minutes(1)
  @limit 100

  def hit(key) do
    hit(key, @scale, @limit)
  end
end
```

### Using Agent

You can create a simple rate limiter using Agent:

```elixir
defmodule MyApp.SimpleRateLimiter do
  use Agent

  @scale_ms :timer.minutes(1)
  @limit 10

  def start_link(_opts) do
    Agent.start_link(fn -> %{} end, name: __MODULE__)
  end

  def hit(key) do
    now = System.system_time(:millisecond)
    window_start = div(now, @scale_ms) * @scale_ms

    Agent.get_and_update(__MODULE__, fn state ->
      # Clean up old windows (keep only current window)
      cleaned_state =
        Enum.filter(state, fn {{_k, w}, _} ->
          w >= window_start
        end)
        |> Map.new()

      window_key = {key, window_start}
      count = Map.get(cleaned_state, window_key, 0)

      if count < @limit do
        new_state = Map.put(cleaned_state, window_key, count + 1)
        {{:allow, count + 1}, new_state}
      else
        retry_after = @scale_ms - (now - window_start)
        {{:deny, retry_after}, cleaned_state}
      end
    end)
  end
end
```

Then use it:

```elixir
# Start the agent in your supervision tree
MyApp.SimpleRateLimiter.start_link([])

Req.new()
|> ReqThrottle.attach(
  rate_limiter: MyApp.SimpleRateLimiter,
  key_generator: :host
)
|> Req.get("https://api.example.com/data")
```

### Using Anonymous Functions

You can also pass an anonymous function directly:

```elixir
rate_limiter_fn = fn key ->
  # Your custom rate limiting logic
  # Must return {:allow, count} or {:deny, retry_after_ms}
  {:allow, 1}
end

Req.new()
|> ReqThrottle.attach(rate_limiter: rate_limiter_fn)
|> Req.get("https://api.example.com/data")
```

## Configuration Options

- `rate_limiter` (required) - Module atom or function that implements rate limiting
  - Module must have a `hit/1` function: `hit(key) -> {:allow, count} | {:deny, retry_after_ms}`
  - Function signature: `(key) -> {:allow, count} | {:deny, retry_after_ms}`
  - The rate limiter is responsible for managing its own scale, limit, and all rate limiting logic

- `key_generator` - Atom, function, or MFA tuple to generate the rate limit key from the request
  - Default: `:host`
  - Atom shortcuts: `:host`, `:path`, `:host_and_path`, `:url`
  - Function alternatives: `&ReqThrottle.KeyGenerators.key_by_host/1`, `&ReqThrottle.KeyGenerators.key_by_path/1`, etc.
  - MFA tuples: `{ReqThrottle.KeyGenerators, :key_by_host, []}`, etc.

- `mode` - `:block` or `:error` (default: `:block`)
  - `:block` - Blocks and retries until a slot becomes available
  - `:error` - Immediately returns an error when limit is reached

- `max_retries` - Maximum number of retries in block mode (default: `3`)

## Key Generators

ReqThrottle provides several pre-configured key generators that can be used as atoms or functions:

```elixir
# Using atom shortcuts (recommended)
key_generator: :host
key_generator: :path
key_generator: :host_and_path
key_generator: :url

# Or using functions directly
key_generator: &ReqThrottle.KeyGenerators.key_by_host/1
key_generator: &ReqThrottle.KeyGenerators.key_by_path/1
key_generator: &ReqThrottle.KeyGenerators.key_by_host_and_path/1
key_generator: &ReqThrottle.KeyGenerators.key_by_url/1
```

You can also create custom key generators:

```elixir
custom_key_generator = fn request ->
  # Extract user ID from request headers or other logic
  user_id = Req.get_header(request, "x-user-id")
  "#{user_id}:#{URI.parse(request.url).host}"
end

Req.new()
|> ReqThrottle.attach(
  rate_limiter: MyApp.RateLimiter,
  key_generator: custom_key_generator
)
```

## Error Handling

When using `mode: :error`, the plugin returns an exception:

```elixir
try do
  Req.get!(client, "https://api.example.com/data")
rescue
  %ReqThrottle.RateLimitError{} = error ->
    # Rate limit exceeded
    IO.puts("Rate limit exceeded for key '#{error.key}'. Retry after #{error.retry_after_ms}ms")
end
```

## Examples

### Rate Limit by Host

```elixir
Req.new()
|> ReqThrottle.attach(
  rate_limiter: MyApp.RateLimiter,
  key_generator: :host
)
```

### Rate Limit by Endpoint

```elixir
Req.new()
|> ReqThrottle.attach(
  rate_limiter: MyApp.RateLimiter,
  key_generator: :path
)
```

### Custom Rate Limiting Logic

```elixir
custom_rate_limiter = fn key ->
  # Check external cache, database, etc.
  current_count = get_count_from_cache(key)
  scale_ms = :timer.minutes(1)
  limit = 50
  
  if current_count < limit do
    increment_cache(key, scale_ms)
    {:allow, current_count + 1}
  else
    {:deny, scale_ms}
  end
end

Req.new()
|> ReqThrottle.attach(rate_limiter: custom_rate_limiter)
```

## License

Copyright (c) 2025

This library is MIT licensed.
