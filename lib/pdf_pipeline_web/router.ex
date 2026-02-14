defmodule PdfPipelineWeb.Router do
  use PdfPipelineWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {PdfPipelineWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", PdfPipelineWeb do
    pipe_through :browser

    live "/", DashboardLive, :index
    live "/review/:job_id", ReviewLive, :show
    live "/review/:job_id/edit", EditorLive, :edit
    live "/review/:job_id/export", ExportLive, :export
  end

  # Other scopes may use custom stacks.
  # scope "/api", PdfPipelineWeb do
  #   pipe_through :api
  # end
end
