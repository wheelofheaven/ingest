defmodule Curator.OCR.ClientTest do
  use ExUnit.Case, async: true

  alias Curator.OCR.Response

  describe "Response.parse/1" do
    test "parses standard chat completion format" do
      body = %{
        "choices" => [
          %{"message" => %{"content" => "Hello world"}}
        ]
      }

      assert {:ok, "Hello world"} = Response.parse(body)
    end

    test "parses result format" do
      body = %{"result" => %{"content" => "Hello world"}}
      assert {:ok, "Hello world"} = Response.parse(body)
    end

    test "parses direct content format" do
      body = %{"content" => "Hello world"}
      assert {:ok, "Hello world"} = Response.parse(body)
    end

    test "parses raw string" do
      assert {:ok, "Hello world"} = Response.parse("Hello world")
    end

    test "returns error for API errors" do
      body = %{"error" => "rate limited"}
      assert {:error, {:api_error, "rate limited"}} = Response.parse(body)
    end

    test "returns error for unexpected format" do
      body = %{"unexpected" => true}
      assert {:error, {:unexpected_format, _}} = Response.parse(body)
    end
  end

  describe "Response.normalize_text/1" do
    test "normalizes line endings" do
      assert Response.normalize_text("foo\r\nbar\rbaz") == "foo\nbar\nbaz"
    end

    test "strips BOM" do
      assert Response.normalize_text("\uFEFFhello") == "hello"
    end

    test "collapses excessive newlines" do
      assert Response.normalize_text("a\n\n\n\n\nb") == "a\n\n\nb"
    end

    test "trims whitespace" do
      assert Response.normalize_text("  hello  ") == "hello"
    end
  end
end
