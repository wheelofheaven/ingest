defmodule CuratorWeb.EditorLive do
  use CuratorWeb, :live_view

  alias Curator.Store.Job
  alias Curator.Schema.{Book, Chapter, Paragraph, Section}
  alias Curator.Stages.{WorkDir, Normalize}
  alias Curator.Git

  @impl true
  def mount(params, _session, socket) do
    case load_book(params) do
      {:ok, book, slug, source} ->
        repeated = detect_repeated_patterns(book)
        speakers = load_speakers(slug, book)

        {:ok,
         socket
         |> assign(:book, book)
         |> assign(:saved_book, book)
         |> assign(:slug, slug)
         |> assign(:source, source)
         |> assign(:speakers, speakers)
         |> assign(:selected_chapter, 1)
         |> assign(:editing_paragraph, nil)
         |> assign(:editing_chapter, nil)
         |> assign(:editing_section, nil)
         |> assign(:editing_metadata, false)
         |> assign(:focused_ref, nil)
         |> assign(:selected_refs, MapSet.new())
         |> assign(:repeated_patterns, repeated)
         |> assign(:show_patterns, false)
         |> assign(:dirty, false)
         |> assign(:synced, !Git.has_unpushed?())
         |> assign(:page_title, "Edit: #{slug}")}

      {:error, message} ->
        {:ok,
         socket
         |> put_flash(:error, message)
         |> push_navigate(to: ~p"/")}
    end
  end

  defp load_book(%{"slug" => slug}) do
    case Normalize.load_book(slug) do
      {:ok, book} -> {:ok, book, slug, :work_dir}
      {:error, _} -> {:error, "No book.json found for #{slug}"}
    end
  end

  defp load_book(%{"job_id" => job_id}) do
    case Job.get(job_id) do
      {:ok, %{book: nil}} -> {:error, "Book not yet parsed"}
      {:ok, %{book: book, metadata: meta}} -> {:ok, book, meta[:slug], {:job, job_id}}
      {:error, :not_found} -> {:error, "Job not found"}
    end
  end

  # -- Scroll-based focus --

  @impl true
  def handle_event("scroll_focus", %{"ref-id" => ref_id}, socket) do
    {:noreply, assign(socket, :focused_ref, ref_id)}
  end

  # -- Chapter navigation --

  def handle_event("select_chapter", %{"chapter" => chapter}, socket) do
    {:noreply,
     socket
     |> assign(:selected_chapter, String.to_integer(chapter))
     |> assign(:editing_paragraph, nil)
     |> assign(:focused_ref, nil)
     |> assign(:selected_refs, MapSet.new())}
  end

  # -- Paragraph editing --

  def handle_event("edit_paragraph", %{"ref-id" => ref_id}, socket) do
    {:noreply, assign(socket, :editing_paragraph, ref_id)}
  end

  def handle_event("cancel_edit", _params, socket) do
    {:noreply, assign(socket, :editing_paragraph, nil)}
  end

  def handle_event("save_paragraph", %{"ref_id" => ref_id, "text" => text} = params, socket) do
    book = update_paragraph(socket.assigns.book, ref_id, fn para ->
      para = %{para | text: String.trim(text), confidence: 1.0}

      case params do
        %{"speaker" => ""} -> %{para | speaker: nil}
        %{"speaker" => speaker} -> %{para | speaker: speaker}
        _ -> para
      end
    end)

    {:noreply,
     socket
     |> assign(:book, book)
     |> assign(:editing_paragraph, nil)
     |> assign(:dirty, true)}
  end

  # -- Delete paragraph --

  def handle_event("delete_paragraph", %{"ref-id" => ref_id}, socket) do
    book = delete_paragraphs(socket.assigns.book, [ref_id])

    {:noreply,
     socket
     |> assign(:book, book)
     |> assign(:dirty, true)
     |> assign(:repeated_patterns, detect_repeated_patterns(book))}
  end

  # -- Multi-select --

  def handle_event("toggle_select", %{"ref-id" => ref_id}, socket) do
    selected = socket.assigns.selected_refs

    selected =
      if MapSet.member?(selected, ref_id),
        do: MapSet.delete(selected, ref_id),
        else: MapSet.put(selected, ref_id)

    {:noreply, assign(socket, :selected_refs, selected)}
  end

  def handle_event("select_all_chapter", _params, socket) do
    chapter = get_chapter(socket.assigns.book, socket.assigns.selected_chapter)

    refs =
      if chapter,
        do: MapSet.new(Enum.map(Chapter.all_paragraphs(chapter), & &1.ref_id)),
        else: MapSet.new()

    {:noreply, assign(socket, :selected_refs, refs)}
  end

  def handle_event("select_none", _params, socket) do
    {:noreply, assign(socket, :selected_refs, MapSet.new())}
  end

  def handle_event("delete_selected", _params, socket) do
    refs = MapSet.to_list(socket.assigns.selected_refs)
    count = length(refs)

    if count > 0 do
      book = delete_paragraphs(socket.assigns.book, refs)

      {:noreply,
       socket
       |> assign(:book, book)
       |> assign(:selected_refs, MapSet.new())
       |> assign(:dirty, true)
       |> assign(:repeated_patterns, detect_repeated_patterns(book))
       |> put_flash(:info, "Deleted #{count} paragraphs")}
    else
      {:noreply, socket}
    end
  end

  def handle_event("set_speaker_selected", %{"speaker" => speaker}, socket) do
    speaker = if speaker == "", do: nil, else: speaker
    refs = socket.assigns.selected_refs

    book =
      Enum.reduce(refs, socket.assigns.book, fn ref_id, book ->
        update_paragraph(book, ref_id, fn para -> %{para | speaker: speaker} end)
      end)

    {:noreply,
     socket
     |> assign(:book, book)
     |> assign(:selected_refs, MapSet.new())
     |> assign(:dirty, true)
     |> put_flash(:info, "Speaker set for #{MapSet.size(refs)} paragraphs")}
  end

  # -- Repeated patterns --

  def handle_event("toggle_patterns", _params, socket) do
    {:noreply, assign(socket, :show_patterns, !socket.assigns.show_patterns)}
  end

  def handle_event("remove_pattern", %{"pattern" => pattern}, socket) do
    book = socket.assigns.book

    matching_refs =
      book.chapters
      |> Enum.flat_map(&Chapter.all_paragraphs/1)
      |> Enum.filter(fn p -> String.trim(p.text) == pattern end)
      |> Enum.map(& &1.ref_id)

    book = delete_paragraphs(book, matching_refs)

    {:noreply,
     socket
     |> assign(:book, book)
     |> assign(:dirty, true)
     |> assign(:repeated_patterns, detect_repeated_patterns(book))
     |> put_flash(:info, "Removed #{length(matching_refs)} occurrences")}
  end

  def handle_event("select_pattern", %{"pattern" => pattern}, socket) do
    book = socket.assigns.book

    matching_refs =
      book.chapters
      |> Enum.flat_map(&Chapter.all_paragraphs/1)
      |> Enum.filter(fn p -> String.trim(p.text) == pattern end)
      |> Enum.map(& &1.ref_id)
      |> MapSet.new()

    {:noreply, assign(socket, :selected_refs, matching_refs)}
  end

  # -- Merge with next --

  def handle_event("merge_with_next", %{"ref-id" => ref_id}, socket) do
    chapter_n = socket.assigns.selected_chapter
    book = socket.assigns.book

    updated_chapters =
      Enum.map(book.chapters, fn chapter ->
        if chapter.n == chapter_n, do: merge_paragraphs(chapter, ref_id), else: chapter
      end)

    book = %{book | chapters: updated_chapters} |> Book.assign_ref_ids()

    {:noreply,
     socket
     |> assign(:book, book)
     |> assign(:dirty, true)}
  end

  # -- Speaker list management --

  def handle_event("add_speaker_option", %{"speaker" => name}, socket) do
    name = String.trim(name)

    if name != "" and name not in socket.assigns.speakers do
      speakers = (socket.assigns.speakers ++ [name]) |> Enum.sort()
      {:noreply, assign(socket, :speakers, speakers)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("remove_speaker_option", %{"speaker" => name}, socket) do
    speakers = Enum.reject(socket.assigns.speakers, &(&1 == name))
    {:noreply, assign(socket, :speakers, speakers)}
  end

  # -- Quick speaker set --

  def handle_event("set_speaker", %{"ref-id" => ref_id, "speaker" => speaker}, socket) do
    speaker = if speaker == "", do: nil, else: speaker

    book = update_paragraph(socket.assigns.book, ref_id, fn para ->
      %{para | speaker: speaker}
    end)

    {:noreply,
     socket
     |> assign(:book, book)
     |> assign(:dirty, true)}
  end

  # -- Glue / merge paragraphs (between-paragraph action) --

  def handle_event("glue_paragraphs", %{"ref-id" => ref_id}, socket) do
    chapter_n = socket.assigns.selected_chapter
    book = socket.assigns.book

    # ref_id is the SECOND paragraph — we merge the one BEFORE it with this one
    chapter = get_chapter(book, chapter_n)

    if chapter do
      all_paras = Chapter.all_paragraphs(chapter)
      idx = Enum.find_index(all_paras, &(&1.ref_id == ref_id))

      if idx && idx > 0 do
        prev = Enum.at(all_paras, idx - 1)
        book = glue_paragraph_pair(book, chapter_n, prev.ref_id)

        {:noreply,
         socket
         |> assign(:book, book)
         |> assign(:dirty, true)}
      else
        {:noreply, socket}
      end
    else
      {:noreply, socket}
    end
  end

  # -- Chapter break insertion --

  def handle_event("insert_chapter_break", %{"ref-id" => ref_id}, socket) do
    book = socket.assigns.book
    chapter_n = socket.assigns.selected_chapter
    book = split_chapter_at_paragraph(book, chapter_n, ref_id)

    # The new chapter is chapter_n + 1 — switch to it and open title editing
    new_chapter_n = chapter_n + 1

    {:noreply,
     socket
     |> assign(:book, book)
     |> assign(:selected_chapter, new_chapter_n)
     |> assign(:editing_chapter, new_chapter_n)
     |> assign(:dirty, true)
     |> put_flash(:info, "Chapter break inserted — name your new chapter")}
  end

  # -- Section break insertion --

  def handle_event("insert_section_break", %{"ref-id" => ref_id}, socket) do
    book = socket.assigns.book
    chapter_n = socket.assigns.selected_chapter
    book = split_section_at_paragraph(book, chapter_n, ref_id)

    {:noreply,
     socket
     |> assign(:book, book)
     |> assign(:editing_section, {chapter_n, :new})
     |> assign(:dirty, true)
     |> put_flash(:info, "Section break inserted")}
  end

  def handle_event("remove_section_break", %{"chapter" => ch_str, "section" => s_str}, socket) do
    ch_n = String.to_integer(ch_str)
    s_n = String.to_integer(s_str)
    book = socket.assigns.book

    if s_n > 1 do
      book = merge_sections(book, ch_n, s_n - 1)

      {:noreply,
       socket
       |> assign(:book, book)
       |> assign(:dirty, true)
       |> put_flash(:info, "Section break removed")}
    else
      {:noreply, put_flash(socket, :error, "Cannot remove the first section break")}
    end
  end

  def handle_event("rename_section", %{"chapter" => ch_str, "section" => s_str, "title" => title}, socket) do
    ch_n = String.to_integer(ch_str)
    s_n = String.to_integer(s_str)
    book = socket.assigns.book

    chapters =
      Enum.map(book.chapters, fn ch ->
        if ch.n == ch_n do
          sections =
            Enum.map(ch.sections, fn s ->
              if s.n == s_n, do: %{s | title: String.trim(title)}, else: s
            end)

          %{ch | sections: sections}
        else
          ch
        end
      end)

    {:noreply,
     socket
     |> assign(:book, %{book | chapters: chapters})
     |> assign(:editing_section, nil)
     |> assign(:dirty, true)}
  end

  def handle_event("edit_section_title", %{"chapter" => ch_str, "section" => s_str}, socket) do
    {:noreply, assign(socket, :editing_section, {String.to_integer(ch_str), String.to_integer(s_str)})}
  end

  def handle_event("cancel_edit_section", _params, socket) do
    {:noreply, assign(socket, :editing_section, nil)}
  end

  def handle_event("delete_section", %{"chapter" => ch_str, "section" => s_str}, socket) do
    ch_n = String.to_integer(ch_str)
    s_n = String.to_integer(s_str)
    book = socket.assigns.book

    chapters =
      Enum.map(book.chapters, fn ch ->
        if ch.n == ch_n and Chapter.has_sections?(ch) do
          sections = Enum.reject(ch.sections, &(&1.n == s_n))

          if length(sections) <= 1 do
            # Only one (or zero) section left — flatten
            all_paras = Enum.flat_map(sections, & &1.paragraphs)
            %{ch | paragraphs: all_paras, sections: []}
          else
            %{ch | sections: sections}
          end
        else
          ch
        end
      end)

    book = %{book | chapters: chapters} |> Book.assign_ref_ids()

    {:noreply,
     socket
     |> assign(:book, book)
     |> assign(:dirty, true)
     |> put_flash(:info, "Section deleted")}
  end

  def handle_event("remove_all_section_breaks", %{"chapter" => ch_str}, socket) do
    ch_n = String.to_integer(ch_str)
    book = socket.assigns.book

    chapters =
      Enum.map(book.chapters, fn ch ->
        if ch.n == ch_n and Chapter.has_sections?(ch) do
          all_paras = Chapter.all_paragraphs(ch)
          %{ch | paragraphs: all_paras, sections: []}
        else
          ch
        end
      end)

    book = %{book | chapters: chapters} |> Book.assign_ref_ids()

    {:noreply,
     socket
     |> assign(:book, book)
     |> assign(:dirty, true)
     |> put_flash(:info, "All section breaks removed")}
  end

  # -- Chapter editing --

  def handle_event("rename_chapter", %{"chapter" => n_str, "title" => title}, socket) do
    n = String.to_integer(n_str)
    book = socket.assigns.book

    chapters =
      Enum.map(book.chapters, fn ch ->
        if ch.n == n, do: %{ch | title: String.trim(title)}, else: ch
      end)

    {:noreply,
     socket
     |> assign(:book, %{book | chapters: chapters})
     |> assign(:editing_chapter, nil)
     |> assign(:dirty, true)}
  end

  def handle_event("edit_chapter_title", %{"chapter" => n_str}, socket) do
    {:noreply, assign(socket, :editing_chapter, String.to_integer(n_str))}
  end

  def handle_event("cancel_edit_chapter", _params, socket) do
    {:noreply, assign(socket, :editing_chapter, nil)}
  end

  def handle_event("remove_chapter_break", %{"chapter" => n_str}, socket) do
    n = String.to_integer(n_str)
    book = socket.assigns.book

    if n > 1 do
      book = merge_chapters(book, n - 1)

      {:noreply,
       socket
       |> assign(:book, book)
       |> assign(:selected_chapter, n - 1)
       |> assign(:dirty, true)
       |> put_flash(:info, "Chapter break removed")}
    else
      {:noreply, put_flash(socket, :error, "Cannot remove the first chapter break")}
    end
  end

  def handle_event("delete_chapter", %{"chapter" => n_str}, socket) do
    n = String.to_integer(n_str)
    book = socket.assigns.book

    chapters = Enum.reject(book.chapters, &(&1.n == n))
    book = %{book | chapters: chapters} |> Book.assign_ref_ids()

    new_selected = min(socket.assigns.selected_chapter, length(chapters))
    new_selected = max(new_selected, 1)

    {:noreply,
     socket
     |> assign(:book, book)
     |> assign(:selected_chapter, new_selected)
     |> assign(:dirty, true)
     |> put_flash(:info, "Chapter deleted")}
  end

  # -- Metadata editing --

  def handle_event("toggle_metadata", _params, socket) do
    {:noreply, assign(socket, :editing_metadata, !socket.assigns.editing_metadata)}
  end

  def handle_event("save_metadata", params, socket) do
    book = socket.assigns.book

    titles =
      case params["title"] do
        nil -> book.titles
        title -> Map.put(book.titles, book.primary_lang || "en", String.trim(title))
      end

    primary_lang = String.trim(params["primary_lang"] || book.primary_lang || "en")

    # If primary_lang changed and the title was under the old key, move it
    titles =
      if primary_lang != book.primary_lang and Map.has_key?(titles, book.primary_lang) do
        {val, rest} = Map.pop(titles, book.primary_lang)
        Map.put_new(rest, primary_lang, val)
      else
        titles
      end

    pub_year =
      case Integer.parse(params["publication_year"] || "") do
        {y, _} -> y
        :error -> book.publication_year
      end

    code = String.trim(params["code"] || book.code || "")

    book = %{book |
      titles: titles,
      primary_lang: primary_lang,
      publication_year: pub_year,
      code: if(code != "", do: code, else: book.code)
    } |> Book.assign_ref_ids()

    new_slug = String.trim(params["slug"] || socket.assigns.slug)
    new_slug = if new_slug != "", do: new_slug, else: socket.assigns.slug
    book = %{book | slug: new_slug}

    {:noreply,
     socket
     |> assign(:book, book)
     |> assign(:slug, new_slug)
     |> assign(:editing_metadata, false)
     |> assign(:dirty, true)
     |> assign(:page_title, "Edit: #{new_slug}")}
  end

  # -- Save --

  def handle_event("save_to_disk", _params, socket) do
    book = socket.assigns.book
    slug = socket.assigns.slug
    saved_book = socket.assigns.saved_book
    json = Book.to_json(book)
    encoded = Jason.encode!(json, pretty: true)
    {:ok, path} = WorkDir.write_artifact(slug, "book.json", encoded)

    # Persist speaker list
    save_speakers(slug, socket.assigns.speakers)

    case socket.assigns.source do
      {:job, job_id} -> Job.update(job_id, %{book: book})
      _ -> :ok
    end

    # Git commit
    commit_message = build_commit_message(slug, saved_book, book)

    flash =
      case Git.commit(slug, commit_message) do
        {:ok, :no_changes} -> "Saved to #{path}"
        {:ok, sha} -> "Saved to #{path} (commit #{sha})"
        {:error, reason} -> "Saved to #{path} (git error: #{reason})"
      end

    {:noreply,
     socket
     |> assign(:saved_book, book)
     |> assign(:dirty, false)
     |> assign(:synced, false)
     |> put_flash(:info, flash)}
  end

  # -- Sync --

  def handle_event("sync", _params, socket) do
    case Git.push() do
      :ok ->
        {:noreply,
         socket
         |> assign(:synced, true)
         |> put_flash(:info, "Pushed to origin")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Push failed: #{reason}")}
    end
  end

  # -- Vetting --

  def handle_event("toggle_vet", %{"ref-id" => ref_id}, socket) do
    book = socket.assigns.book
    para = find_paragraph(book, ref_id)

    case para.vetted do
      true ->
        # Vetted → skipped (explicitly unvet)
        book = update_paragraph(book, ref_id, fn p -> %{p | vetted: :skipped} end)
        {:noreply, socket |> assign(:book, book) |> assign(:dirty, true)}

      :skipped ->
        # Skipped → re-vet (just this one, no waterfall)
        book = update_paragraph(book, ref_id, fn p -> %{p | vetted: true} end)
        {:noreply, socket |> assign(:book, book) |> assign(:dirty, true)}

      false ->
        # Unreviewed → vet + waterfall: vet all preceding `false` paragraphs
        all_paras = book.chapters |> Enum.flat_map(&Chapter.all_paragraphs/1)
        idx = Enum.find_index(all_paras, &(&1.ref_id == ref_id))

        refs_to_vet =
          all_paras
          |> Enum.take(idx + 1)
          |> Enum.filter(&(&1.vetted == false))
          |> Enum.map(& &1.ref_id)
          |> MapSet.new()

        book = update_paragraphs(book, refs_to_vet, fn p -> %{p | vetted: true} end)
        {:noreply, socket |> assign(:book, book) |> assign(:dirty, true)}
    end
  end

  # -- Private helpers --

  defp get_chapter(book, n) do
    Enum.find(book.chapters, &(&1.n == n))
  end

  defp find_paragraph(book, ref_id) do
    book.chapters
    |> Enum.flat_map(&Chapter.all_paragraphs/1)
    |> Enum.find(&(&1.ref_id == ref_id))
  end

  defp update_paragraph(book, ref_id, update_fn) do
    chapters =
      Enum.map(book.chapters, fn chapter ->
        if Chapter.has_sections?(chapter) do
          sections =
            Enum.map(chapter.sections, fn section ->
              paragraphs =
                Enum.map(section.paragraphs, fn para ->
                  if para.ref_id == ref_id, do: update_fn.(para), else: para
                end)

              %{section | paragraphs: paragraphs}
            end)

          %{chapter | sections: sections}
        else
          paragraphs =
            Enum.map(chapter.paragraphs, fn para ->
              if para.ref_id == ref_id, do: update_fn.(para), else: para
            end)

          %{chapter | paragraphs: paragraphs}
        end
      end)

    %{book | chapters: chapters}
  end

  defp update_paragraphs(book, ref_id_set, update_fn) do
    chapters =
      Enum.map(book.chapters, fn chapter ->
        if Chapter.has_sections?(chapter) do
          sections =
            Enum.map(chapter.sections, fn section ->
              paragraphs =
                Enum.map(section.paragraphs, fn para ->
                  if MapSet.member?(ref_id_set, para.ref_id), do: update_fn.(para), else: para
                end)

              %{section | paragraphs: paragraphs}
            end)

          %{chapter | sections: sections}
        else
          paragraphs =
            Enum.map(chapter.paragraphs, fn para ->
              if MapSet.member?(ref_id_set, para.ref_id), do: update_fn.(para), else: para
            end)

          %{chapter | paragraphs: paragraphs}
        end
      end)

    %{book | chapters: chapters}
  end

  defp delete_paragraphs(book, ref_ids) do
    ref_set = MapSet.new(ref_ids)

    chapters =
      Enum.map(book.chapters, fn chapter ->
        if Chapter.has_sections?(chapter) do
          sections =
            chapter.sections
            |> Enum.map(fn section ->
              paragraphs = Enum.reject(section.paragraphs, &MapSet.member?(ref_set, &1.ref_id))
              %{section | paragraphs: paragraphs}
            end)
            |> Enum.reject(fn s -> s.paragraphs == [] end)

          if sections == [] do
            %{chapter | sections: [], paragraphs: []}
          else
            %{chapter | sections: sections}
          end
        else
          paragraphs = Enum.reject(chapter.paragraphs, &MapSet.member?(ref_set, &1.ref_id))
          %{chapter | paragraphs: paragraphs}
        end
      end)

    %{book | chapters: chapters} |> Book.assign_ref_ids()
  end

  defp merge_paragraphs(chapter, ref_id) do
    if Chapter.has_sections?(chapter) do
      # Merge within sections — get flat list, find pair, rebuild sections
      all_paras = Chapter.all_paragraphs(chapter)
      idx = Enum.find_index(all_paras, &(&1.ref_id == ref_id))

      if idx && idx < length(all_paras) - 1 do
        current = Enum.at(all_paras, idx)
        next_para = Enum.at(all_paras, idx + 1)
        merged = %{current | text: current.text <> "\n\n" <> next_para.text}
        next_ref = next_para.ref_id

        sections =
          Enum.map(chapter.sections, fn section ->
            paragraphs =
              section.paragraphs
              |> Enum.map(fn p -> if p.ref_id == current.ref_id, do: merged, else: p end)
              |> Enum.reject(fn p -> p.ref_id == next_ref end)

            %{section | paragraphs: paragraphs}
          end)
          |> Enum.reject(fn s -> s.paragraphs == [] end)

        %{chapter | sections: sections}
      else
        chapter
      end
    else
      paragraphs = chapter.paragraphs
      idx = Enum.find_index(paragraphs, &(&1.ref_id == ref_id))

      if idx && idx < length(paragraphs) - 1 do
        current = Enum.at(paragraphs, idx)
        next = Enum.at(paragraphs, idx + 1)
        merged = %{current | text: current.text <> "\n\n" <> next.text}

        paragraphs
        |> List.delete_at(idx + 1)
        |> List.replace_at(idx, merged)
        |> then(&%{chapter | paragraphs: &1})
      else
        chapter
      end
    end
  end

  defp split_chapter_at_paragraph(book, chapter_n, ref_id) do
    chapters =
      Enum.flat_map(book.chapters, fn chapter ->
        if chapter.n == chapter_n do
          all_paras = Chapter.all_paragraphs(chapter)

          case Enum.find_index(all_paras, &(&1.ref_id == ref_id)) do
            nil ->
              [chapter]

            0 ->
              [chapter]

            idx ->
              {before_paras, after_paras} = Enum.split(all_paras, idx)

              first_para = List.first(after_paras)

              new_title =
                if first_para,
                  do: String.slice(first_para.text, 0, 60) |> String.trim(),
                  else: "New Chapter"

              # Flatten: new chapters lose sections (user can re-add)
              [
                %{chapter | paragraphs: before_paras, sections: []},
                Chapter.new(%{n: chapter.n + 1, title: new_title, paragraphs: after_paras})
              ]
          end
        else
          [chapter]
        end
      end)

    %{book | chapters: chapters} |> Book.assign_ref_ids()
  end

  defp merge_chapters(book, chapter_n) do
    chapters = book.chapters
    idx = Enum.find_index(chapters, &(&1.n == chapter_n))

    if idx && idx < length(chapters) - 1 do
      current = Enum.at(chapters, idx)
      next = Enum.at(chapters, idx + 1)

      # Flatten both to paragraphs for a clean merge
      all_paras = Chapter.all_paragraphs(current) ++ Chapter.all_paragraphs(next)
      merged = %{current | paragraphs: all_paras, sections: []}

      chapters
      |> List.delete_at(idx + 1)
      |> List.replace_at(idx, merged)
      |> then(&%{book | chapters: &1})
      |> Book.assign_ref_ids()
    else
      book
    end
  end

  defp split_section_at_paragraph(book, chapter_n, ref_id) do
    chapters =
      Enum.map(book.chapters, fn chapter ->
        if chapter.n == chapter_n do
          if Chapter.has_sections?(chapter) do
            # Find which section contains this paragraph and split it
            sections =
              Enum.flat_map(chapter.sections, fn section ->
                case Enum.find_index(section.paragraphs, &(&1.ref_id == ref_id)) do
                  nil ->
                    [section]

                  0 ->
                    [section]

                  idx ->
                    {before, after_paras} = Enum.split(section.paragraphs, idx)
                    first = List.first(after_paras)
                    new_title = if first, do: String.slice(first.text, 0, 60) |> String.trim(), else: "New Section"

                    [
                      %{section | paragraphs: before},
                      Section.new(%{n: section.n + 1, title: new_title, paragraphs: after_paras})
                    ]
                end
              end)

            %{chapter | sections: sections}
          else
            # No sections yet — create two sections from the flat paragraph list
            all_paras = chapter.paragraphs

            case Enum.find_index(all_paras, &(&1.ref_id == ref_id)) do
              nil ->
                chapter

              0 ->
                chapter

              idx ->
                {before, after_paras} = Enum.split(all_paras, idx)
                first = List.first(after_paras)
                title1 = chapter.title || "Section 1"
                title2 = if first, do: String.slice(first.text, 0, 60) |> String.trim(), else: "Section 2"

                sections = [
                  Section.new(%{n: 1, title: title1, paragraphs: before}),
                  Section.new(%{n: 2, title: title2, paragraphs: after_paras})
                ]

                %{chapter | paragraphs: [], sections: sections}
            end
          end
        else
          chapter
        end
      end)

    %{book | chapters: chapters} |> Book.assign_ref_ids()
  end

  defp merge_sections(book, ch_n, section_n) do
    chapters =
      Enum.map(book.chapters, fn chapter ->
        if chapter.n == ch_n and Chapter.has_sections?(chapter) do
          idx = Enum.find_index(chapter.sections, &(&1.n == section_n))

          if idx && idx < length(chapter.sections) - 1 do
            current = Enum.at(chapter.sections, idx)
            next = Enum.at(chapter.sections, idx + 1)
            merged = %{current | paragraphs: current.paragraphs ++ next.paragraphs}

            sections =
              chapter.sections
              |> List.delete_at(idx + 1)
              |> List.replace_at(idx, merged)

            if length(sections) <= 1 do
              # Only one section left — flatten back to chapter paragraphs
              %{chapter | paragraphs: Chapter.all_paragraphs(%{chapter | sections: sections}), sections: []}
            else
              %{chapter | sections: sections}
            end
          else
            chapter
          end
        else
          chapter
        end
      end)

    %{book | chapters: chapters} |> Book.assign_ref_ids()
  end

  defp load_speakers(slug, book) do
    # Try loading persisted speaker list first
    case WorkDir.read_artifact(slug, "speakers.json") do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, list} when is_list(list) -> list
          _ -> build_default_speakers(book)
        end

      {:error, _} ->
        build_default_speakers(book)
    end
  end

  defp build_default_speakers(book) do
    # Collect speakers from all rule profiles
    rules_speakers =
      Path.wildcard("priv/rules/*.json")
      |> Enum.flat_map(fn path ->
        case File.read(path) do
          {:ok, content} ->
            json = Jason.decode!(content)
            get_in(json, ["speaker_patterns", "known_speakers"]) || []

          _ ->
            []
        end
      end)

    # Collect speakers already in the book
    book_speakers =
      book.chapters
      |> Enum.flat_map(&Chapter.all_paragraphs/1)
      |> Enum.map(& &1.speaker)
      |> Enum.reject(&is_nil/1)

    # Combine, deduplicate, ensure Narrator is included
    (["Narrator"] ++ rules_speakers ++ book_speakers)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp save_speakers(slug, speakers) do
    encoded = Jason.encode!(speakers, pretty: true)
    WorkDir.write_artifact(slug, "speakers.json", encoded)
  end

  defp glue_paragraph_pair(book, chapter_n, ref_id) do
    updated_chapters =
      Enum.map(book.chapters, fn chapter ->
        if chapter.n == chapter_n, do: merge_paragraphs(chapter, ref_id), else: chapter
      end)

    %{book | chapters: updated_chapters} |> Book.assign_ref_ids()
  end

  defp speaker_abbreviations(speakers) do
    # Build unique abbreviations: start with 1 char, bump colliding ones to 2, etc.
    speakers
    |> Enum.map(fn name -> {name, String.upcase(String.slice(name, 0, 1))} end)
    |> resolve_collisions(speakers, 2)
    |> Map.new()
  end

  defp resolve_collisions(pairs, speakers, depth) do
    # Group by abbreviation to find collisions
    groups = Enum.group_by(pairs, fn {_name, abbr} -> abbr end)

    Enum.flat_map(groups, fn {_abbr, group} ->
      if length(group) > 1 and depth <= 4 do
        # Collision — bump all in this group to more chars
        bumped =
          Enum.map(group, fn {name, _} ->
            {name, String.upcase(String.slice(name, 0, depth))}
          end)

        resolve_collisions(bumped, speakers, depth + 1)
      else
        group
      end
    end)
  end

  defp detect_repeated_patterns(book) do
    book.chapters
    |> Enum.flat_map(&Chapter.all_paragraphs/1)
    |> Enum.map(fn p -> String.trim(p.text) end)
    |> Enum.reject(&(&1 == ""))
    |> Enum.frequencies()
    |> Enum.filter(fn {_text, count} -> count >= 3 end)
    |> Enum.sort_by(fn {_text, count} -> -count end)
    |> Enum.map(fn {text, count} -> %{text: text, count: count, short: String.slice(text, 0, 80)} end)
  end

  defp compute_changes(saved_book, current_book) do
    saved_ch = Book.chapter_count(saved_book)
    current_ch = Book.chapter_count(current_book)
    saved_p = Book.paragraph_count(saved_book)
    current_p = Book.paragraph_count(current_book)

    saved_texts =
      saved_book.chapters
      |> Enum.flat_map(&Chapter.all_paragraphs/1)
      |> MapSet.new(& &1.text)

    current_texts =
      current_book.chapters
      |> Enum.flat_map(&Chapter.all_paragraphs/1)
      |> MapSet.new(& &1.text)

    added = MapSet.difference(current_texts, saved_texts) |> MapSet.size()
    removed = MapSet.difference(saved_texts, current_texts) |> MapSet.size()

    %{
      ch_saved: saved_ch,
      ch_current: current_ch,
      p_saved: saved_p,
      p_current: current_p,
      added: added,
      removed: removed,
      has_changes: saved_ch != current_ch || saved_p != current_p || added > 0 || removed > 0
    }
  end

  defp build_commit_message(slug, saved_book, book) do
    saved_paras = saved_book.chapters |> Enum.flat_map(&Chapter.all_paragraphs/1)
    current_paras = book.chapters |> Enum.flat_map(&Chapter.all_paragraphs/1)

    saved_map = Map.new(saved_paras, &{&1.ref_id, &1})
    current_map = Map.new(current_paras, &{&1.ref_id, &1})

    all_refs = MapSet.union(MapSet.new(Map.keys(saved_map)), MapSet.new(Map.keys(current_map)))

    text_changes = []
    speaker_changes = []
    vet_changes = []

    {text_changes, speaker_changes, vet_changes} =
      Enum.reduce(all_refs, {text_changes, speaker_changes, vet_changes}, fn ref, {tc, sc, vc} ->
        old = Map.get(saved_map, ref)
        new = Map.get(current_map, ref)

        cond do
          is_nil(old) or is_nil(new) ->
            {tc, sc, vc}

          old.text != new.text ->
            {[ref | tc], sc, vc}

          old.speaker != new.speaker ->
            speaker_desc = "#{ref} (#{old.speaker || "nil"} → #{new.speaker || "nil"})"
            {tc, [speaker_desc | sc], vc}

          old.vetted != new.vetted ->
            {tc, sc, [ref | vc]}

          true ->
            {tc, sc, vc}
        end
      end)

    # Count structural changes
    ch_diff = Book.chapter_count(book) - Book.chapter_count(saved_book)
    p_diff = Book.paragraph_count(book) - Book.paragraph_count(saved_book)

    changes = length(text_changes) + length(speaker_changes) + length(vet_changes) + abs(ch_diff) + abs(p_diff)

    # Determine which chapters were affected
    affected_chapters =
      (text_changes ++ Enum.map(speaker_changes, fn s -> s |> String.split(" ") |> hd() end) ++ vet_changes)
      |> Enum.map(fn ref -> ref |> String.split(":") |> hd() |> String.split("-") |> Enum.drop(1) |> Enum.join("-") end)
      |> Enum.uniq()
      |> Enum.sort()

    ch_summary = if affected_chapters != [], do: " in ch " <> Enum.join(affected_chapters, ", "), else: ""
    summary = "#{changes} changes#{ch_summary}"

    details =
      [
        if(text_changes != [], do: "Text: #{Enum.join(Enum.reverse(text_changes), ", ")}"),
        if(speaker_changes != [], do: "Speaker: #{Enum.join(Enum.reverse(speaker_changes), ", ")}"),
        if vet_changes != [] do
          count = length(vet_changes)
          if count <= 5 do
            "Vetted: #{Enum.join(Enum.reverse(vet_changes), ", ")}"
          else
            "Vetted: #{count} paragraphs"
          end
        end,
        if(ch_diff != 0, do: "Chapters: #{if ch_diff > 0, do: "+"}#{ch_diff}"),
        if(p_diff != 0, do: "Paragraphs: #{if p_diff > 0, do: "+"}#{p_diff}")
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join("\n")

    if details != "" do
      "edit(#{slug}): #{summary}\n\n#{details}"
    else
      "edit(#{slug}): save (no structural changes)"
    end
  end

  defp vetting_stats(book) do
    all_paras = book.chapters |> Enum.flat_map(&Chapter.all_paragraphs/1)
    total = length(all_paras)
    vetted = Enum.count(all_paras, &(&1.vetted == true))
    skipped = Enum.count(all_paras, &(&1.vetted == :skipped))
    pct = if total > 0, do: round(vetted / total * 100), else: 0
    %{total: total, vetted: vetted, skipped: skipped, pct: pct}
  end

  defp focused_paragraph_json(book, ref_id) do
    case find_paragraph(book, ref_id) do
      nil -> nil
      para -> Paragraph.to_json(para) |> Jason.encode!(pretty: true)
    end
  end

  defp focused_chapter_json(chapter) do
    base = %{
      "n" => chapter.n,
      "title" => chapter.title,
      "refId" => chapter.ref_id,
      "paragraphCount" => Chapter.paragraph_count(chapter)
    }

    base =
      if Chapter.has_sections?(chapter) do
        Map.put(base, "sectionCount", length(chapter.sections))
      else
        base
      end

    Jason.encode!(base, pretty: true)
  end

  # -- Render --

  defp render_paragraph(assigns, para) do
    assigns = assign(assigns, :para, para)

    ~H"""
    <div
      data-ref-id={@para.ref_id}
      class={"group flex items-stretch rounded transition-colors #{cond do
        MapSet.member?(@selected_refs, @para.ref_id) -> "bg-primary/5 ring-1 ring-primary/20"
        @focused_ref == @para.ref_id -> "bg-base-200"
        true -> "hover:bg-base-200/50"
      end}"}
    >
      <%!-- Select checkbox column — outside the paragraph, far left --%>
      <div class="w-7 shrink-0 flex items-center justify-center">
        <input
          type="checkbox"
          class={"checkbox checkbox-primary rounded-full w-5 h-5 transition-opacity cursor-pointer #{if MapSet.member?(@selected_refs, @para.ref_id), do: "opacity-100", else: "opacity-0 group-hover:opacity-40 hover:!opacity-100"}"}
          checked={MapSet.member?(@selected_refs, @para.ref_id)}
          phx-click="toggle_select"
          phx-value-ref-id={@para.ref_id}
        />
      </div>

      <%!-- Vet gutter — full height click target --%>
      <button
        phx-click="toggle_vet"
        phx-value-ref-id={@para.ref_id}
        class={"w-7 shrink-0 flex items-center justify-center cursor-pointer rounded-l transition-colors #{case @para.vetted do
          true -> "bg-success/20 text-success hover:bg-success/30"
          :skipped -> "bg-warning/10 text-warning/60 hover:bg-warning/20"
          _ -> "text-base-content/15 hover:bg-success/10 hover:text-success/50"
        end}"}
        title={case @para.vetted do
          true -> "Unvet"
          :skipped -> "Re-vet"
          _ -> "Mark as vetted (+ all above)"
        end}
      >
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16" fill="currentColor" class="w-3.5 h-3.5"><path fill-rule="evenodd" d={case @para.vetted do
          true -> "M12.416 3.376a.75.75 0 0 1 .208 1.04l-5 7.5a.75.75 0 0 1-1.154.114l-3-3a.75.75 0 0 1 1.06-1.06l2.353 2.353 4.493-6.74a.75.75 0 0 1 1.04-.207Z"
          :skipped -> "M3.75 7.25a.75.75 0 0 0 0 1.5h8.5a.75.75 0 0 0 0-1.5h-8.5Z"
          _ -> "M8 1a.75.75 0 0 1 .75.75v6.5a.75.75 0 0 1-1.5 0v-6.5A.75.75 0 0 1 8 1ZM8 11a1 1 0 1 0 0 2 1 1 0 0 0 0-2Z"
        end} clip-rule="evenodd"/></svg>
      </button>

      <%!-- Content area --%>
      <div class="flex-1 min-w-0 py-1.5 px-2">
        <%!-- Line 1: metadata --%>
        <div class="flex items-center gap-2 mb-0.5">
          <span class="font-mono text-xs text-base-content/30">{@para.ref_id}</span>
          <%!-- Speaker slider --%>
          <div class="inline-flex items-center bg-base-300 rounded-full overflow-hidden">
            <button
              phx-click="set_speaker"
              phx-value-ref-id={@para.ref_id}
              phx-value-speaker=""
              class={"px-1.5 py-0.5 text-xs leading-none transition-colors cursor-pointer #{if is_nil(@para.speaker), do: "bg-base-content/10 font-semibold text-base-content", else: "text-base-content/30 hover:text-base-content/60"}"}
              title="Clear speaker"
            >&times;</button>
            <%= for speaker <- @speakers do %>
              <button
                phx-click="set_speaker"
                phx-value-ref-id={@para.ref_id}
                phx-value-speaker={speaker}
                class={"px-1.5 py-0.5 text-xs leading-none transition-colors cursor-pointer whitespace-nowrap #{if @para.speaker == speaker, do: "bg-primary text-primary-content font-semibold rounded-full", else: "text-base-content/40 hover:text-base-content/70"}"}
                title={speaker}
              >{if @para.speaker == speaker, do: speaker, else: Map.get(@speaker_abbrevs, speaker, String.first(speaker))}</button>
            <% end %>
          </div>
        </div>
        <%!-- Line 2: text content — becomes contenteditable when editing --%>
        <p
          id={"para-text-#{@para.ref_id}"}
          phx-hook="ContentEditable"
          data-ref-id={@para.ref_id}
          data-editing={to_string(@editing_paragraph == @para.ref_id)}
          phx-click="edit_paragraph"
          phx-value-ref-id={@para.ref_id}
          class={"text-sm transition-all outline-none #{if @editing_paragraph == @para.ref_id, do: "bg-base-200 ring-1 ring-primary/30 rounded px-2 py-1 -mx-2", else: "cursor-pointer hover:text-primary/80"}"}
        >{@para.text}</p>
      </div>

      <%!-- Delete gutter — full height click target, mirrors vet gutter --%>
      <button
        phx-click="delete_paragraph"
        phx-value-ref-id={@para.ref_id}
        class="w-7 shrink-0 flex items-center justify-center cursor-pointer rounded-r transition-colors text-base-content/0 group-hover:text-error/40 hover:!bg-error/15 hover:!text-error"
        title="Delete paragraph"
        data-confirm="Delete this paragraph?"
      >
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16" fill="currentColor" class="w-3.5 h-3.5"><path fill-rule="evenodd" d="M5 3.25V4H2.75a.75.75 0 0 0 0 1.5h.3l.815 8.15A1.5 1.5 0 0 0 5.357 15h5.285a1.5 1.5 0 0 0 1.493-1.35l.815-8.15h.3a.75.75 0 0 0 0-1.5H11v-.75A2.25 2.25 0 0 0 8.75 1h-1.5A2.25 2.25 0 0 0 5 3.25Zm2.25-.75a.75.75 0 0 0-.75.75V4h3v-.75a.75.75 0 0 0-.75-.75h-1.5ZM6.05 6a.75.75 0 0 1 .787.713l.275 5.5a.75.75 0 0 1-1.498.075l-.275-5.5A.75.75 0 0 1 6.05 6Zm3.9 0a.75.75 0 0 1 .712.787l-.275 5.5a.75.75 0 0 1-1.498-.075l.275-5.5A.75.75 0 0 1 9.95 6Z" clip-rule="evenodd"/></svg>
      </button>
    </div>
    """
  end

  @impl true
  def render(assigns) do
    chapter = get_chapter(assigns.book, assigns.selected_chapter)
    changes = compute_changes(assigns.saved_book, assigns.book)

    abbrevs = speaker_abbreviations(assigns.speakers)

    vet_stats = vetting_stats(assigns.book)

    assigns =
      assigns
      |> assign(:chapter, chapter)
      |> assign(:selected_count, MapSet.size(assigns.selected_refs))
      |> assign(:changes, changes)
      |> assign(:para_json, focused_paragraph_json(assigns.book, assigns.focused_ref))
      |> assign(:ch_json, if(chapter, do: focused_chapter_json(chapter), else: nil))
      |> assign(:speaker_abbrevs, abbrevs)
      |> assign(:vet_stats, vet_stats)

    ~H"""
    <CuratorWeb.Layouts.app flash={@flash} container_class="mx-auto max-w-[96rem]">
      <div class="space-y-3">
        <%!-- Header --%>
        <div class="flex items-center justify-between">
          <div>
            <h1 class="text-xl font-bold">{@slug}</h1>
            <p class="text-base-content/50 text-xs">
              {Book.chapter_count(@book)} chapters · {Book.paragraph_count(@book)} paragraphs
            </p>
          </div>
          <div class="flex gap-2 items-center">
            <%= if @dirty do %>
              <span class="badge badge-warning badge-xs">unsaved</span>
            <% end %>
            <button phx-click="save_to_disk" class={"btn btn-sm #{if @dirty, do: "btn-warning", else: "btn-ghost"}"}>
              Save
            </button>
            <button phx-click="sync" class={"btn btn-sm #{if @synced or @dirty, do: "btn-ghost btn-disabled", else: "btn-info"}"} disabled={@dirty or @synced} title={cond do
              @dirty -> "Save first before syncing"
              @synced -> "All commits pushed"
              true -> "Push commits to origin"
            end}>
              <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16" fill="currentColor" class="w-4 h-4"><path d="M5.22 14.78a.75.75 0 0 0 1.06-1.06L4.56 12h8.69a.75.75 0 0 0 0-1.5H4.56l1.72-1.72a.75.75 0 0 0-1.06-1.06l-3 3a.75.75 0 0 0 0 1.06l3 3ZM10.78 1.22a.75.75 0 0 0-1.06 1.06L11.44 4H2.75a.75.75 0 0 0 0 1.5h8.69l-1.72 1.72a.75.75 0 1 0 1.06 1.06l3-3a.75.75 0 0 0 0-1.06l-3-3Z"/></svg>
              Sync
            </button>
            <.link navigate={~p"/"} class="btn btn-ghost btn-sm">Back</.link>
          </div>
        </div>

        <%!-- Repeated patterns --%>
        <%= if @repeated_patterns != [] do %>
          <div class="bg-base-200 rounded-lg p-3">
            <button phx-click="toggle_patterns" class="flex items-center gap-2 w-full text-left text-sm">
              <span class="font-semibold">{length(@repeated_patterns)} repeated patterns</span>
              <span class="text-base-content/40 text-xs">(page headers/footers)</span>
              <span class="ml-auto text-xs">{if @show_patterns, do: "Hide", else: "Show"}</span>
            </button>
            <%= if @show_patterns do %>
              <div class="mt-2 space-y-1">
                <%= for pattern <- @repeated_patterns do %>
                  <div class="flex items-center gap-2 bg-base-100 rounded p-2 text-sm">
                    <span class="flex-1 font-mono text-xs truncate">{pattern.short}</span>
                    <span class="badge badge-ghost badge-xs">{pattern.count}x</span>
                    <button phx-click="select_pattern" phx-value-pattern={pattern.text} class="btn btn-ghost btn-xs">Select</button>
                    <button phx-click="remove_pattern" phx-value-pattern={pattern.text} class="btn btn-error btn-xs" data-confirm={"Remove all #{pattern.count} occurrences?"}>Remove</button>
                  </div>
                <% end %>
              </div>
            <% end %>
          </div>
        <% end %>

        <%!-- Bulk actions --%>
        <%= if @selected_count > 0 do %>
          <div class="sticky top-0 z-10 bg-base-300 rounded-lg p-2 flex items-center gap-3 shadow-lg text-sm">
            <span class="font-semibold">{@selected_count} selected</span>
            <button phx-click="select_none" class="btn btn-ghost btn-xs">Clear</button>
            <div class="divider divider-horizontal mx-0"></div>
            <button phx-click="delete_selected" class="btn btn-error btn-xs" data-confirm={"Delete #{@selected_count} paragraphs?"}>Delete</button>
            <form phx-submit="set_speaker_selected" class="flex items-center gap-1">
              <input type="text" name="speaker" placeholder="Speaker..." class="input input-bordered input-xs w-32" />
              <button type="submit" class="btn btn-xs btn-ghost">Set</button>
            </form>
          </div>
        <% end %>

        <%!-- Three-column layout --%>
        <div class="flex gap-4">
          <%!-- Left: Chapter sidebar --%>
          <div class="w-48 shrink-0 hidden lg:block">
            <div class="sticky top-2">
              <h3 class="font-semibold text-xs text-base-content/50 uppercase tracking-wide mb-2">Chapters</h3>
              <ul class="space-y-0.5">
                <%= for ch <- @book.chapters do %>
                  <li>
                    <%= if @editing_chapter == ch.n do %>
                      <form phx-submit="rename_chapter" class="px-2 py-1">
                        <input type="hidden" name="chapter" value={ch.n} />
                        <input type="text" name="title" value={ch.title} class="input input-bordered input-xs w-full mb-1" autofocus />
                        <div class="flex gap-1">
                          <button type="submit" class="btn btn-primary btn-xs flex-1">Save</button>
                          <button type="button" phx-click="cancel_edit_chapter" class="btn btn-ghost btn-xs">Cancel</button>
                        </div>
                      </form>
                    <% else %>
                      <div class="group flex items-center gap-1">
                        <button
                          phx-click="select_chapter"
                          phx-value-chapter={ch.n}
                          class={"flex items-center gap-1.5 flex-1 text-left px-2 py-1 rounded text-sm hover:bg-base-200 transition-colors #{if @selected_chapter == ch.n, do: "bg-base-200 font-medium", else: ""}"}
                        >
                          <span class="text-base-content/30 font-mono text-xs w-5 text-right shrink-0">{ch.n}</span>
                          <span class="truncate flex-1">{ch.title}</span>
                          <span class="text-base-content/30 text-xs">{Chapter.paragraph_count(ch)}</span>
                        </button>
                        <button
                          phx-click="edit_chapter_title"
                          phx-value-chapter={ch.n}
                          class="hidden group-hover:block btn btn-ghost btn-xs px-1"
                          title="Rename chapter"
                        >
                          <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16" fill="currentColor" class="w-3 h-3"><path d="M13.488 2.513a1.75 1.75 0 0 0-2.475 0L6.05 7.475a.75.75 0 0 0-.186.312l-.9 3.15a.75.75 0 0 0 .926.926l3.15-.9a.75.75 0 0 0 .312-.186l4.963-4.963a1.75 1.75 0 0 0 0-2.475l-.827-.826ZM11.72 3.22a.25.25 0 0 1 .354 0l.826.826a.25.25 0 0 1 0 .354L8.55 8.75l-1.186.339.338-1.186L11.72 3.22Z"/></svg>
                        </button>
                      </div>
                    <% end %>
                  </li>
                <% end %>
              </ul>
            </div>
          </div>

          <%!-- Center: Paragraph editor --%>
          <div class="flex-1 min-w-0">
            <%= if @chapter do %>
              <%!-- Chapter header --%>
              <div class="flex items-center gap-2 mb-3 pb-2 border-b-2 border-primary/30" id={"chapter-#{@chapter.n}"}>
                <span class="text-primary font-mono text-sm font-bold">Ch. {@chapter.n}</span>
                <%= if @editing_chapter == @chapter.n do %>
                  <form phx-submit="rename_chapter" class="flex items-center gap-1 flex-1">
                    <input type="hidden" name="chapter" value={@chapter.n} />
                    <input type="text" name="title" value={@chapter.title} class="input input-bordered input-sm flex-1" autofocus />
                    <button type="submit" class="btn btn-primary btn-sm">Save</button>
                    <button type="button" phx-click="cancel_edit_chapter" class="btn btn-ghost btn-sm">Cancel</button>
                  </form>
                <% else %>
                  <h2
                    class="text-lg font-semibold flex-1 cursor-pointer hover:text-primary transition-colors"
                    phx-click="edit_chapter_title"
                    phx-value-chapter={@chapter.n}
                    title="Click to rename"
                  >{@chapter.title}</h2>
                <% end %>
                <span class="text-base-content/30 text-xs">
                  {Chapter.paragraph_count(@chapter)}p
                  <%= if Chapter.has_sections?(@chapter) do %>
                    · {length(@chapter.sections)}s
                  <% end %>
                </span>
                <%= if @chapter.n > 1 do %>
                  <button
                    phx-click="remove_chapter_break"
                    phx-value-chapter={@chapter.n}
                    class="btn btn-ghost btn-xs text-base-content/40 hover:text-warning"
                    title="Remove this chapter break (merge with previous)"
                  >Merge up</button>
                <% end %>
              </div>

              <%!-- Paragraph list with scroll spy --%>
              <div id="paragraph-list" phx-hook="ScrollSpy" class="space-y-0">
                <div class="flex items-center justify-end mb-1 gap-2">
                  <button phx-click="select_all_chapter" class="btn btn-ghost btn-xs text-base-content/40">Select all</button>
                  <%= if Chapter.has_sections?(@chapter) do %>
                    <button
                      phx-click="remove_all_section_breaks"
                      phx-value-chapter={@chapter.n}
                      class="btn btn-ghost btn-xs text-base-content/40"
                      data-confirm="Remove all section breaks in this chapter?"
                    >Flatten sections</button>
                  <% end %>
                </div>

                <%!-- Render paragraphs: section-aware --%>
                <%= if Chapter.has_sections?(@chapter) do %>
                  <%= for {section, s_idx} <- Enum.with_index(@chapter.sections) do %>
                    <%!-- Section header --%>
                    <div class={"flex items-center gap-2 py-2 px-2 border-b border-secondary/30 #{if s_idx > 0, do: "mt-3 border-t border-t-secondary/30 pt-3", else: ""}"}>
                      <span class="text-secondary font-mono text-xs font-bold">§{section.n}</span>
                      <%= if @editing_section == {@chapter.n, section.n} do %>
                        <form phx-submit="rename_section" class="flex items-center gap-1 flex-1">
                          <input type="hidden" name="chapter" value={@chapter.n} />
                          <input type="hidden" name="section" value={section.n} />
                          <input type="text" name="title" value={section.title} class="input input-bordered input-xs flex-1" autofocus />
                          <button type="submit" class="btn btn-primary btn-xs">Save</button>
                          <button type="button" phx-click="cancel_edit_section" class="btn btn-ghost btn-xs">Cancel</button>
                        </form>
                      <% else %>
                        <span
                          class="text-sm font-medium flex-1 cursor-pointer hover:text-secondary transition-colors"
                          phx-click="edit_section_title"
                          phx-value-chapter={@chapter.n}
                          phx-value-section={section.n}
                          title="Click to rename"
                        >{section.title}</span>
                      <% end %>
                      <span class="text-base-content/30 text-xs">{length(section.paragraphs)}p</span>
                      <%= if section.n > 1 do %>
                        <button
                          phx-click="remove_section_break"
                          phx-value-chapter={@chapter.n}
                          phx-value-section={section.n}
                          class="btn btn-ghost btn-xs text-base-content/40 hover:text-warning"
                          title="Remove this section break (merge with previous)"
                        >Merge up</button>
                      <% end %>
                    </div>

                    <%= for {para, idx} <- Enum.with_index(section.paragraphs) do %>
                      <%!-- Between-paragraph zone --%>
                      <%= if idx > 0 do %>
                        <div class="group relative h-3 cursor-pointer hover:h-10 transition-all duration-150 flex items-center justify-center">
                          <div class="hidden group-hover:flex items-center gap-3 absolute inset-x-0 top-0 bottom-0 rounded justify-center">
                            <button
                              phx-click="glue_paragraphs"
                              phx-value-ref-id={para.ref_id}
                              class="btn btn-ghost btn-xs text-success border-dashed border-success/30 bg-success/10 hover:bg-success/20"
                              title="Merge with paragraph above"
                            >Glue</button>
                            <button
                              phx-click="insert_section_break"
                              phx-value-ref-id={para.ref_id}
                              class="btn btn-ghost btn-xs text-secondary border-dashed border-secondary/30 bg-secondary/10 hover:bg-secondary/20"
                            >+ Section break</button>
                            <button
                              phx-click="insert_chapter_break"
                              phx-value-ref-id={para.ref_id}
                              class="btn btn-ghost btn-xs text-info border-dashed border-info/30 bg-info/10 hover:bg-info/20"
                            >+ Chapter break</button>
                          </div>
                        </div>
                      <% end %>

                      {render_paragraph(assigns, para)}
                    <% end %>
                  <% end %>
                <% else %>

                <%= for {para, idx} <- Enum.with_index(Chapter.all_paragraphs(@chapter)) do %>
                  <%!-- Between-paragraph zone: glue + section break + chapter break --%>
                  <%= if idx > 0 do %>
                    <div class="group relative h-3 cursor-pointer hover:h-10 transition-all duration-150 flex items-center justify-center">
                      <div class="hidden group-hover:flex items-center gap-3 absolute inset-x-0 top-0 bottom-0 rounded justify-center">
                        <button
                          phx-click="glue_paragraphs"
                          phx-value-ref-id={para.ref_id}
                          class="btn btn-ghost btn-xs text-success border-dashed border-success/30 bg-success/10 hover:bg-success/20"
                          title="Merge with paragraph above"
                        >Glue</button>
                        <button
                          phx-click="insert_section_break"
                          phx-value-ref-id={para.ref_id}
                          class="btn btn-ghost btn-xs text-secondary border-dashed border-secondary/30 bg-secondary/10 hover:bg-secondary/20"
                        >+ Section break</button>
                        <button
                          phx-click="insert_chapter_break"
                          phx-value-ref-id={para.ref_id}
                          class="btn btn-ghost btn-xs text-info border-dashed border-info/30 bg-info/10 hover:bg-info/20"
                        >+ Chapter break</button>
                      </div>
                    </div>
                  <% end %>

                  {render_paragraph(assigns, para)}
                <% end %>
                <% end %>
              </div>

              <%!-- Chapter nav footer --%>
              <div class="flex items-center justify-between mt-4 pt-3 border-t border-base-200">
                <%= if @chapter.n > 1 do %>
                  <button phx-click="select_chapter" phx-value-chapter={@chapter.n - 1} class="btn btn-ghost btn-sm">&larr; Prev</button>
                <% else %>
                  <div></div>
                <% end %>
                <%= if @chapter.n < Book.chapter_count(@book) do %>
                  <button phx-click="select_chapter" phx-value-chapter={@chapter.n + 1} class="btn btn-ghost btn-sm">Next &rarr;</button>
                <% end %>
              </div>
            <% else %>
              <p class="text-base-content/40">Select a chapter to edit.</p>
            <% end %>
          </div>

          <%!-- Right: JSON preview + diff --%>
          <div class="w-80 shrink-0 hidden xl:block">
            <div class="sticky top-2 space-y-3">
              <%!-- Book metadata --%>
              <div>
                <button phx-click="toggle_metadata" class="flex items-center gap-1 w-full text-left">
                  <h4 class="font-semibold text-xs text-base-content/50 uppercase tracking-wide">Metadata</h4>
                  <span class="text-base-content/30 text-xs ml-auto">{if @editing_metadata, do: "Close", else: "Edit"}</span>
                </button>
                <%= if @editing_metadata do %>
                  <form phx-submit="save_metadata" class="mt-2 space-y-2">
                    <div class="form-control">
                      <label class="label py-0"><span class="label-text text-xs">Title</span></label>
                      <input type="text" name="title" value={Map.get(@book.titles, @book.primary_lang || "en", "")} class="input input-bordered input-xs w-full" />
                    </div>
                    <div class="grid grid-cols-2 gap-2">
                      <div class="form-control">
                        <label class="label py-0"><span class="label-text text-xs">Slug</span></label>
                        <input type="text" name="slug" value={@book.slug} class="input input-bordered input-xs w-full font-mono" />
                      </div>
                      <div class="form-control">
                        <label class="label py-0"><span class="label-text text-xs">Code</span></label>
                        <input type="text" name="code" value={@book.code} class="input input-bordered input-xs w-full font-mono" />
                      </div>
                    </div>
                    <div class="grid grid-cols-2 gap-2">
                      <div class="form-control">
                        <label class="label py-0"><span class="label-text text-xs">Language</span></label>
                        <input type="text" name="primary_lang" value={@book.primary_lang} class="input input-bordered input-xs w-full font-mono" placeholder="en" />
                      </div>
                      <div class="form-control">
                        <label class="label py-0"><span class="label-text text-xs">Year</span></label>
                        <input type="text" name="publication_year" value={@book.publication_year || ""} class="input input-bordered input-xs w-full font-mono" placeholder="1974" />
                      </div>
                    </div>
                    <div class="flex gap-1 justify-end">
                      <button type="button" phx-click="toggle_metadata" class="btn btn-ghost btn-xs">Cancel</button>
                      <button type="submit" class="btn btn-primary btn-xs">Apply</button>
                    </div>
                  </form>
                <% else %>
                  <div class="mt-1 text-xs space-y-0.5">
                    <div class="flex justify-between">
                      <span class="text-base-content/40">Title</span>
                      <span class="font-medium truncate ml-2">{Map.get(@book.titles, @book.primary_lang || "en", "--")}</span>
                    </div>
                    <div class="flex justify-between">
                      <span class="text-base-content/40">Code</span>
                      <span class="font-mono">{@book.code || "--"}</span>
                    </div>
                    <div class="flex justify-between">
                      <span class="text-base-content/40">Lang</span>
                      <span class="font-mono">{@book.primary_lang || "--"}</span>
                    </div>
                    <%= if @book.publication_year do %>
                      <div class="flex justify-between">
                        <span class="text-base-content/40">Year</span>
                        <span>{@book.publication_year}</span>
                      </div>
                    <% end %>
                  </div>
                <% end %>
              </div>

              <%!-- Change summary --%>
              <%= if @changes.has_changes do %>
                <div class="bg-warning/10 border border-warning/20 rounded-lg p-3">
                  <h4 class="font-semibold text-xs text-warning uppercase tracking-wide mb-2">Unsaved changes</h4>
                  <div class="space-y-1 text-xs">
                    <%= if @changes.ch_current != @changes.ch_saved do %>
                      <div class="flex justify-between">
                        <span>Chapters</span>
                        <span>
                          <span class="text-base-content/40">{@changes.ch_saved}</span>
                          <span>&rarr;</span>
                          <span class="font-semibold">{@changes.ch_current}</span>
                          <span class={if @changes.ch_current > @changes.ch_saved, do: "text-success", else: "text-error"}>
                            ({if @changes.ch_current > @changes.ch_saved, do: "+", else: ""}{@changes.ch_current - @changes.ch_saved})
                          </span>
                        </span>
                      </div>
                    <% end %>
                    <%= if @changes.p_current != @changes.p_saved do %>
                      <div class="flex justify-between">
                        <span>Paragraphs</span>
                        <span>
                          <span class="text-base-content/40">{@changes.p_saved}</span>
                          <span>&rarr;</span>
                          <span class="font-semibold">{@changes.p_current}</span>
                          <span class={if @changes.p_current > @changes.p_saved, do: "text-success", else: "text-error"}>
                            ({if @changes.p_current > @changes.p_saved, do: "+", else: ""}{@changes.p_current - @changes.p_saved})
                          </span>
                        </span>
                      </div>
                    <% end %>
                    <%= if @changes.added > 0 do %>
                      <div class="flex justify-between">
                        <span>New content</span>
                        <span class="text-success">+{@changes.added} blocks</span>
                      </div>
                    <% end %>
                    <%= if @changes.removed > 0 do %>
                      <div class="flex justify-between">
                        <span>Removed</span>
                        <span class="text-error">-{@changes.removed} blocks</span>
                      </div>
                    <% end %>
                  </div>
                </div>
              <% else %>
                <div class="bg-success/10 border border-success/20 rounded-lg p-3">
                  <p class="text-xs text-success">All changes saved</p>
                </div>
              <% end %>

              <%!-- Structure: chapters + sections with delete --%>
              <div>
                <h4 class="font-semibold text-xs text-base-content/50 uppercase tracking-wide mb-1">Structure</h4>
                <ul class="space-y-0.5 text-xs max-h-48 overflow-y-auto">
                  <%= for ch <- @book.chapters do %>
                    <li>
                      <div class={"group/ch flex items-center gap-1 px-1.5 py-1 rounded #{if ch.n == @selected_chapter, do: "bg-base-200", else: "hover:bg-base-200/50"}"}>
                        <button phx-click="select_chapter" phx-value-chapter={ch.n} class="flex items-center gap-1 flex-1 text-left min-w-0">
                          <span class="font-mono text-base-content/30 w-4 text-right shrink-0">{ch.n}</span>
                          <span class="truncate">{ch.title}</span>
                        </button>
                        <span class="text-base-content/20 shrink-0">{Chapter.paragraph_count(ch)}</span>
                        <%= if length(@book.chapters) > 1 do %>
                          <button
                            phx-click="delete_chapter"
                            phx-value-chapter={ch.n}
                            class="hidden group-hover/ch:block shrink-0 text-base-content/20 hover:text-error transition-colors"
                            data-confirm={"Delete chapter #{ch.n} \"#{ch.title}\" and all its paragraphs?"}
                            title="Delete chapter"
                          >
                            <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16" fill="currentColor" class="w-3.5 h-3.5"><path fill-rule="evenodd" d="M5 3.25V4H2.75a.75.75 0 0 0 0 1.5h.3l.815 8.15A1.5 1.5 0 0 0 5.357 15h5.285a1.5 1.5 0 0 0 1.493-1.35l.815-8.15h.3a.75.75 0 0 0 0-1.5H11v-.75A2.25 2.25 0 0 0 8.75 1h-1.5A2.25 2.25 0 0 0 5 3.25Zm2.25-.75a.75.75 0 0 0-.75.75V4h3v-.75a.75.75 0 0 0-.75-.75h-1.5ZM6.05 6a.75.75 0 0 1 .787.713l.275 5.5a.75.75 0 0 1-1.498.075l-.275-5.5A.75.75 0 0 1 6.05 6Zm3.9 0a.75.75 0 0 1 .712.787l-.275 5.5a.75.75 0 0 1-1.498-.075l.275-5.5A.75.75 0 0 1 9.95 6Z" clip-rule="evenodd"/></svg>
                          </button>
                        <% end %>
                      </div>
                      <%= if ch.n == @selected_chapter and Chapter.has_sections?(ch) do %>
                        <ul class="ml-5 space-y-0.5 mt-0.5">
                          <%= for section <- ch.sections do %>
                            <li class="group/sec flex items-center gap-1 px-1.5 py-0.5 rounded hover:bg-base-200/50">
                              <span class="text-secondary font-mono shrink-0">§{section.n}</span>
                              <span class="truncate flex-1 text-base-content/60">{section.title}</span>
                              <span class="text-base-content/20 shrink-0">{length(section.paragraphs)}</span>
                              <button
                                phx-click="delete_section"
                                phx-value-chapter={ch.n}
                                phx-value-section={section.n}
                                class="hidden group-hover/sec:block shrink-0 text-base-content/20 hover:text-error transition-colors"
                                data-confirm={"Delete section §#{section.n} \"#{section.title}\" and all its paragraphs?"}
                                title="Delete section"
                              >
                                <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16" fill="currentColor" class="w-3.5 h-3.5"><path fill-rule="evenodd" d="M5 3.25V4H2.75a.75.75 0 0 0 0 1.5h.3l.815 8.15A1.5 1.5 0 0 0 5.357 15h5.285a1.5 1.5 0 0 0 1.493-1.35l.815-8.15h.3a.75.75 0 0 0 0-1.5H11v-.75A2.25 2.25 0 0 0 8.75 1h-1.5A2.25 2.25 0 0 0 5 3.25Zm2.25-.75a.75.75 0 0 0-.75.75V4h3v-.75a.75.75 0 0 0-.75-.75h-1.5ZM6.05 6a.75.75 0 0 1 .787.713l.275 5.5a.75.75 0 0 1-1.498.075l-.275-5.5A.75.75 0 0 1 6.05 6Zm3.9 0a.75.75 0 0 1 .712.787l-.275 5.5a.75.75 0 0 1-1.498-.075l.275-5.5A.75.75 0 0 1 9.95 6Z" clip-rule="evenodd"/></svg>
                              </button>
                            </li>
                          <% end %>
                        </ul>
                      <% end %>
                    </li>
                  <% end %>
                </ul>
              </div>

              <%!-- Speakers --%>
              <div>
                <h4 class="font-semibold text-xs text-base-content/50 uppercase tracking-wide mb-1">Speakers</h4>
                <div class="flex flex-wrap gap-1 mb-2">
                  <%= for speaker <- @speakers do %>
                    <div class="badge badge-sm gap-1">
                      <span>{speaker}</span>
                      <button
                        phx-click="remove_speaker_option"
                        phx-value-speaker={speaker}
                        class="text-base-content/40 hover:text-error"
                        title={"Remove #{speaker}"}
                      >&times;</button>
                    </div>
                  <% end %>
                </div>
                <form phx-submit="add_speaker_option" class="flex gap-1">
                  <input type="text" name="speaker" placeholder="Add speaker..." class="input input-bordered input-xs flex-1" />
                  <button type="submit" class="btn btn-ghost btn-xs">Add</button>
                </form>
              </div>

              <%!-- Vetting progress --%>
              <div>
                <h4 class="font-semibold text-xs text-base-content/50 uppercase tracking-wide mb-1">Vetting</h4>
                <div class="flex items-center gap-2 text-xs">
                  <progress class="progress progress-success flex-1" value={@vet_stats.vetted} max={@vet_stats.total}></progress>
                  <span class="text-base-content/60 whitespace-nowrap">{@vet_stats.vetted}/{@vet_stats.total} ({@vet_stats.pct}%)</span>
                </div>
                <%= if @vet_stats.skipped > 0 do %>
                  <p class="text-xs text-warning/70 mt-0.5">{@vet_stats.skipped} skipped</p>
                <% end %>
              </div>

              <%!-- Chapter JSON --%>
              <%= if @ch_json do %>
                <div>
                  <h4 class="font-semibold text-xs text-base-content/50 uppercase tracking-wide mb-1">Chapter</h4>
                  <pre class="bg-base-200 rounded-lg p-3 text-xs font-mono overflow-x-auto select-all whitespace-pre-wrap break-words">{@ch_json}</pre>
                </div>
              <% end %>

              <%!-- Focused paragraph JSON --%>
              <%= if @para_json do %>
                <div>
                  <h4 class="font-semibold text-xs text-base-content/50 uppercase tracking-wide mb-1">Paragraph <span class="text-primary">{@focused_ref}</span></h4>
                  <pre class="bg-base-200 rounded-lg p-3 text-xs font-mono overflow-x-auto select-all whitespace-pre-wrap break-words">{@para_json}</pre>
                </div>
              <% else %>
                <div>
                  <h4 class="font-semibold text-xs text-base-content/50 uppercase tracking-wide mb-1">Paragraph</h4>
                  <p class="text-xs text-base-content/30 italic">Scroll to focus a paragraph</p>
                </div>
              <% end %>
            </div>
          </div>
        </div>
      </div>

    </CuratorWeb.Layouts.app>
    """
  end
end
