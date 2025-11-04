defmodule ReqThrottleTest do
  use ExUnit.Case
  doctest ReqThrottle

  setup do
    start_supervised!({TestRateLimiter, []})
    :ok
  end

  describe "attach/2" do
    test "requires rate_limiter option" do
      request = Req.new()

      assert_raise KeyError, fn ->
        ReqThrottle.attach(request, [])
      end
    end

    test "sets default values" do
      request = Req.new()
      TestRateLimiter.set_allow(true)

      attached = ReqThrottle.attach(request, rate_limiter: TestRateLimiter)

      # Check that the step was added
      assert length(attached.request_steps) > 0
    end

    test "accepts custom configuration" do
      request = Req.new()
      key_gen = fn _req -> "custom_key" end
      TestRateLimiter.set_allow(true)

      attached = ReqThrottle.attach(
        request,
        rate_limiter: TestRateLimiter,
        key_generator: key_gen,
        mode: :error,
        max_retries: 10
      )

      assert length(attached.request_steps) > 0
    end

    test "validates mode" do
      request = Req.new()

      assert_raise ArgumentError, ~r/mode must be :block or :error/, fn ->
        ReqThrottle.attach(request, rate_limiter: TestRateLimiter, mode: :invalid)
      end
    end

    test "normalizes MFA key generator" do
      request = Req.new()
      TestRateLimiter.set_allow(true)

      attached = ReqThrottle.attach(
        request,
        rate_limiter: TestRateLimiter,
        key_generator: {ReqThrottle.KeyGenerators, :key_by_host, []}
      )

      assert length(attached.request_steps) > 0
    end

    test "normalizes MFA key generator with arguments" do
      request = Req.new(url: "https://example.com")
      TestRateLimiter.set_allow(true)

      # Test MFA with additional arguments
      attached = ReqThrottle.attach(
        request,
        rate_limiter: TestRateLimiter,
        key_generator: {String, :upcase, ["test"]}
      )

      assert length(attached.request_steps) > 0
    end

    test "validates key generator" do
      request = Req.new()

      assert_raise ArgumentError, ~r/key_generator must be an atom, function, or MFA tuple/, fn ->
        ReqThrottle.attach(
          request,
          rate_limiter: TestRateLimiter,
          key_generator: "invalid"
        )
      end
    end

    test "accepts atom shortcuts for key generators" do
      request = Req.new()
      TestRateLimiter.set_allow(true)

      for atom <- [:host, :path, :host_and_path, :url] do
        attached = ReqThrottle.attach(
          request,
          rate_limiter: TestRateLimiter,
          key_generator: atom
        )

        assert length(attached.request_steps) > 0
      end
    end

    test "validates atom key generator" do
      request = Req.new()

      assert_raise ArgumentError, ~r/key_generator atom must be one of/, fn ->
        ReqThrottle.attach(
          request,
          rate_limiter: TestRateLimiter,
          key_generator: :invalid_atom
        )
      end
    end
  end

  describe "throttle step" do
    test "allows request when rate limit allows" do
      request = Req.new(url: "https://example.com/api")
      TestRateLimiter.set_allow(true)

      client = ReqThrottle.attach(request, rate_limiter: TestRateLimiter)

      # Use a mock adapter to avoid actual HTTP call
      adapter = fn req ->
        response = %Req.Response{status: 200, body: "ok"}
        {req, response}
      end

      {_req, resp} = Req.Request.run_request(%{client | adapter: adapter})
      assert resp.status == 200
    end

    test "returns error exception in error mode when rate limit denies" do
      request = Req.new(url: "https://example.com/api")
      TestRateLimiter.set_allow(false)

      client = ReqThrottle.attach(
        request,
        rate_limiter: TestRateLimiter,
        mode: :error
      )

      # Use a mock adapter
      adapter = fn req ->
        response = %Req.Response{status: 200, body: "ok"}
        {req, response}
      end

      result = Req.Request.run_request(%{client | adapter: adapter})

      assert {_req, %ReqThrottle.RateLimitError{} = error} = result
      assert error.key == "example.com"
      assert error.retry_after_ms == 50
    end

    test "blocks and retries in block mode when rate limit denies then allows" do
      request = Req.new(url: "https://example.com/api")

      # Deny first call, then allow on retry
      TestRateLimiter.set_deny_then_allow(1)

      client = ReqThrottle.attach(
        request,
        rate_limiter: TestRateLimiter,
        mode: :block,
        max_retries: 3
      )

      # Use a mock adapter
      adapter = fn req ->
        response = %Req.Response{status: 200, body: "ok"}
        {req, response}
      end

      {_req, resp} = Req.Request.run_request(%{client | adapter: adapter})
      assert resp.status == 200
    end

    test "returns error exception after max retries in block mode" do
      request = Req.new(url: "https://example.com/api")
      TestRateLimiter.set_allow(false)

      client = ReqThrottle.attach(
        request,
        rate_limiter: TestRateLimiter,
        mode: :block,
        max_retries: 2
      )

      # Use a mock adapter
      adapter = fn req ->
        response = %Req.Response{status: 200, body: "ok"}
        {req, response}
      end

      result = Req.Request.run_request(%{client | adapter: adapter})

      assert {_req, %ReqThrottle.RateLimitError{} = error} = result
      assert error.key == "example.com"
    end

    test "works with function-based rate limiter" do
      _call_count_agent = Agent.start_link(fn -> 0 end, name: :call_counter)
      rate_limiter_fn = fn _key ->
        Agent.update(:call_counter, &(&1 + 1))
        {:allow, 1}
      end

      request = Req.new(url: "https://example.com/api")

      client = ReqThrottle.attach(request, rate_limiter: rate_limiter_fn)

      # Use a mock adapter
      adapter = fn req ->
        response = %Req.Response{status: 200, body: "ok"}
        {req, response}
      end

      {_req, resp} = Req.Request.run_request(%{client | adapter: adapter})
      assert resp.status == 200
      assert Agent.get(:call_counter, & &1) == 1
    end

    test "raises error for invalid rate_limiter type (non-atom, non-function)" do
      request = Req.new(url: "https://example.com/api")

      # Attach with an invalid rate_limiter (string instead of atom or function)
      client = ReqThrottle.attach(request, rate_limiter: "invalid_string")

      adapter = fn req ->
        response = %Req.Response{status: 200, body: "ok"}
        {req, response}
      end

      # This should raise ArgumentError when rate_limit_hit is called
      assert_raise ArgumentError, ~r/rate_limiter must be a module atom or a function/, fn ->
        Req.Request.run_request(%{client | adapter: adapter})
      end
    end
  end

  describe "key generator integration" do
    test "works with custom key generator function" do
      key_gen = fn request -> "custom:#{URI.parse(request.url).host}" end
      request = Req.new(url: "https://example.com/api")
      TestRateLimiter.set_allow(true)

      client = ReqThrottle.attach(
        request,
        rate_limiter: TestRateLimiter,
        key_generator: key_gen
      )

      adapter = fn req ->
        response = %Req.Response{status: 200, body: "ok"}
        {req, response}
      end

      {_req, resp} = Req.Request.run_request(%{client | adapter: adapter})
      assert resp.status == 200
    end

    test "works with atom shortcut key generators" do
      request = Req.new(url: "https://example.com/api")
      TestRateLimiter.set_allow(true)

      # Test :host atom
      client = ReqThrottle.attach(
        request,
        rate_limiter: TestRateLimiter,
        key_generator: :host
      )

      adapter = fn req ->
        response = %Req.Response{status: 200, body: "ok"}
        {req, response}
      end

      {_req, resp} = Req.Request.run_request(%{client | adapter: adapter})
      assert resp.status == 200
    end
  end

  describe "RateLimitError" do
    test "creates error struct with correct fields using new/2" do
      error = ReqThrottle.RateLimitError.new("test-key", 100)

      assert error.key == "test-key"
      assert error.retry_after_ms == 100
      assert error.message =~ "Rate limit exceeded"
    end

    test "creates error struct using exception/1 with keyword args" do
      # Test the keyword args version directly
      error = ReqThrottle.RateLimitError.exception(key: "test-key", retry_after_ms: 100)

      assert error.key == "test-key"
      assert error.retry_after_ms == 100
      assert error.message =~ "Rate limit exceeded"
      assert error.message =~ "test-key"
      assert error.message =~ "100"
    end

    test "creates error struct using exception/1 with opts keyword list" do
      # Test the exception/1 that takes opts as a keyword list variable
      # We need to call it in a way that doesn't match the keyword args clause
      # By using apply/3, we can force it to match the opts clause
      opts = [key: "test-key", retry_after_ms: 200]
      error = apply(ReqThrottle.RateLimitError, :exception, [opts])

      assert error.key == "test-key"
      assert error.retry_after_ms == 200
      assert error.message =~ "Rate limit exceeded"
    end

    test "exception/1 with opts raises KeyError for missing key" do
      # Test that exception/1 with opts validates required keys
      # Use apply/3 to ensure we match the opts clause
      assert_raise KeyError, fn ->
        apply(ReqThrottle.RateLimitError, :exception, [[key: "test"]])
      end
    end

    test "exception/2 with exception and stacktrace (generated by defexception)" do
      # Test the exception/2 function that's automatically generated by defexception
      error = ReqThrottle.RateLimitError.exception(key: "test", retry_after_ms: 100)
      stacktrace = [{__MODULE__, :test, 1, []}]

      # The generated exception/2 function takes the exception and stacktrace
      formatted = Exception.format(:error, error, stacktrace)

      assert formatted =~ "ReqThrottle.RateLimitError"
      assert formatted =~ "test"
    end
  end
end

# Test rate limiter module for testing
defmodule TestRateLimiter do
  use Agent

  def start_link(_opts) do
    Agent.start_link(
      fn -> %{allow: true, call_count: 0, allow_after_denies: :infinity} end,
      name: __MODULE__
    )
  end

  def hit(_key) do
    Agent.get_and_update(__MODULE__, fn state ->
      call_count = state.call_count + 1
      new_state = %{state | call_count: call_count}

      cond do
        state.allow ->
          {{:allow, 1}, new_state}

        state.allow_after_denies != :infinity and call_count > state.allow_after_denies ->
          {{:allow, 1}, %{new_state | allow: true}}

        true ->
          {{:deny, 50}, new_state}
      end
    end)
  end

  def set_allow(allow) do
    Agent.update(__MODULE__, fn state ->
      %{state | allow: allow, call_count: 0, allow_after_denies: :infinity}
    end)
  end

  def set_deny_then_allow(denies_before_allow) do
    Agent.update(__MODULE__, fn state ->
      %{state | allow: false, call_count: 0, allow_after_denies: denies_before_allow}
    end)
  end
end
