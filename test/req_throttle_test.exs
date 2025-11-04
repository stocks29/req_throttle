defmodule ReqThrottleTest do
  use ExUnit.Case
  doctest ReqThrottle

  test "greets the world" do
    assert ReqThrottle.hello() == :world
  end
end
