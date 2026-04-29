# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Elixir Team

defmodule Mix.Dep.BuildCache do
  @moduledoc false

  # Implements the build-directory routing for `:build_per_lockfile`.
  #
  # The canonical build directory `_build/<env>/` is "owned" by the
  # lockfile that was first seen there. Its hash is recorded in a
  # sentinel file (`_build/<env>/.mix/build_lockfile_hash`).
  #
  # When the current `mix.lock` matches the sentinel, the canonical
  # path is used directly (zero overhead). When it diverges, a hashed
  # build directory `_build/<env>-<hash>/` is used instead, seeded
  # on first use by copying the most recently modified compatible
  # build dir (canonical or another hashed dir).

  @sentinel_basename "build_lockfile_hash"

  @doc """
  Returns the active build tag (hash string) for the current project,
  or nil if the canonical build directory should be used directly.

  This function is pure: it does not write to disk. The sentinel is
  only written by `claim_canonical/1`, called explicitly during compile.
  """
  @spec active_build_tag(keyword) :: String.t() | nil
  def active_build_tag(config \\ Mix.Project.config()) do
    # Take the lockfile path from the supplied config rather than going
    # back through Mix.Project.config(). This function is called from
    # within ProjectStack.push/3 where re-entering the GenServer would
    # deadlock the project stack process.
    case Mix.Dep.Lock.hash(config[:lockfile] || "mix.lock") do
      nil ->
        # No lockfile (or empty); use canonical. Nothing to cache.
        nil

      current_hash ->
        case read_sentinel(config) do
          nil ->
            # Canonical not yet claimed; use it. Compile will claim it.
            nil

          ^current_hash ->
            # Lock matches what canonical was built against; fast path.
            nil

          _other_hash ->
            # Diverged from canonical; route to hashed build dir.
            current_hash
        end
    end
  end

  @doc """
  Records the given lockfile hash as the canonical build directory's
  identity, if it has not yet been claimed.

  Called once per compile invocation against the build path that the
  compile actually uses. If the build path is a hashed (non-canonical)
  one, this is a no-op.
  """
  @spec claim_canonical(Path.t(), keyword) :: :ok
  def claim_canonical(build_path, config \\ Mix.Project.config()) do
    canonical = canonical_build_path(config)

    if Keyword.get(config, :build_per_lockfile, false) and
         Path.expand(build_path) == canonical do
      lockfile = config[:lockfile] || "mix.lock"

      case {Mix.Dep.Lock.hash(lockfile), read_sentinel(config)} do
        {nil, _} ->
          :ok

        {_hash, existing} when is_binary(existing) ->
          :ok

        {hash, nil} ->
          path = Path.join([canonical, ".mix", @sentinel_basename])
          File.mkdir_p!(Path.dirname(path))
          File.write!(path, hash)
          :ok
      end
    else
      :ok
    end
  end

  @doc """
  Seeds a freshly-routed hashed build dir by copying from the most
  recently modified compatible build dir, if the target does not yet
  exist.

  Returns `:copied` if a copy was performed, `:skipped` otherwise.
  """
  @spec seed_from_nearest(Path.t(), keyword) :: :copied | :skipped
  def seed_from_nearest(target_path, config \\ Mix.Project.config()) do
    cond do
      not Keyword.get(config, :build_per_lockfile, false) ->
        :skipped

      File.dir?(target_path) ->
        :skipped

      true ->
        case find_seed_source(target_path, config) do
          nil ->
            :skipped

          source ->
            Mix.shell().info(
              "* Seeding build cache: copying #{Path.relative_to_cwd(source)} → " <>
                Path.relative_to_cwd(target_path)
            )

            seed_atomically(source, target_path)
            :copied
        end
    end
  end

  # Copies `source` into a sibling `<target>.seed.tmp` first, strips the
  # sentinel inside, then atomically renames the staging dir into place.
  # If the cp_r is interrupted (Ctrl-C, OOM, etc.) the partially copied
  # tmp dir is cleaned up here and on the next invocation — `target` is
  # never observed in a half-populated state, so a subsequent
  # `seed_from_nearest` call will see `target` doesn't exist yet and
  # try again rather than silently compiling on top of stale artifacts.
  defp seed_atomically(source, target) do
    File.mkdir_p!(Path.dirname(target))
    tmp = target <> ".seed.tmp"

    # Cleanup any leftover from a prior interrupted seed — best effort.
    _ = File.rm_rf(tmp)

    try do
      File.cp_r!(source, tmp)

      # Strip the sentinel from the seed before publishing — the new
      # hashed dir's identity is its hash suffix, not a sentinel record.
      _ = File.rm(Path.join([tmp, ".mix", @sentinel_basename]))

      File.rename!(tmp, target)
    rescue
      e ->
        _ = File.rm_rf(tmp)
        reraise e, __STACKTRACE__
    end
  end

  @doc """
  Lists all hashed build dirs sibling to the canonical, returning paths.
  """
  @spec hashed_build_dirs(keyword) :: [Path.t()]
  def hashed_build_dirs(config \\ Mix.Project.config()) do
    canonical = canonical_build_path(config)
    parent = Path.dirname(canonical)
    prefix = Path.basename(canonical) <> "-"

    # Use File.ls + manual prefix matching rather than Path.wildcard so that
    # glob meta characters in the parent path (e.g. `{`, `}`, `,`) don't
    # corrupt the lookup. These can appear in legitimate project paths.
    case File.ls(parent) do
      {:ok, entries} ->
        for entry <- entries,
            String.starts_with?(entry, prefix),
            path = Path.join(parent, entry),
            File.dir?(path),
            do: path

      _ ->
        []
    end
  end

  @doc """
  Refreshes the cached size record for the given build dir.

  Walks the directory tree, totals regular file sizes, and writes the
  result to `<build_path>/.mix/build_size_bytes`. Intended to be called
  after a successful compile of the active build dir; subsequent reads
  via `cached_size/1` will use the recorded value until invalidation.
  """
  @spec refresh_size_cache(Path.t()) :: non_neg_integer() | :error
  def refresh_size_cache(build_path) do
    if File.dir?(build_path) do
      build_path
      |> walk_dir_size()
      |> tap(&write_size_cache(build_path, &1))
    else
      :error
    end
  end

  defp write_size_cache(build_path, bytes) do
    size_file = size_cache_file(build_path)
    File.mkdir_p!(Path.dirname(size_file))
    File.write!(size_file, Integer.to_string(bytes))
  end

  @doc """
  Returns the on-disk size in bytes of the given build dir, using a
  cached record when fresh. Recomputes (and re-caches) when the cache
  is missing or older than the dir's root-project compile manifest.
  """
  @spec cached_size(Path.t(), keyword) :: non_neg_integer()
  def cached_size(build_path, config \\ Mix.Project.config()) do
    size_file = size_cache_file(build_path)

    if size_cache_fresh?(build_path, size_file, config) do
      case File.read(size_file) do
        {:ok, contents} ->
          case Integer.parse(contents) do
            {bytes, _} -> bytes
            :error -> refresh_or_zero(build_path)
          end

        _ ->
          refresh_or_zero(build_path)
      end
    else
      refresh_or_zero(build_path)
    end
  end

  defp refresh_or_zero(build_path) do
    case refresh_size_cache(build_path) do
      bytes when is_integer(bytes) -> bytes
      :error -> 0
    end
  end

  @doc """
  Prunes hashed build dirs to keep only the `keep` most recent (by
  last-used mtime). The active build path and the canonical dir are
  always preserved regardless of `keep`.

  Returns `{:pruned, list_of_paths}` or `{:kept, count}` if nothing
  needed to be removed. A `keep` of `:infinity` is a no-op.
  """
  @spec prune_to(:infinity | non_neg_integer(), keyword) ::
          {:pruned, [Path.t()]} | {:kept, non_neg_integer()}
  def prune_to(:infinity, _config), do: {:kept, 0}

  def prune_to(keep, config) when is_integer(keep) and keep >= 0 do
    active = Path.expand(Mix.Project.build_path(config))
    canonical = canonical_build_path(config)
    protected = MapSet.new([active, canonical])

    candidates =
      hashed_build_dirs(config)
      |> Enum.reject(&MapSet.member?(protected, &1))
      |> Enum.map(fn path -> {path, last_used_mtime(path, config)} end)
      |> Enum.sort_by(fn {_path, mtime} -> mtime_for_sort(mtime) end, :desc)

    to_prune = Enum.drop(candidates, keep)

    pruned =
      for {path, mtime} <- to_prune do
        age = format_age(mtime)

        Mix.shell().info(
          "* Pruning cached build #{Path.relative_to_cwd(path)} (last used #{age})"
        )

        File.rm_rf(path)
        path
      end

    case pruned do
      [] -> {:kept, length(candidates)}
      _ -> {:pruned, pruned}
    end
  end

  @doc """
  Prints a one-line status summary of cached lockfile builds when
  `:build_per_lockfile` is enabled and there is at least one hashed
  build dir on disk. Suppressed when only the canonical exists.
  """
  @spec print_status(keyword) :: :ok
  def print_status(config \\ Mix.Project.config()) do
    if Keyword.get(config, :build_per_lockfile, false) and
         Keyword.get(config, :build_per_lockfile_hint, true) do
      do_print_status(config)
    end

    :ok
  end

  defp do_print_status(config) do
    hashed = hashed_build_dirs(config)

    case hashed do
      [] ->
        :ok

      _ ->
        total =
          hashed
          |> Enum.map(&cached_size(&1, config))
          |> Enum.sum()

        count = length(hashed)
        keep = Keyword.get(config, :build_per_lockfile_keep, :infinity)

        suffix =
          case keep do
            :infinity ->
              ~s(run "mix deps.clean --include-branches" to prune)

            n when count > n ->
              ~s(keeping #{n} newest, run "mix deps.clean --include-branches" to prune all)

            _ ->
              ~s(within keep limit of #{keep})
          end

        noun = if count == 1, do: "build", else: "builds"

        Mix.shell().info(
          "* #{count} cached lockfile #{noun} (#{format_bytes(total)} total) — #{suffix}"
        )
    end
  end

  @doc """
  Formats a byte count as a human-readable string (B/KB/MB/GB).
  """
  @spec format_bytes(non_neg_integer()) :: String.t()
  def format_bytes(bytes) when is_integer(bytes) and bytes >= 0 do
    cond do
      bytes < 1024 -> "#{bytes} B"
      bytes < 1024 * 1024 -> "#{format_float(bytes / 1024, 1)} KB"
      bytes < 1024 * 1024 * 1024 -> "#{format_float(bytes / 1024 / 1024, 1)} MB"
      true -> "#{format_float(bytes / 1024 / 1024 / 1024, 2)} GB"
    end
  end

  defp format_float(num, precision) do
    :erlang.float_to_binary(num, decimals: precision)
  end

  ## Helpers

  defp read_sentinel(config) do
    path = Path.join([canonical_build_path(config), ".mix", @sentinel_basename])

    case File.read(path) do
      {:ok, contents} -> String.trim(contents)
      _ -> nil
    end
  end

  # Single source of truth lives in Mix.Project. We delegate to keep the
  # two callers in lockstep — drift between them caused a `Path.expand`
  # mismatch in an earlier draft of this module.
  defp canonical_build_path(config) do
    Mix.Project.canonical_build_path(config)
  end

  defp size_cache_file(build_path) do
    Path.join([build_path, ".mix", "build_size_bytes"])
  end

  # The size cache is fresh if the cache file is at least as new as the
  # root project's compile manifest inside this build dir. Compile writes
  # to that manifest on every successful build, so any change to the
  # build's content will invalidate the cache via this comparison.
  defp size_cache_fresh?(build_path, size_file, config) do
    with {:ok, %{mtime: cache_mtime}} <- File.stat(size_file, time: :posix) do
      manifest = root_compile_manifest(build_path, config)

      case File.stat(manifest, time: :posix) do
        {:ok, %{mtime: manifest_mtime}} -> cache_mtime >= manifest_mtime
        # Manifest absent (dir was seeded but never compiled into) — accept
        # the cached size as-is.
        _ -> true
      end
    else
      _ -> false
    end
  end

  # Returns the POSIX timestamp of the dir's last successful root-project
  # compile (which writes its compile manifest). Falls back to the dir's
  # own mtime, then to `:unknown` if neither stat succeeds. We use an
  # atom rather than `0` so a directory with mtime exactly at the Unix
  # epoch (rare but reproducible: `touch -t 197001010000 ...`) doesn't
  # collide with the "couldn't read" sentinel.
  defp last_used_mtime(build_path, config) do
    manifest = root_compile_manifest(build_path, config)

    case File.stat(manifest, time: :posix) do
      {:ok, %{mtime: mtime}} ->
        mtime

      _ ->
        case File.stat(build_path, time: :posix) do
          {:ok, %{mtime: mtime}} -> mtime
          _ -> :unknown
        end
    end
  end

  # `:unknown` sorts as "oldest" (atoms compare greater than integers in
  # Erlang term order, so we map it to a sentinel low integer for sorting).
  defp mtime_for_sort(:unknown), do: -1
  defp mtime_for_sort(mtime) when is_integer(mtime), do: mtime

  defp root_compile_manifest(build_path, config) do
    app = config[:app] || :unknown
    Path.join([build_path, "lib", to_string(app), ".mix", "compile.elixir"])
  end

  defp walk_dir_size(path) do
    case File.ls(path) do
      {:ok, entries} ->
        Enum.reduce(entries, 0, fn entry, acc ->
          full = Path.join(path, entry)

          cond do
            # Don't count our own size-cache sentinel — it would otherwise
            # change the reported size on every refresh, defeating caching.
            entry == "build_size_bytes" ->
              acc

            true ->
              case File.stat(full) do
                {:ok, %{type: :directory}} -> acc + walk_dir_size(full)
                {:ok, %{type: :regular, size: size}} -> acc + size
                _ -> acc
              end
          end
        end)

      _ ->
        0
    end
  end

  defp format_age(:unknown), do: "unknown"

  defp format_age(mtime_posix) when is_integer(mtime_posix) do
    seconds = max(System.system_time(:second) - mtime_posix, 0)

    cond do
      seconds < 60 -> "#{seconds}s ago"
      seconds < 3600 -> "#{div(seconds, 60)}m ago"
      seconds < 86_400 -> "#{div(seconds, 3600)}h ago"
      true -> "#{div(seconds, 86_400)}d ago"
    end
  end

  # Picks the build dir most likely to contain artifacts compatible with
  # the new lockfile. Uses the same `last_used_mtime` metric as `prune_to/2`
  # so seeding and pruning agree on which dirs are "freshest" — an earlier
  # version disagreed (one used dir mtime, the other manifest mtime) and
  # could seed from a dir that prune would later target as oldest.
  defp find_seed_source(target_path, config) do
    canonical = canonical_build_path(config)

    candidates =
      [canonical | hashed_build_dirs(config)]
      |> Enum.uniq()
      |> Enum.reject(&(&1 == target_path))
      |> Enum.filter(&File.dir?/1)

    candidates
    |> Enum.map(fn path -> {path, last_used_mtime(path, config)} end)
    |> Enum.sort_by(fn {_path, mtime} -> mtime_for_sort(mtime) end, :desc)
    |> case do
      [{path, _} | _] -> path
      [] -> nil
    end
  end
end
