defmodule PdfPipeline.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      PdfPipelineWeb.Telemetry,
      {DNSCluster, query: Application.get_env(:pdf_pipeline, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: PdfPipeline.PubSub},
      PdfPipeline.Store.Job,
      PdfPipelineWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: PdfPipeline.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    PdfPipelineWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
