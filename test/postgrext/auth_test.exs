defmodule Postgrext.AuthTest do
  use ExUnit.Case, async: true

  alias Postgrext.Auth

  @secret "reallyreallyreallyreallyverysafe"

  defp token(claims) do
    signer = Joken.Signer.create("HS256", @secret)
    {:ok, token, _claims} = Joken.encode_and_sign(claims, signer)
    token
  end

  test "no header resolves to the anon role" do
    assert %{role: "anon", claims: %{"role" => "anon"}} =
             Auth.resolve(nil, jwt_secret: @secret, anon_role: "anon")
  end

  test "no header and no anon role resolves to no role" do
    assert %{role: nil, claims: %{}} = Auth.resolve(nil, jwt_secret: @secret, anon_role: nil)
  end

  test "ignores tokens when no secret is configured" do
    assert %{role: "anon"} =
             Auth.resolve("Bearer whatever", jwt_secret: nil, anon_role: "anon")
  end

  test "extracts the role claim from a valid token" do
    header = "Bearer " <> token(%{"role" => "web_user"})

    assert %{role: "web_user", claims: %{"role" => "web_user"}} =
             Auth.resolve(header, jwt_secret: @secret, anon_role: "anon")
  end

  test "falls back to anon role when the token has no role claim" do
    header = "Bearer " <> token(%{"sub" => "1"})
    assert %{role: "anon"} = Auth.resolve(header, jwt_secret: @secret, anon_role: "anon")
  end

  test "rejects a bad signature" do
    signer = Joken.Signer.create("HS256", "wrong-secret-wrong-secret-wrong!")
    {:ok, bad_token, _claims} = Joken.encode_and_sign(%{"role" => "admin"}, signer)

    assert_raise Postgrext.Error, ~r/Invalid JWT/, fn ->
      Auth.resolve("Bearer " <> bad_token, jwt_secret: @secret, anon_role: "anon")
    end
  end

  test "rejects an expired token" do
    header = "Bearer " <> token(%{"role" => "web_user", "exp" => 100})

    assert_raise Postgrext.Error, ~r/JWT expired/, fn ->
      Auth.resolve(header, jwt_secret: @secret, anon_role: "anon", now: 200)
    end
  end

  test "accepts a not-yet-expired token" do
    header = "Bearer " <> token(%{"role" => "web_user", "exp" => 300})

    assert %{role: "web_user"} =
             Auth.resolve(header, jwt_secret: @secret, anon_role: "anon", now: 200)
  end

  test "rejects non-bearer schemes" do
    assert_raise Postgrext.Error, ~r/authorization scheme/, fn ->
      Auth.resolve("Basic abc", jwt_secret: @secret, anon_role: "anon")
    end
  end
end
