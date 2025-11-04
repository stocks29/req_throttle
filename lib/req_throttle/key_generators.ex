defmodule ReqThrottle.KeyGenerators do
  @moduledoc """
  Pre-configured key generator functions for rate limiting.

  These functions can be used with `ReqThrottle.attach/2` to generate
  rate limit keys from request URLs.
  """

  @doc """
  Key generator that uses the request host.
  """
  def key_by_host(%Req.Request{url: %URI{} = uri}), do: uri.host || "unknown"

  @doc """
  Key generator that uses the request path.
  """
  def key_by_path(%Req.Request{url: %URI{} = uri}), do: uri.path || "/"

  @doc """
  Key generator that uses host and path.
  """
  def key_by_host_and_path(%Req.Request{} = request) do
    "#{key_by_host(request)}#{key_by_path(request)}"
  end

  @doc """
  Key generator that uses the full URL.
  """
  def key_by_url(%Req.Request{url: %URI{} = uri}), do: URI.to_string(uri)
end
