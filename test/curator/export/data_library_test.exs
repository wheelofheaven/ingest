defmodule Curator.Export.DataLibraryTest do
  use ExUnit.Case, async: true

  alias Curator.Schema.{Book, Chapter, Paragraph}
  alias Curator.Export.{SingleFile, SplitFile, DataLibrary}

  @test_book %Book{
    slug: "test-book",
    code: "TB",
    primary_lang: "fr",
    titles: %{"fr" => "Le Livre Test"},
    publication_year: 1973,
    revision: 1,
    updated: "2025-01-01T00:00:00Z",
    chapters: [
      %Chapter{
        n: 1,
        title: "Chapitre Un",
        ref_id: "TB-1",
        i18n: %{},
        paragraphs: [
          %Paragraph{
            n: 1,
            text: "Premier paragraphe.",
            speaker: "Narrator",
            ref_id: "TB-1:1",
            i18n: %{},
            confidence: 1.0
          },
          %Paragraph{
            n: 2,
            text: "Deuxième paragraphe.",
            speaker: "Yahweh",
            ref_id: "TB-1:2",
            i18n: %{},
            confidence: 0.8
          }
        ]
      },
      %Chapter{
        n: 2,
        title: "Chapitre Deux",
        ref_id: "TB-2",
        i18n: %{},
        paragraphs: [
          %Paragraph{
            n: 1,
            text: "Troisième paragraphe.",
            speaker: "Narrator",
            ref_id: "TB-2:1",
            i18n: %{},
            confidence: 1.0
          }
        ]
      }
    ]
  }

  describe "Book.to_json/1" do
    test "produces valid data-library format" do
      json = Book.to_json(@test_book)

      assert json["slug"] == "test-book"
      assert json["code"] == "TB"
      assert json["primaryLang"] == "fr"
      assert json["schema"] == ["book", "chapters", "paragraphs"]
      assert json["chapterCount"] == 2
      assert json["paragraphCount"] == 3
      assert json["refId"] == "TB"
    end

    test "chapters have correct structure" do
      json = Book.to_json(@test_book)
      ch1 = List.first(json["chapters"])

      assert ch1["n"] == 1
      assert ch1["title"] == "Chapitre Un"
      assert ch1["refId"] == "TB-1"
      assert is_map(ch1["i18n"])
    end

    test "paragraphs have correct structure" do
      json = Book.to_json(@test_book)
      ch1 = List.first(json["chapters"])
      p1 = List.first(ch1["paragraphs"])

      assert p1["n"] == 1
      assert p1["text"] == "Premier paragraphe."
      assert p1["speaker"] == "Narrator"
      assert p1["refId"] == "TB-1:1"
      assert is_map(p1["i18n"])
    end
  end

  describe "Book.assign_ref_ids/1" do
    test "assigns correct ref_id format" do
      book = Book.assign_ref_ids(@test_book)

      ch1 = List.first(book.chapters)
      assert ch1.ref_id == "TB-1"
      assert List.first(ch1.paragraphs).ref_id == "TB-1:1"

      ch2 = Enum.at(book.chapters, 1)
      assert ch2.ref_id == "TB-2"
      assert List.first(ch2.paragraphs).ref_id == "TB-2:1"
    end
  end

  describe "Book.init_i18n/2" do
    test "initializes empty i18n slots" do
      book = Book.init_i18n(@test_book, ~w(en fr de es))

      ch1 = List.first(book.chapters)
      # Should have en, de, es but NOT fr (primary lang)
      assert Map.has_key?(ch1.i18n, "en")
      assert Map.has_key?(ch1.i18n, "de")
      assert Map.has_key?(ch1.i18n, "es")
      refute Map.has_key?(ch1.i18n, "fr")

      p1 = List.first(ch1.paragraphs)
      assert p1.i18n["en"] == ""
      assert p1.i18n["de"] == ""
    end
  end

  describe "SingleFile.write/2" do
    test "writes a single JSON file" do
      dir = Path.join(System.tmp_dir!(), "curator_test_#{System.unique_integer([:positive])}")

      assert {:ok, path} = SingleFile.write(@test_book, dir)
      assert File.exists?(path)
      assert path =~ "test-book.json"

      content = File.read!(path) |> Jason.decode!()
      assert content["slug"] == "test-book"
      assert content["chapterCount"] == 2

      File.rm_rf!(dir)
    end
  end

  describe "SplitFile.write/2" do
    test "writes meta and chapter files" do
      dir = Path.join(System.tmp_dir!(), "curator_test_#{System.unique_integer([:positive])}")

      assert {:ok, book_dir} = SplitFile.write(@test_book, dir)
      assert File.exists?(Path.join(book_dir, "_meta.json"))
      assert File.exists?(Path.join(book_dir, "chapter-1.json"))
      assert File.exists?(Path.join(book_dir, "chapter-2.json"))

      meta = Path.join(book_dir, "_meta.json") |> File.read!() |> Jason.decode!()
      assert meta["slug"] == "test-book"
      assert meta["chapterCount"] == 2
      assert length(meta["chapterFiles"]) == 2

      ch1 = Path.join(book_dir, "chapter-1.json") |> File.read!() |> Jason.decode!()
      assert ch1["n"] == 1
      assert ch1["bookSlug"] == "test-book"
      assert length(ch1["paragraphs"]) == 2

      File.rm_rf!(dir)
    end
  end

  describe "Validator" do
    test "validates correct book JSON" do
      json = Book.to_json(@test_book)
      assert {:ok, _} = Curator.Schema.Validator.validate_book(json)
    end

    test "rejects invalid book JSON" do
      json = %{"invalid" => true}
      assert {:error, _errors} = Curator.Schema.Validator.validate_book(json)
    end
  end

  describe "DataLibrary.preview/1" do
    test "returns preview JSON" do
      assert {:ok, json} = DataLibrary.preview(@test_book)
      assert is_map(json)
      assert json["slug"] == "test-book"
    end
  end
end
