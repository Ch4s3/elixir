# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2021 The Elixir Team
# SPDX-FileCopyrightText: 2012 Plataformatec

# Module responsible for fetching (getting/updating)
# dependencies from their sources.
#
# The new_lock and old_lock mechanism exists to signal
# externally which dependencies need to be updated and
# which ones do not.
defmodule Mix.Dep.Fetcher do
  @moduledoc false

  import Mix.Dep, only: [format_dep: 1, check_lock: 1, available?: 1]

  @doc """
  Fetches all dependencies.
  """
  def all(old_lock, new_lock, opts) do
    result = Mix.Dep.Converger.converge([], new_lock, opts, &do_fetch/3)
    {apps, _deps} = do_finalize(result, old_lock, opts)
    apps
  end

  @doc """
  Fetches the dependencies with the given names and their children recursively.
  """
  def by_name(names, old_lock, new_lock, opts) do
    fetcher = fetch_by_name(names, new_lock)
    result = Mix.Dep.Converger.converge([], new_lock, opts, fetcher)
    {apps, deps} = do_finalize(result, old_lock, opts)

    # Check if all given dependencies are loaded or fail
    _ = Mix.Dep.filter_by_name(names, deps, opts)
    apps
  end

  defp fetch_by_name(given, lock) do
    names = to_app_names(given)

    fn %Mix.Dep{app: app} = dep, acc, new_lock ->
      # Only fetch if dependency is in given names or if lock has
      # been changed for dependency by remote converger or it is new
      if app in names or lock[app] != new_lock[app] or is_nil(lock[app]) do
        do_fetch(dep, acc, new_lock)
      else
        {dep, acc, new_lock}
      end
    end
  end

  defp do_fetch(dep, acc, lock) do
    %Mix.Dep{app: app, scm: scm, opts: opts} = dep = check_lock(dep)

    cond do
      # Dependencies that cannot be fetched are always compiled afterwards
      not scm.fetchable?() ->
        if not scm.checked_out?(opts) do
          Mix.shell().error("warning: missing dependency #{format_dep(dep)}")
        end

        {dep, [app | acc], lock}

      # If the dependency is not available or we have a lock mismatch
      out_of_date?(dep) ->
        # Mark the dependency as fetched upfront, in case updating fails,
        # gets interrupted, or corrupted.
        mark_as_fetched([dep])

        new =
          if scm.checked_out?(opts) do
            Mix.shell().info("* Updating #{format_dep(dep)}")
            scm.update(opts)
          else
            Mix.shell().info("* Getting #{format_dep(dep)}")
            scm.checkout(opts)
          end

        if new do
          dep = put_in(dep.opts[:lock], new)
          maybe_update_current_symlink(dep)
          {dep, [app | acc], Map.put(lock, app, new)}
        else
          {dep, acc, lock}
        end

      # The dependency is ok or has some other error
      true ->
        {dep, acc, lock}
    end
  end

  defp out_of_date?(%Mix.Dep{status: {:lockmismatch, _}}), do: true
  defp out_of_date?(%Mix.Dep{status: :lockoutdated}), do: true
  defp out_of_date?(%Mix.Dep{status: :nolock}), do: true
  defp out_of_date?(%Mix.Dep{status: {:unavailable, _}}), do: true
  defp out_of_date?(%Mix.Dep{}), do: false

  defp do_finalize({all_deps, apps, new_lock}, old_lock, opts) do
    # Let's get the loaded versions of deps
    deps = Mix.Dep.filter_by_name(apps, all_deps, opts)

    # Note we only retrieve the parent dependencies of the updated
    # deps if all dependencies are available. This is because if a
    # dependency is missing, it could directly affect one of the
    # dependencies we are trying to compile, causing the whole thing
    # to fail.
    parent_deps =
      if Enum.all?(all_deps, &available?/1) do
        Enum.uniq_by(with_depending(deps, all_deps), & &1.app)
      else
        []
      end

    # Mark parents as fetched before we write the lock file.
    mark_as_fetched(parent_deps)

    # Merge the new lock on top of the old to guarantee we don't
    # leave out things that could not be fetched and save it.
    lock = Map.merge(old_lock, new_lock)
    Mix.Dep.Lock.write(lock, opts)

    # See if any of the deps diverged and abort.
    show_diverged!(Enum.filter(all_deps, &Mix.Dep.diverged?/1))

    {apps, all_deps}
  end

  # When `:versioned_deps` is enabled, `opts[:dest]` is `deps/<app>/<version>/`.
  # Maintain a relative `deps/<app>/current` symlink to the active version so
  # external tools (Phoenix asset pipelines, NIF build scripts, etc.) can refer
  # to a stable path. The symlink is updated atomically via temp+rename so a
  # concurrent reader never sees a half-replaced link.
  defp maybe_update_current_symlink(%Mix.Dep{opts: opts}) do
    dest = opts[:dest]
    parent = Path.dirname(dest)

    case versioned_dep_dir?(dest, parent) do
      true -> swap_current_symlink(parent, Path.basename(dest))
      false -> :ok
    end
  end

  # True when `:versioned_deps` is on AND `dest` is a real versioned path.
  # A versioned dest looks like `<deps_path>/<app>/<version>/`, so its
  # grandparent must equal `deps_path` after expansion. We compare the
  # expanded forms because `dest` and `deps_path` can disagree on trailing
  # slashes, relative-vs-absolute, or symlink resolution depending on how
  # they were constructed.
  defp versioned_dep_dir?(dest, parent) do
    Keyword.get(Mix.Project.config(), :versioned_deps, false) and
      File.dir?(dest) and
      Path.expand(Path.dirname(parent)) == Path.expand(Mix.Project.deps_path())
  end

  defp swap_current_symlink(parent, version) do
    current = Path.join(parent, "current")
    tmp = current <> ".tmp"

    # Clear any leftover tmp from a prior interrupted run; ignore failures.
    _ = File.rm(tmp)

    with :ok <- File.ln_s(version, tmp),
         :ok <- File.rename(tmp, current) do
      :ok
    else
      {:error, reason} ->
        _ = File.rm(tmp)
        warn_symlink_failure(current, reason)
    end
  end

  defp warn_symlink_failure(current, reason) do
    Mix.shell().error(
      "warning: could not update current symlink at " <>
        "#{Path.relative_to_cwd(current)}: #{:file.format_error(reason)}"
    )
  end

  defp mark_as_fetched(deps) do
    # Walk every per-environment build dir under `_build/` (dev, test,
    # dev-<hash>, etc.) and remove the dep's compile manifest so the
    # next compile re-resolves it. Avoids `Path.wildcard` because the
    # `_build/` parent path can contain glob meta characters (`{`,
    # `,`, `}`) on some users' machines and would mis-match silently.
    build_root = Mix.Project.build_path() |> Path.dirname()

    for %Mix.Dep{app: app, scm: scm} <- deps, scm.fetchable?() do
      remove_compile_manifests(build_root, app)
    end

    :ok
  end

  defp remove_compile_manifests(build_root, app) do
    case File.ls(build_root) do
      {:ok, entries} ->
        for entry <- entries,
            full = Path.join(build_root, entry),
            File.dir?(full) do
          manifest = Path.join([full, "lib", to_string(app), ".mix", "compile.elixir_scm"])
          _ = File.rm(manifest)
        end

      _ ->
        :ok
    end
  end

  defp with_depending(deps, all_deps) do
    deps ++ do_with_depending(deps, all_deps)
  end

  defp do_with_depending([], _all_deps) do
    []
  end

  defp do_with_depending(deps, all_deps) do
    dep_names = Enum.map(deps, fn dep -> dep.app end)

    parents =
      Enum.filter(all_deps, fn dep ->
        Enum.any?(dep.deps, &(&1.app in dep_names))
      end)

    do_with_depending(parents, all_deps) ++ parents
  end

  defp to_app_names(given) do
    Enum.map(given, fn app ->
      if is_binary(app), do: String.to_atom(app), else: app
    end)
  end

  defp show_diverged!([]), do: :ok

  defp show_diverged!(deps) do
    shell = Mix.shell()
    shell.error("Dependencies have diverged:")

    Enum.each(deps, fn dep ->
      shell.error("* #{Mix.Dep.format_dep(dep)}")
      shell.error("  #{Mix.Dep.format_status(dep)}")
    end)

    Mix.raise("Can't continue due to errors on dependencies")
  end
end
