defmodule Postgrext.Auth do
  @moduledoc """
  Resolves the database role for a request.

  With `PGRST_JWT_SECRET` set, a `Bearer` token is verified (HS256) and its
  `role` claim is used; expired or invalid tokens are rejected with 401.
  Without a token the configured anon role applies. Without a configured
  secret every request runs as the anon role (or the connection role when no
  anon role is configured either).
  """

  alias Postgrext.Error

  @spec resolve(String.t() | nil, keyword()) :: %{role: String.t() | nil, claims: map()}
  def resolve(authorization_header, opts \\ []) do
    secret = Keyword.get(opts, :jwt_secret, Postgrext.Config.get(:jwt_secret))
    anon_role = Keyword.get(opts, :anon_role, Postgrext.Config.get(:anon_role))
    now = Keyword.get(opts, :now, System.system_time(:second))

    case {authorization_header, secret} do
      {nil, _secret} ->
        anonymous(anon_role)

      {_header, nil} ->
        anonymous(anon_role)

      {header, secret} ->
        token = extract_bearer(header)
        claims = verify(token, secret, now)
        %{role: Map.get(claims, "role", anon_role), claims: claims}
    end
  end

  defp anonymous(anon_role) do
    claims = if anon_role, do: %{"role" => anon_role}, else: %{}
    %{role: anon_role, claims: claims}
  end

  defp extract_bearer(header) do
    case String.split(header, " ", parts: 2) do
      [scheme, token] ->
        if String.downcase(scheme) == "bearer" do
          String.trim(token)
        else
          raise Error.jwt_error("Unsupported authorization scheme")
        end

      _other ->
        raise Error.jwt_error("Malformed authorization header")
    end
  end

  defp verify(token, secret, now) do
    signer = Joken.Signer.create("HS256", secret)

    case Joken.verify(token, signer) do
      {:ok, claims} ->
        check_expiry(claims, now)
        claims

      {:error, _reason} ->
        raise Error.jwt_error("Invalid JWT")
    end
  end

  defp check_expiry(%{"exp" => exp}, now) when is_integer(exp) do
    if exp <= now do
      raise Error.jwt_error("JWT expired")
    end
  end

  defp check_expiry(_claims, _now), do: :ok
end
