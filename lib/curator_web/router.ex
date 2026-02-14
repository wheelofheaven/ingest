defmodule CuratorWeb.Router do
  use CuratorWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {CuratorWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", CuratorWeb do
    pipe_through :browser

    live "/", DashboardLive, :index
    live "/edit/:slug", EditorLive, :edit
    live "/review/:job_id", ReviewLive, :show
    live "/review/:job_id/edit", EditorLive, :edit_job
    live "/review/:job_id/export", ExportLive, :export
  end

  # Other scopes may use custom stacks.
  # scope "/api", CuratorWeb do
  #   pipe_through :api
  # end
end
