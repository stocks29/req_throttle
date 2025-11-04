defmodule ReqThrottle.KeyGeneratorsTest do
  use ExUnit.Case
  doctest ReqThrottle.KeyGenerators

  describe "key generators" do
    test "key_by_host" do
      request = Req.new(url: "https://example.com/api")
      assert ReqThrottle.KeyGenerators.key_by_host(request) == "example.com"
    end

    test "key_by_host with nil host" do
      request = Req.new(url: "invalid-url")
      # URI.parse will return nil for host, so we expect "unknown"
      assert ReqThrottle.KeyGenerators.key_by_host(request) == "unknown"
    end

    test "key_by_path" do
      request = Req.new(url: "https://example.com/api/users")
      assert ReqThrottle.KeyGenerators.key_by_path(request) == "/api/users"
    end

    test "key_by_path with root path" do
      request = Req.new(url: "https://example.com")
      assert ReqThrottle.KeyGenerators.key_by_path(request) == "/"
    end

    test "key_by_host_and_path" do
      request = Req.new(url: "https://example.com/api/users")
      assert ReqThrottle.KeyGenerators.key_by_host_and_path(request) == "example.com/api/users"
    end

    test "key_by_url" do
      url = "https://example.com/api/users?page=1"
      request = Req.new(url: url)
      assert ReqThrottle.KeyGenerators.key_by_url(request) == url
    end

    test "key_by_url with URI struct" do
      uri = %URI{
        scheme: "https",
        host: "example.com",
        path: "/api/users",
        query: "page=1"
      }
      request = %Req.Request{url: uri}
      result = ReqThrottle.KeyGenerators.key_by_url(request)
      assert result == "https://example.com/api/users?page=1"
    end

    test "key_by_host_and_path with nil host" do
      request = Req.new(url: "invalid-url")
      result = ReqThrottle.KeyGenerators.key_by_host_and_path(request)
      # URI.parse returns the string as the path when host is nil
      assert String.starts_with?(result, "unknown")
    end

    test "key_by_host_and_path with nil path" do
      request = Req.new(url: "https://example.com")
      result = ReqThrottle.KeyGenerators.key_by_host_and_path(request)
      assert result == "example.com/"
    end
  end
end
