defmodule Otto.LLM.Providers.OpenAITest do
  use ExUnit.Case, async: true

  alias Otto.LLM.Providers.OpenAI

  describe "build_client/1" do
    test "creates a client with default configuration" do
      # Note: This will use the API key from config, but we'll mock requests
      client = OpenAI.build_client()
      
      assert %Req.Request{} = client
      assert client.options[:base_url] == "https://api.openai.com"
    end

    test "creates a client with custom options" do
      client = OpenAI.build_client(
        api_key: "test-key", 
        base_url: "https://api.test.com",
        receive_timeout: 60_000
      )
      
      assert %Req.Request{} = client
      assert client.options[:base_url] == "https://api.test.com" 
      assert client.options[:openai_api_key] == "test-key"
      assert client.options[:receive_timeout] == 60_000
    end
  end

  describe "attach/2" do
    test "requires api_key option" do
      assert_raise KeyError, fn ->
        Req.new() |> OpenAI.attach([])
      end
    end

    test "attaches plugin with minimal options" do
      client = Req.new() |> OpenAI.attach(api_key: "test-key")
      
      assert %Req.Request{} = client
      assert client.options[:openai_api_key] == "test-key"
    end
  end

  describe "error handling" do
    test "OpenAI.Error can be created from response" do
      status = 400
      body = %{"error" => %{"type" => "invalid_request", "message" => "Test error"}}
      request = %{}

      error = OpenAI.Error.from_response(status, body, request)

      assert %OpenAI.Error{} = error
      assert error.status_code == 400
      assert error.type == "invalid_request"
      assert error.message == "Test error"
    end

    test "handles JSON parsing errors gracefully" do
      status = 500
      body = "Internal Server Error"
      request = %{}

      error = OpenAI.Error.from_response(status, body, request)

      assert %OpenAI.Error{} = error
      assert error.status_code == 500
      assert error.message == "Internal Server Error"
    end
  end
end