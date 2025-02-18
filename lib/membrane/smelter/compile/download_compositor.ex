defmodule Mix.Tasks.Compile.DownloadCompositor do
  @moduledoc false
  # Downloads Smelter binaries.

  use Mix.Task
  require Membrane.Logger

  @lc_version "v0.4.0"

  @impl Mix.Task
  def run(_args) do
    case system_architecture() do
      {:ok, architecture} ->
        ensure_downloaded(lc_app_directory(architecture), lc_app_url(architecture))
        :ok

      :error ->
        :ok
    end
  end

  @spec ensure_downloaded(String.t(), String.t()) :: nil
  defp ensure_downloaded(app_directory, url) do
    lock_path = app_directory |> Path.join(".lock")

    unless File.exists?(lock_path) do
      File.mkdir_p!(app_directory)
      Membrane.Logger.info("Downloading Smelter binary")

      tmp_path = :code.priv_dir(:membrane_smelter_plugin) |> Path.join("tmp")
      File.mkdir_p!(tmp_path)

      wget_res_path = Path.join(tmp_path, "smelter")
      MuonTrap.cmd("wget", ["-O", wget_res_path, url])
      MuonTrap.cmd("tar", ["-xvf", wget_res_path, "-C", app_directory])
      File.rm_rf!(wget_res_path)
      File.touch!(lock_path)
    end
  end

  @spec lc_app_path() :: {:ok, String.t()} | :error
  def lc_app_path() do
    case system_architecture() do
      {:ok, arch} ->
        {:ok, Path.join(lc_app_directory(arch), "smelter/smelter")}

      :error ->
        :error
    end
  end

  @spec lc_app_url(String.t()) :: String.t()
  def lc_app_url(architecture) do
    "https://github.com/software-mansion/smelter/releases/download/#{@lc_version}/smelter_#{architecture}.tar.gz"
  end

  defp lc_app_directory(architecture) do
    :code.priv_dir(:membrane_smelter_plugin)
    |> Path.join("#{@lc_version}/#{architecture}")
  end

  @spec system_architecture() :: {:ok, String.t()} | :error
  defp system_architecture() do
    system =
      case :os.type() do
        {:unix, :darwin} -> :darwin
        {:unix, :linux} -> :linux
        os_type -> os_type
      end

    arch = cpu_architecture()

    case {system, arch} do
      {:linux, :x86} ->
        {:ok, "linux_x86_64"}

      {:linux, :aarch64} ->
        {:ok, "linux_aarch64"}

      {:darwin, :x86} ->
        {:ok, "darwin_x86_64"}

      {:darwin, :aarch64} ->
        {:ok, "darwin_aarch64"}

      {system, arch} ->
        Membrane.Logger.warning("Unsupported platform: #{system} #{arch}")
        :error
    end
  end

  @spec cpu_architecture() :: :aarch64 | :x86 | String.t()
  defp cpu_architecture() do
    system_architecture = :erlang.system_info(:system_architecture) |> to_string()

    cond do
      Regex.match?(~r/aarch64/, system_architecture) ->
        :aarch64

      Regex.match?(~r/x86_64/, system_architecture) ->
        :x86

      true ->
        system_architecture
    end
  end
end
