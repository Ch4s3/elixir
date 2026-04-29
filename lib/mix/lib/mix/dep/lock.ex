# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2021 The Elixir Team
# SPDX-FileCopyrightText: 2012 Plataformatec

# This module keeps a lock file and the manifest for the lock file.
# The lockfile keeps the latest dependency information while the
# manifest is used whenever a dependency is affected via any of the
# deps.* tasks. We also keep the Elixir version in the manifest file.
defmodule Mix.Dep.Lock do
  @moduledoc false

  @typedoc """
  Options for `write/2`.
  """
  @type write_opts :: [
          file: Path.t(),
          check_locked: boolean()
        ]

  @doc """
  Reads the lockfile, returns a map containing
  each app name and its current lock information.
  """
  @spec read(Path.t()) :: map()
  def read(lockfile \\ lockfile()) do
    opts = [file: lockfile, emit_warnings: false]

    with {:ok, contents} <- File.read(lockfile),
         assert_no_merge_conflicts_in_lockfile(lockfile, contents),
         {:ok, quoted} <- Code.string_to_quoted(contents, opts),
         {%{} = lock, _binding} <- Code.eval_quoted(quoted, [], opts) do
      lock
    else
      _ -> %{}
    end
  end

  @doc """
  Returns a short content-addressable hash of the lockfile.

  Returns `nil` if the lockfile does not exist or is empty.
  The hash is the first 8 hex characters of the SHA-256 of the
  lockfile contents, which is sufficient for use as a cache key:
  even at 1000 distinct lockfiles, collision probability is ~10^-4,
  and a stale collision is caught by per-dep manifest checks during
  compilation (worst case is an unnecessary recompile, never a
  correctness bug).
  """
  @spec hash(Path.t()) :: String.t() | nil
  def hash(lockfile \\ lockfile()) do
    case File.read(lockfile) do
      {:ok, ""} ->
        nil

      {:ok, contents} ->
        :crypto.hash(:sha256, contents)
        |> Base.encode16(case: :lower)
        |> binary_part(0, 8)

      _ ->
        nil
    end
  end

  @doc """
  Receives a map and writes it as the latest lock.
  """
  @spec write(map(), write_opts) :: :ok
  def write(map, opts \\ []) do
    lockfile = opts[:file] || lockfile()

    if map != read() do
      if Keyword.get(opts, :check_locked, false) do
        Mix.raise(
          "Your #{lockfile} is out of date and must be updated without the --check-locked flag"
        )
      end

      lines =
        for {app, rev} <- Enum.sort(map), rev != nil do
          ~s(  "#{app}": #{inspect(rev, limit: :infinity)},\n)
        end

      File.write!(lockfile, ["%{\n", lines, "}\n"])
      Mix.Task.run("will_recompile")
    end

    :ok
  end

  defp lockfile do
    Mix.Project.config()[:lockfile]
  end

  defp assert_no_merge_conflicts_in_lockfile(lockfile, info) do
    if String.contains?(info, ~w(<<<<<<< ======= >>>>>>>)) do
      Mix.raise(
        "Your #{lockfile} contains merge conflicts. Please resolve the conflicts " <>
          "and run the command again"
      )
    end
  end
end
