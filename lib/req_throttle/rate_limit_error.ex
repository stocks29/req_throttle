defmodule ReqThrottle.RateLimitError do
  @moduledoc """
  Error struct returned when rate limit is exceeded.

  This struct contains information about the rate limit that was exceeded.
  When used in error mode, this struct is available in the exception or
  in the request's private map.
  """

  defexception [:key, :retry_after_ms, message: ""]

  @type t :: %__MODULE__{
          key: String.t(),
          retry_after_ms: non_neg_integer(),
          message: String.t()
        }

  @doc """
  Creates a new RateLimitError exception.
  """
  def exception(key: key, retry_after_ms: retry_after_ms) do
    %__MODULE__{
      key: key,
      retry_after_ms: retry_after_ms,
      message: "Rate limit exceeded for key '#{key}'. Retry after #{retry_after_ms}ms"
    }
  end

  def exception(opts) do
    exception(
      key: Keyword.fetch!(opts, :key),
      retry_after_ms: Keyword.fetch!(opts, :retry_after_ms)
    )
  end

  @doc """
  Creates a new RateLimitError struct (for backward compatibility).
  """
  def new(key, retry_after_ms) do
    exception(key: key, retry_after_ms: retry_after_ms)
  end
end
