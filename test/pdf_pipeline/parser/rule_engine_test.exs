defmodule PdfPipeline.Parser.RuleEngineTest do
  use ExUnit.Case, async: true

  alias PdfPipeline.Parser.RuleEngine
  alias PdfPipeline.Parser.Rules.{ChapterRules, ParagraphRules, SpeakerRules}
  alias PdfPipeline.Parser.TextUtils
  alias PdfPipeline.Schema.Book

  @sample_text """
  # CHAPITRE I

  La Rencontre

  Depuis l'âge de neuf ans, j'ai toujours eu la passion des sports mécaniques.

  Mon père m'a toujours encouragé dans cette voie.

  # CHAPITRE II

  La Vérité

  Yahweh: Il y a très longtemps, nous avons atteint un niveau de connaissance avancé.

  Nous avons créé la vie artificiellement.

  Raël: Mais pourquoi la Terre?

  Yahweh: La Terre était un laboratoire idéal.
  """

  @metadata %{
    slug: "test-book",
    code: "TB",
    primary_lang: "fr",
    title: "Test Book"
  }

  describe "RuleEngine.parse/3" do
    test "parses text into a book struct with default rules" do
      assert {:ok, %Book{} = book} = RuleEngine.parse(@sample_text, @metadata)

      assert book.slug == "test-book"
      assert book.code == "TB"
      assert book.primary_lang == "fr"
      assert length(book.chapters) >= 1
    end

    test "assigns ref_ids to chapters and paragraphs" do
      {:ok, book} = RuleEngine.parse(@sample_text, @metadata)

      first_chapter = List.first(book.chapters)
      assert first_chapter.ref_id =~ "TB-"

      first_para = List.first(first_chapter.paragraphs)
      assert first_para.ref_id =~ "TB-"
      assert first_para.ref_id =~ ":"
    end

    test "parses with raelian profile" do
      {:ok, book} = RuleEngine.parse(@sample_text, @metadata, "raelian")
      assert length(book.chapters) >= 1
    end

    test "falls back to defaults for unknown profile" do
      {:ok, book} = RuleEngine.parse(@sample_text, @metadata, "nonexistent")
      assert %Book{} = book
    end
  end

  describe "ChapterRules.split_chapters/2" do
    test "splits on markdown headings" do
      text = "# Chapter 1\n\nContent one\n\n# Chapter 2\n\nContent two"
      patterns = ["^#+\\s+Chapter\\s+\\d+"]

      result = ChapterRules.split_chapters(text, patterns)

      assert length(result) == 2
      [{t1, c1}, {t2, c2}] = result
      assert t1 =~ "Chapter 1"
      assert c1 =~ "Content one"
      assert t2 =~ "Chapter 2"
      assert c2 =~ "Content two"
    end

    test "returns single chapter when no headings found" do
      text = "Just some text without chapters"
      patterns = ["^#+\\s+Chapter\\s+\\d+"]

      result = ChapterRules.split_chapters(text, patterns)

      assert length(result) == 1
      [{title, content}] = result
      assert title == nil
      assert content =~ "Just some text"
    end
  end

  describe "ParagraphRules.split_paragraphs/2" do
    test "splits on double newlines" do
      text = "First paragraph.\n\nSecond paragraph.\n\nThird paragraph."
      rules = %{"paragraph_separator" => "\\n\\n", "strip_patterns" => []}

      result = ParagraphRules.split_paragraphs(text, rules)

      assert length(result) == 3
      assert Enum.at(result, 0).text == "First paragraph."
      assert Enum.at(result, 1).text == "Second paragraph."
      assert Enum.at(result, 2).text == "Third paragraph."
    end

    test "strips page numbers" do
      text = "Content here.\n\n42\n\nMore content."
      rules = %{"paragraph_separator" => "\\n\\n", "strip_patterns" => ["^\\d{1,3}$"]}

      result = ParagraphRules.split_paragraphs(text, rules)

      texts = Enum.map(result, & &1.text)
      refute "42" in texts
    end

    test "assigns confidence scores" do
      text = "Long paragraph with enough text to be confident.\n\nOk.\n\nAnother paragraph with enough content."
      rules = %{"paragraph_separator" => "\\n\\n", "strip_patterns" => []}

      result = ParagraphRules.split_paragraphs(text, rules)

      long = Enum.find(result, &(String.length(&1.text) > 30))
      short = Enum.find(result, &(String.length(&1.text) < 10))

      assert long.confidence == 1.0
      assert short.confidence < 1.0
    end
  end

  describe "SpeakerRules.detect_speakers/2" do
    test "detects known speakers" do
      paragraphs = [
        %PdfPipeline.Schema.Paragraph{n: 1, text: "Yahweh: Hello", confidence: 1.0},
        %PdfPipeline.Schema.Paragraph{n: 2, text: "Just narration.", confidence: 1.0}
      ]

      rules = %{
        "speaker_patterns" => %{
          "dialogue_dash" => "^[\u2014\u2013]\\s*",
          "known_speakers" => ["Yahweh", "Raël"]
        },
        "default_speaker" => "Narrator"
      }

      result = SpeakerRules.detect_speakers(paragraphs, rules)

      assert Enum.at(result, 0).speaker == "Yahweh"
      assert Enum.at(result, 1).speaker == "Narrator"
    end

    test "flags dialogue with unknown speaker" do
      paragraphs = [
        %PdfPipeline.Schema.Paragraph{n: 1, text: "\u2014 Some dialogue", confidence: 1.0}
      ]

      rules = %{
        "speaker_patterns" => %{
          "dialogue_dash" => "^[\u2014\u2013]\\s*",
          "known_speakers" => []
        },
        "default_speaker" => "Narrator"
      }

      result = SpeakerRules.detect_speakers(paragraphs, rules)

      assert Enum.at(result, 0).confidence <= 0.5
    end
  end

  describe "TextUtils" do
    test "strip_patterns removes matching lines" do
      text = "Content\n42\nMore content"
      assert TextUtils.strip_patterns(text, ["^\\d{1,3}$"]) =~ "Content"
      refute TextUtils.strip_patterns(text, ["^\\d{1,3}$"]) =~ "\n42\n"
    end

    test "split_paragraphs splits on double newlines" do
      text = "Para 1\n\nPara 2\n\nPara 3"
      result = TextUtils.split_paragraphs(text)
      assert length(result) == 3
    end

    test "merge_hyphenated_words merges across lines" do
      assert TextUtils.merge_hyphenated_words("com-\nputer") == "computer"
    end

    test "page_number? detects page numbers" do
      assert TextUtils.page_number?("42")
      assert TextUtils.page_number?("  123  ")
      refute TextUtils.page_number?("hello")
      refute TextUtils.page_number?("12345")
    end
  end
end
