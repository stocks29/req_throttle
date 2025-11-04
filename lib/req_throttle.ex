defmodule ReqThrottle do
  @moduledoc """
  A Req plugin for rate limiting and throttling HTTP requests.

  The plugin supports pluggable rate limiters that can be either:
  - A module atom (e.g., `MyApp.RateLimiter`) that defines a `hit/1` function
  - An anonymous function `(key) -> {:allow, count} | {:deny, retry_after_ms}`

  The rate limiter is responsible for managing scale, limit, and all rate limiting logic.
  This plugin only handles key generation and calling the rate limiter with the key.

  ## Modes

  - `:block` (default) - Blocks and retries until a slot becomes available
  - `:error` - Immediately returns an error tuple when the limit is reached

  ## Configuration Options

  - `rate_limiter` (required) - Module atom or function that implements the rate limiting logic
  - `key_generator` - Atom, function, or MFA tuple to generate the rate limit key from the request (default: `:host`)
    - Atoms: `:host`, `:path`, `:host_and_path`, `:url`
    - Functions: `&ReqThrottle.KeyGenerators.key_by_host/1`, etc.
  - `mode` - `:block` or `:error` (default: `:block`)
  - `max_retries` - Maximum number of retries in block mode (default: `3`)

  ## Examples

      # Blocking mode with Hammer
      Req.new()
      |> ReqThrottle.attach(
        rate_limiter: MyApp.RateLimiter,
        key_generator: &ReqThrottle.KeyGenerators.key_by_host/1
      )

      # Error mode with custom function
      Req.new()
      |> ReqThrottle.attach(
        rate_limiter: fn key ->
          # Custom rate limiting logic
          {:allow, 1}
        end,
        mode: :error
      )
  """

  @default_mode :block
  @default_max_retries 3

  @doc """
  Attaches the ReqThrottle plugin to a request.

  ## Options

  - `rate_limiter` (required) - Module atom or function that implements rate limiting
  - `key_generator` - Atom, function, or MFA tuple to generate the rate limit key (default: `:host`)
    - Atoms: `:host`, `:path`, `:host_and_path`, `:url`
    - Functions: `&ReqThrottle.KeyGenerators.key_by_host/1`, etc.
    - MFA: `{Module, :function, [args]}`
  - `mode` - `:block` or `:error` (default: `:block`)
  - `max_retries` - Maximum number of retries in block mode (default: `3`)

  ## Examples

      # Using atom shortcut
      Req.new()
      |> ReqThrottle.attach(
        rate_limiter: MyApp.RateLimiter,
        key_generator: :host
      )

      # Using function directly
      Req.new()
      |> ReqThrottle.attach(
        rate_limiter: MyApp.RateLimiter,
        key_generator: &ReqThrottle.KeyGenerators.key_by_host/1
      )
  """
  def attach(%Req.Request{} = request, options) do
    rate_limiter = Keyword.fetch!(options, :rate_limiter)

    key_generator = Keyword.get(options, :key_generator, :host)
    mode = Keyword.get(options, :mode, @default_mode)
    max_retries = Keyword.get(options, :max_retries, @default_max_retries)

    unless mode in [:block, :error] do
      raise ArgumentError, "mode must be :block or :error, got: #{inspect(mode)}"
    end

    opts = %{
      rate_limiter: rate_limiter,
      key_generator: normalize_key_generator(key_generator),
      mode: mode,
      max_retries: max_retries
    }

    Req.Request.append_request_steps(request, throttle: fn req -> throttle_request(req, opts) end)
  end

  defp throttle_request(request, opts) do
    key = generate_key(request, opts.key_generator)

    case rate_limit_hit(key, opts.rate_limiter) do
      {:allow, _count} ->
        request

      {:deny, retry_after_ms} ->
        handle_deny(request, key, retry_after_ms, opts)
    end
  end

  defp normalize_key_generator(atom) when is_atom(atom) do
    case atom_to_key_generator(atom) do
      nil ->
        raise ArgumentError,
              "key_generator atom must be one of #{inspect([:host, :path, :host_and_path, :url])}, got: #{inspect(atom)}"

      fun ->
        fun
    end
  end

  defp normalize_key_generator({module, function, args}) when is_atom(module) and is_atom(function) do
    fn request -> apply(module, function, [request | args]) end
  end

  defp normalize_key_generator(fun) when is_function(fun, 1) do
    fun
  end

  defp normalize_key_generator(other) do
    raise ArgumentError,
          "key_generator must be an atom, function, or MFA tuple, got: #{inspect(other)}"
  end

  defp atom_to_key_generator(:host), do: &ReqThrottle.KeyGenerators.key_by_host/1
  defp atom_to_key_generator(:path), do: &ReqThrottle.KeyGenerators.key_by_path/1
  defp atom_to_key_generator(:host_and_path), do: &ReqThrottle.KeyGenerators.key_by_host_and_path/1
  defp atom_to_key_generator(:url), do: &ReqThrottle.KeyGenerators.key_by_url/1
  defp atom_to_key_generator(_), do: nil

  defp generate_key(request, key_generator) do
    key_generator.(request)
  end

  defp rate_limit_hit(key, rate_limiter) when is_atom(rate_limiter) do
    apply(rate_limiter, :hit, [key])
  end

  defp rate_limit_hit(key, rate_limiter) when is_function(rate_limiter, 1) do
    rate_limiter.(key)
  end

  defp rate_limit_hit(_key, other) do
    raise ArgumentError,
          "rate_limiter must be a module atom or a function, got: #{inspect(other)}"
  end

  defp handle_deny(request, key, retry_after_ms, opts) do
    case opts.mode do
      :error ->
        exception = ReqThrottle.RateLimitError.exception(
          key: key,
          retry_after_ms: retry_after_ms
        )
        {request, exception}

      :block ->
        handle_blocking_retry(request, key, retry_after_ms, opts, opts.max_retries)
    end
  end

  defp handle_blocking_retry(request, key, retry_after_ms, _opts, retries_remaining)
       when retries_remaining <= 0 do
    exception = ReqThrottle.RateLimitError.exception(
      key: key,
      retry_after_ms: retry_after_ms
    )
    {request, exception}
  end

  defp handle_blocking_retry(request, key, retry_after_ms, opts, retries_remaining) do
    Process.sleep(retry_after_ms)

    case rate_limit_hit(key, opts.rate_limiter) do
      {:allow, _count} ->
        request

      {:deny, new_retry_after_ms} ->
        handle_blocking_retry(request, key, new_retry_after_ms, opts, retries_remaining - 1)
    end
  end
end
