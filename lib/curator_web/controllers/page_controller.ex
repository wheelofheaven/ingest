defmodule CuratorWeb.PageController do
  use CuratorWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
