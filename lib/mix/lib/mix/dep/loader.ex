# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2021 The Elixir Team
# SPDX-FileCopyrightText: 2012 Plataformatec

# This module is responsible for loading dependencies
# of the current project. This module and its functions
# are private to Mix.
defmodule Mix.Dep.Loader do
  @moduledoc false

  import Mix.Dep, only: [ok?: 1, mix?: 1, rebar?: 1, make?: 1]

  @doc """
  Gets all direct children of the current `Mix.Project`
  as a `Mix.Dep` struct. Umbrella project dependencies
  are included as children.

  By default, it will filter all dependencies that does not match
  current environment, behavior can be overridden via options.
  """
  def children(locked?) do
    mix_children(Mix.Project.config(), locked?, []) ++ Mix.Dep.Umbrella.unloaded()
  end

  @doc """
  Partitions loaded dependencies by environment.
  """
  def split_by_env_and_target(deps, {nil, nil}), do: {deps, []}

  def split_by_env_and_target(deps, env_target),
    do: Enum.split_with(deps, &(not skip?(&1, env_target)))

  @doc """
  Checks if a dependency must be skipped according to the environment.
  """
  def skip?(%Mix.Dep{status: {:divergedonly, _}}, _), do: false
  def skip?(%Mix.Dep{status: {:divergedtargets, _}}, _), do: false

  def skip?(%Mix.Dep{opts: opts}, {env, target}) do
    skip?(opts[:only], :only, env) or skip?(opts[:targets], :targets, target)
  end

  # The dependency is not filtered
  defp skip?(nil, _key, _value), do: false

  # The command is not filtered
  defp skip?(_maybe_list_of_atoms, _key, nil), do: false

  # The dependency is filtered as well as the command
  defp skip?(maybe_list_of_atoms, key, value) do
    wrapped = List.wrap(maybe_list_of_atoms)

    for entry <- wrapped, not is_atom(entry) do
      Mix.raise(
        "Expected #{inspect(key)} in dependency to be an atom or a list of atoms, " <>
          "got: #{inspect(maybe_list_of_atoms)}"
      )
    end

    value not in wrapped
  end

  def with_system_env(%Mix.Dep{system_env: []}, callback), do: callback.()

  def with_system_env(%Mix.Dep{system_env: new_env}, callback) do
    old_env =
      for {key, _} <- new_env do
        key = to_string(key)
        {key, System.get_env(key)}
      end

    try do
      System.put_env(new_env)
      callback.()
    after
      System.put_env(old_env)
    end
  end

  @doc """
  Loads the given dependency information, including its
  latest status and children.
  """
  def load(%Mix.Dep{manager: manager, scm: scm, opts: opts} = dep, children, locked?) do
    # The manager for a child dependency is set based on the following rules:
    #   1. Set in dependency definition
    #   2. From SCM, so that Hex dependencies of a rebar project can be compiled with mix
    #   3. From the parent dependency, used for rebar dependencies from git
    #   4. Inferred from files in dependency (mix.exs, rebar.config, Makefile)
    manager = opts[:manager] || scm_manager(scm, opts) || manager || infer_manager(opts[:dest])
    dep = %{dep | manager: manager, status: scm_status(scm, opts)}

    {dep, children} =
      cond do
        not ok?(dep) ->
          {dep, []}

        mix?(dep) ->
          mix_dep(dep, children, locked?)

        # If not an explicit Rebar or Mix dependency
        # but came from Rebar, assume to be a Rebar dep.
        rebar?(dep) ->
          rebar_dep(dep, children, manager, locked?)

        make?(dep) ->
          make_dep(dep)

        true ->
          {dep, []}
      end

    validate_app(%{dep | deps: attach_only_and_targets(children, opts)})
  end

  @doc """
  Checks if a requirement from a dependency matches
  the given version.
  """
  def vsn_match(nil, _actual, _app), do: {:ok, true}

  def vsn_match(req, actual, app) do
    if is_struct(req, Regex) do
      {:ok, actual =~ req}
    else
      case Version.parse(actual) do
        {:ok, version} ->
          case Version.parse_requirement(req) do
            {:ok, req} ->
              {:ok, Version.match?(version, req)}

            :error ->
              Mix.raise("Invalid requirement #{req} for app #{app}")
          end

        :error ->
          {:error, :nosemver}
      end
    end
  end

  ## Helpers

  defp to_dep(tuple, from, manager, locked?) do
    %{with_scm_and_app(tuple, locked?) | from: from, manager: manager}
  end

  defp with_scm_and_app({app, opts} = original, locked?) when is_atom(app) and is_list(opts) do
    with_scm_and_app(app, nil, opts, original, locked?)
  end

  defp with_scm_and_app({app, req} = original, locked?) when is_atom(app) do
    if is_binary(req) or is_struct(req, Regex) do
      with_scm_and_app(app, req, [], original, locked?)
    else
      invalid_dep_format(original)
    end
  end

  defp with_scm_and_app({app, req, opts} = original, locked?)
       when is_atom(app) and is_list(opts) do
    if is_binary(req) or is_struct(req, Regex) do
      with_scm_and_app(app, req, opts, original, locked?)
    else
      invalid_dep_format(original)
    end
  end

  defp with_scm_and_app(original, _locked?) do
    invalid_dep_format(original)
  end

  defp with_scm_and_app(app, req, opts, original, locked?) do
    if not Keyword.keyword?(opts) do
      invalid_dep_format(original)
    end

    bin_app = Atom.to_string(app)

    config = Mix.Project.config()
    dest = compute_dest(config, app, bin_app, opts)
    build = Path.join([Mix.Project.build_path(config), "lib", bin_app])

    opts =
      opts
      |> Keyword.put(:dest, dest)
      |> Keyword.put(:build, build)

    {system_env, opts} = Keyword.pop(opts, :system_env, [])
    {scm, opts} = get_scm(app, opts)

    {scm, opts} =
      if is_nil(scm) and Mix.Hex.ensure_installed?(locked?) do
        _ = Mix.Hex.start()
        get_scm(app, opts)
      else
        {scm, opts}
      end

    if !scm do
      Mix.raise(
        "Could not find an SCM for dependency #{inspect(app)} from #{inspect(Mix.Project.get())}"
      )
    end

    if config[:app] == app do
      Mix.shell().error(
        "warning: the application name #{inspect(app)} is the same as one of its dependencies"
      )
    end

    %Mix.Dep{
      scm: scm,
      app: app,
      requirement: req,
      status: scm_status(scm, opts),
      opts: Keyword.put_new(opts, :env, :prod),
      system_env: Enum.to_list(system_env)
    }
  end

  defp get_scm(app, opts) do
    Enum.find_value(Mix.SCM.available(), {nil, opts}, fn scm ->
      (new = scm.accepts_options(app, opts)) && {scm, new}
    end)
  end

  # Computes the on-disk destination for a dep. When `:versioned_deps`
  # is enabled and we can extract a stable version identifier from the
  # lock entry, the dep is checked out under `deps/<app>/<version>/`,
  # with a `deps/<app>/current` symlink maintained by Mix.Dep.Fetcher.
  # Falls back to the unversioned `deps/<app>/` path when no version
  # is available (no lock entry, path dep, or feature disabled).
  defp compute_dest(config, app, bin_app, opts) do
    base = Path.join(Mix.Project.deps_path(config), bin_app)

    if Keyword.get(config, :versioned_deps, false) do
      case dep_version_for(app, opts, config) do
        nil ->
          # If the user enabled `:versioned_deps` after deps were already
          # checked out unversioned, deps/<app>/ is now a non-versioned
          # checkout. Surface that condition so they know to migrate.
          maybe_warn_unversioned_checkout(base, bin_app)
          base

        version ->
          Path.join(base, version)
      end
    else
      base
    end
  end

  # Extracts a directory-safe version identifier from the lock entry
  # for the given app. Path deps yield nil (no versioning).
  #
  # The lockfile path is taken from `config[:lockfile]` rather than going
  # through `Mix.Dep.Lock.read/0`'s default-arg lookup, which itself
  # calls `Mix.Project.config()`. This function is reachable from inside
  # `Mix.ProjectStack.push/3` (via dep loading), and re-entering the
  # ProjectStack GenServer there deadlocks the project stack process —
  # the same shape of bug we already fixed once in
  # `Mix.Dep.BuildCache.active_build_tag/1`.
  defp dep_version_for(app, opts, config) do
    lock =
      cond do
        opts[:lock] -> %{app => opts[:lock]}
        true -> Mix.Dep.Lock.read(config[:lockfile] || "mix.lock")
      end

    lock_version(lock[app])
  end

  defp maybe_warn_unversioned_checkout(base, bin_app) do
    if File.regular?(Path.join(base, "mix.exs")) or
         File.regular?(Path.join(base, "rebar.config")) do
      Mix.shell().error(
        "warning: deps/#{bin_app} appears to be a non-versioned checkout but " <>
          ":versioned_deps is enabled. Run \"mix deps.clean #{bin_app}\" and " <>
          "\"mix deps.get\" to migrate it to deps/#{bin_app}/<version>/."
      )
    end
  end

  @doc """
  Extracts a directory-safe version identifier from a `mix.lock` entry.

  Used by `:versioned_deps` to compute the per-version checkout path
  `deps/<app>/<version>/`. The returned string is safe to use as a single
  path segment (see `sanitize_version/1`).

  Returns `nil` when no usable identifier can be derived. The caller falls
  back to the unversioned `deps/<app>/` layout. Nil is returned for:

    * a `nil` lock entry — the dep was just added to `mix.exs` and
      `mix deps.get` has not written a lock yet
    * path deps — the source lives outside `deps/` and has no SCM-managed
      version concept
    * unknown or future SCM tuple shapes — fails closed rather than
      fabricate a version string that does not reflect the checkout

  ## Lock entry shapes

  The trailing Hex fields evolved across versions, so all three Hex
  tuple arities are matched:

    * `{:hex, app, version, hash, managers, deps, repo, outer_hash}` (8-tuple, current)
    * `{:hex, app, version, hash, managers, deps, repo}` (7-tuple)
    * `{:hex, app, version, hash, managers, deps}` (6-tuple, pre-1.10)
    * `{:git, url, sha, opts}` — `opts` may contain `:ref`, `:branch`, or `:tag`

  ## Return shape per SCM

    * Hex: the lock's version string, sanitized
      (e.g. `"1.0.0-rc.1+build.5"` becomes `"1.0.0-rc.1-build.5"`)
    * Git with a ref/branch/tag: `"<sanitized-ref>-<8-char-sha>"`
      (e.g. `"main-abcdef12"`)
    * Git without a ref: `"<8-char-sha>"` (e.g. `"abcdef12"`)

  ## Examples

      iex> Mix.Dep.Loader.lock_version({:hex, :foo, "1.2.3", "h", [], [], "hexpm", "h"})
      "1.2.3"

      iex> Mix.Dep.Loader.lock_version({:git, "url", "abcdef1234567890", [ref: "main"]})
      "main-abcdef12"

      iex> Mix.Dep.Loader.lock_version({:path, "../foo", []})
      nil

  The function is public (rather than private) so the test suite can
  exercise the SCM-shape matrix directly without setting up a full
  project. It is otherwise an internal implementation detail of
  `compute_dest/4`.
  """
  @spec lock_version(term()) :: String.t() | nil
  def lock_version(nil), do: nil

  def lock_version({:hex, _pkg, version, _hash, _managers, _deps, _repo, _outer_hash})
      when is_binary(version),
      do: sanitize_version(version)

  def lock_version({:hex, _pkg, version, _hash, _managers, _deps, _repo})
      when is_binary(version),
      do: sanitize_version(version)

  def lock_version({:hex, _pkg, version, _hash, _managers, _deps})
      when is_binary(version),
      do: sanitize_version(version)

  def lock_version({:git, _url, sha, lock_opts}) when is_binary(sha) do
    short = binary_part(sha, 0, min(byte_size(sha), 8))

    case lock_opts[:ref] || lock_opts[:branch] || lock_opts[:tag] do
      nil -> short
      ref when is_binary(ref) -> sanitize_version(ref) <> "-" <> short
      _ -> short
    end
  end

  # Path deps and unknown SCMs: no versioning. Catches anything not matched
  # by the explicit clauses above (including future Hex tuple sizes that
  # Mix doesn't yet recognize, in which case skipping versioning is the
  # safe behavior — the dep still works, it just shares `deps/<app>/`).
  def lock_version(_), do: nil

  # Replaces filesystem-unfriendly characters. POSIX accepts most
  # things but `+` and `/` cause issues with shells, build tools,
  # and URLs. Pre-release/build separators in semver (`-`, `+`) are
  # collapsed to `-`.
  defp sanitize_version(version) do
    version
    |> String.replace(~r{[/+\s]+}, "-")
    |> String.replace(~r{-+}, "-")
    |> String.trim("-")
  end

  # Note that we ignore Make dependencies because the
  # file based heuristic will always figure it out.
  @scm_managers ~w(mix rebar3)a

  defp scm_manager(scm, opts) do
    managers = scm.managers(opts)
    Enum.find(@scm_managers, &(&1 in managers))
  end

  defp scm_status(scm, opts) do
    if scm.checked_out?(opts) do
      {:ok, nil}
    else
      {:unavailable, opts[:dest]}
    end
  end

  defp infer_manager(dest) do
    cond do
      any_of?(dest, ["mix.exs"]) ->
        :mix

      any_of?(dest, ["rebar", "rebar.config", "rebar.config.script", "rebar.lock"]) ->
        :rebar3

      any_of?(dest, ["Makefile", "Makefile.win"]) ->
        :make

      true ->
        nil
    end
  end

  defp any_of?(dest, files) do
    Enum.any?(files, &File.regular?(Path.join(dest, &1)))
  end

  defp invalid_dep_format(dep) do
    Mix.raise("""
    Dependency specified in the wrong format:

        #{inspect(dep)}

    Expected:

        {app, opts} | {app, requirement} | {app, requirement, opts}

    Where:

        app :: atom
        requirement :: String.t | Regex.t
        opts :: keyword

    If you want to skip the requirement (not recommended), use ">= 0.0.0".
    """)
  end

  ## Fetching

  # We need to override the dependencies so they mirror
  # the :only and :targets requirements from the parent.
  defp attach_only_and_targets(deps, opts) do
    case Keyword.take(opts, [:only, :targets]) do
      [] ->
        deps

      merge_opts ->
        Enum.map(deps, fn %{opts: opts} = dep ->
          %{dep | opts: Keyword.merge(merge_opts, opts)}
        end)
    end
  end

  defp mix_dep(%Mix.Dep{app: app, opts: opts} = dep, nil, locked?) do
    Mix.Dep.in_dependency(dep, fn _ ->
      config = Mix.Project.config()

      opts =
        if Mix.Project.umbrella?() do
          Keyword.put_new(opts, :app, false)
        else
          opts
        end

      child_opts =
        if opts[:from_umbrella] do
          if config[:app] != app do
            Mix.raise(
              "Umbrella app #{inspect(config[:app])} is located at " <>
                "directory #{app}. Mix requires the directory to match " <>
                "the application name for umbrella apps. Please rename the " <>
                "directory or change the application name in the mix.exs file."
            )
          end

          []
        else
          [env: Keyword.fetch!(opts, :env)]
        end

      deps = mix_children(config, locked?, child_opts) ++ Mix.Dep.Umbrella.unloaded()
      {%{dep | opts: opts}, deps}
    end)
  end

  # If we have a Mix dependency that came from a remote converger,
  # we just use the dependencies given by the remote converger,
  # we don't need to load the mix.exs at all. We can only do this
  # because umbrella projects are not supported in remotes.
  defp mix_dep(%Mix.Dep{opts: opts} = dep, children, locked?) do
    from = Path.join(opts[:dest], "mix.exs")
    deps = Enum.map(children, &to_dep(&1, from, _manager = nil, locked?))
    {dep, deps}
  end

  defp rebar_dep(dep, children, manager, locked?) do
    %Mix.Dep{app: app, opts: opts, extra: overrides} = dep

    if locked? and not Mix.Rebar.available?(manager) do
      Mix.Tasks.Local.Rebar.run(["--force"])
    end

    config = File.cd!(opts[:dest], fn -> Mix.Rebar.load_config(".") end)
    config = Mix.Rebar.apply_overrides(app, config, overrides)

    deps =
      if children do
        from = Path.join(opts[:dest], "rebar.config")
        # Pass the manager because deps of a Rebar project need
        # to default to Rebar if we cannot chose a manager from
        # files in the dependency
        Enum.map(children, &to_dep(&1, from, manager, locked?))
      else
        rebar_children(config, manager, opts[:dest], locked?)
      end

    {%{dep | extra: config}, deps}
  end

  defp make_dep(dep) do
    {dep, []}
  end

  defp mix_children(config, locked?, opts) do
    from = Mix.Project.project_file()

    (config[:deps] || [])
    |> Enum.map(&to_dep(&1, from, _manager = nil, locked?))
    |> split_by_env_and_target({opts[:env], nil})
    |> elem(0)
  end

  defp rebar_children(config, manager, dest, locked?) do
    from = Path.absname(Path.join(dest, "rebar.config"))
    overrides = overrides(manager, config)

    config
    |> Mix.Rebar.deps()
    |> Enum.map(fn dep -> %{to_dep(dep, from, manager, locked?) | extra: overrides} end)
  end

  defp overrides(:rebar3, config), do: config[:overrides] || []
  defp overrides(_, _config), do: []

  defp validate_app(%Mix.Dep{opts: opts, requirement: req, app: app} = dep) do
    opts_app = opts[:app]

    cond do
      not ok?(dep) ->
        dep

      opts_app == false ->
        dep

      true ->
        path = if is_binary(opts_app), do: opts_app, else: "ebin/#{app}.app"
        path = Path.expand(path, opts[:build])

        case app_status(path, app, req) do
          {:ok, vsn, app} -> %{dep | status: {:ok, vsn}, opts: [app_properties: app] ++ opts}
          status -> %{dep | status: status}
        end
    end
  end

  defp app_status(app_path, app, req) do
    case Mix.AppLoader.read_app(app, app_path) do
      {:ok, properties} ->
        case List.keyfind(properties, :vsn, 0) do
          {:vsn, actual} when is_list(actual) ->
            actual = IO.iodata_to_binary(actual)

            case vsn_match(req, actual, app) do
              {:ok, true} -> compile_env_status(actual, properties)
              {:ok, false} -> {:nomatchvsn, actual}
              {:error, error} -> {error, actual}
            end

          {:vsn, actual} ->
            {:invalidvsn, actual}

          nil ->
            {:invalidvsn, nil}
        end

      :invalid ->
        {:invalidapp, app_path}

      :missing ->
        case Path.wildcard(Path.join(Path.dirname(app_path), "*.app")) do
          [other_app_path] -> {:noappfile, {app_path, other_app_path}}
          _ -> {:noappfile, {app_path, nil}}
        end
    end
  end

  defp compile_env_status(vsn, properties) do
    with [_ | _] = compile_env <- properties[:compile_env],
         false <- Config.Provider.valid_compile_env?(compile_env) do
      :envoutdated
    else
      _ -> {:ok, vsn, properties}
    end
  end
end
