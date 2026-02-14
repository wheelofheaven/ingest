defmodule Curator.Store.Job do
  @moduledoc """
  ETS-based job state tracking for pipeline processing.

  Tracks the state of PDF curation jobs through the pipeline stages.
  """

  use GenServer

  @table :curator_jobs

  @type status :: :pending | :ocr | :parsing | :refining | :exporting | :complete | :error

  @type t :: %{
          id: String.t(),
          status: status(),
          pdf_path: String.t(),
          metadata: map(),
          ocr_text: String.t() | nil,
          book: struct() | nil,
          errors: [String.t()],
          started_at: DateTime.t(),
          updated_at: DateTime.t(),
          completed_at: DateTime.t() | nil,
          output_path: String.t() | nil
        }

  # Client API

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @doc """
  Creates a new job and returns its ID.
  """
  def create(pdf_path, metadata) do
    job = %{
      id: generate_id(),
      status: :pending,
      pdf_path: pdf_path,
      metadata: metadata,
      ocr_text: nil,
      book: nil,
      errors: [],
      started_at: DateTime.utc_now(),
      updated_at: DateTime.utc_now(),
      completed_at: nil,
      output_path: nil
    }

    :ets.insert(@table, {job.id, job})
    broadcast(job)
    {:ok, job.id}
  end

  @doc """
  Gets a job by ID.
  """
  def get(id) do
    case :ets.lookup(@table, id) do
      [{^id, job}] -> {:ok, job}
      [] -> {:error, :not_found}
    end
  end

  @doc """
  Updates a job's fields.
  """
  def update(id, updates) do
    case get(id) do
      {:ok, job} ->
        updated = Map.merge(job, Map.put(updates, :updated_at, DateTime.utc_now()))
        :ets.insert(@table, {id, updated})
        broadcast(updated)
        {:ok, updated}

      error ->
        error
    end
  end

  @doc """
  Lists all jobs, optionally filtered by status.
  """
  def list(status \\ nil) do
    jobs =
      :ets.tab2list(@table)
      |> Enum.map(fn {_id, job} -> job end)
      |> Enum.sort_by(& &1.started_at, {:desc, DateTime})

    if status do
      Enum.filter(jobs, &(&1.status == status))
    else
      jobs
    end
  end

  @doc """
  Deletes a job by ID.
  """
  def delete(id) do
    :ets.delete(@table, id)
    :ok
  end

  # Server callbacks

  @impl true
  def init(_) do
    :ets.new(@table, [:named_table, :public, :set])
    {:ok, %{}}
  end

  # Helpers

  defp generate_id do
    :crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false)
  end

  defp broadcast(job) do
    Phoenix.PubSub.broadcast(Curator.PubSub, "jobs", {:job_updated, job})
  end
end
