defmodule Curator.EcosystemTest do
  use ExUnit.Case, async: true

  alias Curator.Ecosystem

  describe "library_catalog/0" do
    test "returns catalog data when catalog.json exists" do
      result = Ecosystem.library_catalog()

      assert is_map(result)
      assert Map.has_key?(result, :ok)
      assert Map.has_key?(result, :books)
      assert Map.has_key?(result, :traditions)
      assert Map.has_key?(result, :collections)
      assert Map.has_key?(result, :book_count)
      assert Map.has_key?(result, :tradition_count)
      assert Map.has_key?(result, :collection_count)

      assert is_list(result.books)
      assert is_list(result.traditions)
      assert is_list(result.collections)
      assert is_integer(result.book_count)
    end

    test "returns graceful fallback when path is invalid" do
      original = Application.get_env(:curator, :data_library_path)
      Application.put_env(:curator, :data_library_path, "/tmp/nonexistent_library_#{System.unique_integer([:positive])}")

      result = Ecosystem.library_catalog()

      assert result.ok == false
      assert result.books == []
      assert result.traditions == []
      assert result.book_count == 0

      # Restore
      if original, do: Application.put_env(:curator, :data_library_path, original),
        else: Application.delete_env(:curator, :data_library_path)
    end
  end

  describe "content_stats/0" do
    test "returns content stats with section counts" do
      result = Ecosystem.content_stats()

      assert is_map(result)
      assert Map.has_key?(result, :ok)
      assert Map.has_key?(result, :sections)
      assert Map.has_key?(result, :languages)
      assert Map.has_key?(result, :total_files)
      assert Map.has_key?(result, :available_languages)

      assert is_map(result.sections)
      assert is_map(result.languages)
      assert is_integer(result.total_files)
      assert is_list(result.available_languages)
    end

    test "sections map contains expected keys" do
      result = Ecosystem.content_stats()

      if result.ok do
        for section <- ~w(wiki timeline essentials resources) do
          assert Map.has_key?(result.sections, section),
            "Missing section: #{section}"
          assert is_integer(result.sections[section])
        end
      end
    end

    test "returns graceful fallback when path is invalid" do
      original = Application.get_env(:curator, :data_content_path)
      Application.put_env(:curator, :data_content_path, "/tmp/nonexistent_content_#{System.unique_integer([:positive])}")

      result = Ecosystem.content_stats()

      assert result.ok == false
      assert result.sections == %{}
      assert result.total_files == 0

      if original, do: Application.put_env(:curator, :data_content_path, original),
        else: Application.delete_env(:curator, :data_content_path)
    end
  end

  describe "images_stats/0" do
    test "returns image stats with counts and categories" do
      result = Ecosystem.images_stats()

      assert is_map(result)
      assert Map.has_key?(result, :ok)
      assert Map.has_key?(result, :raw_count)
      assert Map.has_key?(result, :processed_count)
      assert Map.has_key?(result, :manifest_entries)
      assert Map.has_key?(result, :categories)
      assert Map.has_key?(result, :global_settings)

      assert is_integer(result.raw_count)
      assert is_integer(result.processed_count)
      assert is_integer(result.manifest_entries)
      assert is_map(result.categories)
    end

    test "returns graceful fallback when path is invalid" do
      original = Application.get_env(:curator, :data_images_path)
      Application.put_env(:curator, :data_images_path, "/tmp/nonexistent_images_#{System.unique_integer([:positive])}")

      result = Ecosystem.images_stats()

      assert result.ok == false
      assert result.raw_count == 0
      assert result.processed_count == 0
      assert result.manifest_entries == 0
      assert result.categories == %{}

      if original, do: Application.put_env(:curator, :data_images_path, original),
        else: Application.delete_env(:curator, :data_images_path)
    end
  end
end
