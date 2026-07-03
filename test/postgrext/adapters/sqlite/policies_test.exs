defmodule Postgrext.Adapters.SQLite.PoliciesTest do
  use ExUnit.Case, async: true

  alias Postgrext.Adapters.SQLite.Policies

  @table %{schema: "main", name: "docs"}
  @auth %{role: "authenticated", claims: %{"sub" => "u1"}}

  defp cache(policies, opts \\ []) do
    enabled =
      if Keyword.get(opts, :enabled, true) do
        MapSet.new([{"main", "docs"}])
      else
        MapSet.new()
      end

    %{rls_enabled: enabled, policies: %{{"main", "docs"} => policies}}
  end

  defp policy(overrides) do
    Map.merge(
      %{name: "p", command: "ALL", kind: :permissive, roles: nil, using: nil, check: nil},
      Map.new(overrides)
    )
  end

  describe "visibility/4" do
    test "returns nil when RLS is not enabled for the table" do
      cache = cache([policy(using: "1")], enabled: false)
      assert Policies.visibility(cache, @auth, @table, "SELECT") == nil
    end

    test "denies everything when enabled with no applicable policy" do
      assert Policies.visibility(cache([]), @auth, @table, "SELECT") == {"0", []}
    end

    test "works without a policies entry or auth" do
      cache = %{rls_enabled: MapSet.new([{"main", "docs"}]), policies: %{}}
      assert Policies.visibility(cache, nil, @table, "SELECT") == {"0", []}
    end

    test "binds auth.uid() as a parameter" do
      cache = cache([policy(using: "owner = auth.uid()")])
      assert Policies.visibility(cache, @auth, @table, "SELECT") == {"((owner = ?))", ["u1"]}
    end

    test "binds auth.role() and auth.jwt() in occurrence order" do
      cache = cache([policy(using: "auth.role() = 'admin' or auth.jwt() ->> 'org' = org")])

      assert Policies.visibility(cache, @auth, @table, "SELECT") ==
               {"((? = 'admin' or ? ->> 'org' = org))",
                ["authenticated", Jason.encode!(@auth.claims)]}
    end

    test "binds nulls when there is no auth context" do
      cache = cache([policy(using: "owner = auth.uid()")])
      assert Policies.visibility(cache, nil, @table, "SELECT") == {"((owner = ?))", [nil]}
    end

    test "ors permissive policies together" do
      cache = cache([policy(name: "a", using: "a > 1"), policy(name: "b", using: "b > 2")])

      assert Policies.visibility(cache, @auth, @table, "SELECT") ==
               {"((a > 1) or (b > 2))", []}
    end

    test "ands restrictive policies on top of permissive ones" do
      cache =
        cache([
          policy(name: "open", using: "1"),
          policy(name: "tenant", kind: :restrictive, using: "org = 'x'")
        ])

      assert Policies.visibility(cache, @auth, @table, "SELECT") ==
               {"((1)) and (org = 'x')", []}
    end

    test "a lone restrictive policy still denies without a permissive grant" do
      cache = cache([policy(kind: :restrictive, using: "1")])
      assert Policies.visibility(cache, @auth, @table, "SELECT") == {"0 and (1)", []}
    end

    test "filters policies by command" do
      cache = cache([policy(command: "SELECT", using: "1")])
      assert Policies.visibility(cache, @auth, @table, "SELECT") == {"((1))", []}
      assert Policies.visibility(cache, @auth, @table, "DELETE") == {"0", []}
    end

    test "filters policies by role" do
      cache = cache([policy(roles: ["manager"], using: "1")])
      assert Policies.visibility(cache, @auth, @table, "SELECT") == {"0", []}

      manager = %{role: "manager", claims: %{}}
      assert Policies.visibility(cache, manager, @table, "SELECT") == {"((1))", []}
      assert Policies.visibility(cache, nil, @table, "SELECT") == {"0", []}
    end
  end

  describe "check/4" do
    test "prefers check_expr and falls back to using_expr" do
      cache = cache([policy(using: "a > 1", check: "a > 10")])
      assert Policies.check(cache, @auth, @table, "UPDATE") == {"((a > 10))", []}

      cache = cache([policy(using: "a > 1")])
      assert Policies.check(cache, @auth, @table, "UPDATE") == {"((a > 1))", []}
    end

    test "denies when no applicable policy has an expression" do
      assert Policies.check(cache([policy([])]), @auth, @table, "INSERT") == {"0", []}
    end

    test "returns nil when RLS is not enabled" do
      cache = cache([policy(check: "1")], enabled: false)
      assert Policies.check(cache, @auth, @table, "INSERT") == nil
    end
  end

  describe "violation_query/3" do
    test "counts affected rows that fail the check" do
      assert Policies.violation_query("docs", [1, 2], {"owner = ?", ["u1"]}) ==
               {"select count(*) from \"docs\" as \"docs\" " <>
                  "where \"docs\".\"rowid\" in (?, ?) and not coalesce((owner = ?), 0)",
                [1, 2, "u1"]}
    end
  end
end
