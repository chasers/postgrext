defmodule Postgrext.Router do
  @moduledoc """
  Maps PostgREST-style routes onto `Postgrext.Controller`: `/` for the
  schema listing, `/rpc/:function` for function calls, and `/:relation` for
  table and view access.
  """

  use Plug.Router

  plug(Plug.Logger)
  plug(:match)
  plug(:dispatch)

  get "/" do
    Postgrext.Controller.root(conn)
  end

  get "/rpc/:fname" do
    Postgrext.Controller.rpc(conn, fname)
  end

  post "/rpc/:fname" do
    Postgrext.Controller.rpc(conn, fname)
  end

  get "/:relation" do
    Postgrext.Controller.read(conn, relation)
  end

  post "/:relation" do
    Postgrext.Controller.create(conn, relation)
  end

  patch "/:relation" do
    Postgrext.Controller.update(conn, relation)
  end

  delete "/:relation" do
    Postgrext.Controller.delete(conn, relation)
  end

  match _ do
    Postgrext.Controller.not_found(conn)
  end
end
