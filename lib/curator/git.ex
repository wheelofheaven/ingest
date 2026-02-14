defmodule Curator.Git do
  @moduledoc """
  Git operations targeting the curator-work directory.

  Uses System.cmd to run git commands in the work directory root.
  """

  alias Curator.Stages.WorkDir

  require Logger

  @doc """
  Stages and commits changes for a slug's directory.

  Returns `{:ok, sha}` on success or `{:error, reason}` on failure.
  """
  def commit(slug, message) do
    root = WorkDir.root()

    case System.cmd("git", ["add", slug <> "/"], cd: root, stderr_to_stdout: true) do
      {_, 0} ->
        case System.cmd("git", ["diff", "--cached", "--quiet"], cd: root, stderr_to_stdout: true) do
          {_, 0} ->
            # Nothing staged — no changes to commit
            {:ok, :no_changes}

          {_, 1} ->
            case System.cmd("git", ["commit", "-m", message], cd: root, stderr_to_stdout: true) do
              {output, 0} ->
                sha = parse_commit_sha(output)
                Logger.info("[Git] Committed #{slug}: #{sha}")
                {:ok, sha}

              {output, _} ->
                Logger.error("[Git] Commit failed: #{output}")
                {:error, String.trim(output)}
            end
        end

      {output, _} ->
        Logger.error("[Git] Add failed: #{output}")
        {:error, String.trim(output)}
    end
  end

  @doc """
  Pushes commits to origin.

  Returns `:ok` or `{:error, reason}`.
  """
  def push do
    root = WorkDir.root()

    case System.cmd("git", ["push"], cd: root, stderr_to_stdout: true) do
      {_, 0} ->
        Logger.info("[Git] Pushed to origin")
        :ok

      {output, _} ->
        Logger.error("[Git] Push failed: #{output}")
        {:error, String.trim(output)}
    end
  end

  @doc """
  Returns git status (porcelain format) for the work directory.

  Returns `{:ok, output}` or `{:error, reason}`.
  """
  def status do
    root = WorkDir.root()

    case System.cmd("git", ["status", "--porcelain"], cd: root, stderr_to_stdout: true) do
      {output, 0} -> {:ok, String.trim(output)}
      {output, _} -> {:error, String.trim(output)}
    end
  end

  @doc """
  Returns true if there are unpushed commits on the current branch.
  """
  def has_unpushed? do
    root = WorkDir.root()

    case System.cmd("git", ["log", "--oneline", "@{upstream}..HEAD"], cd: root, stderr_to_stdout: true) do
      {"", 0} -> false
      {_, 0} -> true
      _ -> false
    end
  end

  defp parse_commit_sha(output) do
    case Regex.run(~r/\[[\w\/]+ ([a-f0-9]+)\]/, output) do
      [_, sha] -> sha
      _ -> "unknown"
    end
  end
end
