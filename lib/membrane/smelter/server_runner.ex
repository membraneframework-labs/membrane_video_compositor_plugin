defmodule Membrane.Smelter.ServerRunner do
  @moduledoc false

  require Membrane.Logger

  alias Membrane.Smelter
  alias Membrane.Smelter.ApiClient

  @local_host {127, 0, 0, 1}

  @spec ensure_server_started(Smelter.t(), Membrane.UtilitySupervisor.t()) ::
          {:ok, {:inet.ip_address(), :inet.port_number()}, pid() | nil}
  def ensure_server_started(opt, utility_supervisor) do
    {framerate_num, framerate_den} = opt.framerate
    framerate_str = "#{framerate_num}/#{framerate_den}"
    instance_id = "smelter_#{:rand.uniform(1_000_000_000)}"

    env = %{
      "SMELTER_INSTANCE_ID" => instance_id,
      "SMELTER_OFFLINE_PROCESSING_ENABLE" =>
        to_string(opt.composing_strategy == :offline_processing),
      "SMELTER_OUTPUT_FRAMERATE" => framerate_str,
      "SMELTER_STREAM_FALLBACK_TIMEOUT_MS" =>
        to_string(Membrane.Time.as_milliseconds(opt.stream_fallback_timeout, :round))
    }

    case opt.server_setup do
      :start_locally ->
        path =
          case Mix.Tasks.Compile.DownloadCompositor.lc_app_path() do
            {:ok, path} ->
              path

            :error ->
              raise """
              Smelter prebuilds are not available for this platform. Start Smelter bin
              with "server_setup: {:start_locally, smelter_binary_path}" to provide your own
              executable.
              """
          end

        {:ok, lc_port, server_pid} =
          start_server(path, opt.api_port, env, instance_id, utility_supervisor)

        lc_address = {@local_host, lc_port}
        {:ok, lc_address, server_pid}

      {:start_locally, path} ->
        {:ok, lc_port, server_pid} =
          start_server(path, opt.api_port, env, instance_id, utility_supervisor)

        lc_address = {@local_host, lc_port}
        {:ok, lc_address, server_pid}

      :already_started ->
        with {_start_, _end} <- opt.api_port do
          raise "Exact api_port is required when server_setup is set to :already_started"
        end

        lc_address = {@local_host, opt.api_port}
        {:ok, lc_address, nil}

      {:already_started, ip_or_hostname} ->
        with {_start_, _end} <- opt.api_port do
          raise "Exact api_port is required when server_setup is set to {:already_started, ip}"
        end

        ip_address = ensure_ip_address_resolved(ip_or_hostname)
        lc_address = {ip_address, opt.api_port}
        {:ok, lc_address, nil}
    end
  end

  defp ensure_ip_address_resolved(ip_or_hostname) do
    cond do
      :inet.is_ipv4_address(ip_or_hostname) ->
        ip_or_hostname

      is_atom(ip_or_hostname) ->
        ip_or_hostname |> get_host_by_name!()

      is_binary(ip_or_hostname) ->
        ip_or_hostname |> to_charlist() |> get_host_by_name!()
    end
  end

  defp get_host_by_name!(hostname) do
    with {:ok, {:hostent, _hostname, _aliases, :inet, 4, ips}} <-
           :inet.gethostbyname(hostname, :inet),
         ipv4 when ipv4 != nil <- Enum.find(ips, &:inet.is_ipv4_address/1) do
      ipv4
    else
      nil ->
        raise """
        :inet.gethostbyname(#{inspect(hostname)}) didn't return any IPv4 address. \
        Retuned addresses are: #{:inet.gethostbyname(hostname, :inet) |> elem(1) |> elem(5) |> inspect()}
        """

      {:error, _reason} = error ->
        raise """
        :inet.gethostbyname(#{inspect(hostname)}) returned #{inspect(error)} instead of \
        {:ok, hostnet_record} tuple.
        """
    end
  end

  @spec start_server(
          String.t(),
          :inet.port_number() | Smelter.port_range(),
          map(),
          String.t(),
          Membrane.UtilitySupervisor.t()
        ) ::
          {:ok, :inet.port_number(), pid()} | {:error, err :: String.t()}
  defp start_server(bin_path, port_or_port_range, env, instance_id, utility_supervisor) do
    {port_lower_bound, port_upper_bound} =
      case port_or_port_range do
        {start, endd} -> {start, endd}
        exact -> {exact, exact}
      end

    unless File.exists?(bin_path) do
      raise "Smelter binary is not available under search path: \"#{bin_path}\"."
    end

    port_lower_bound..port_upper_bound
    |> Enum.shuffle()
    |> Enum.reduce_while(
      {:error, "Failed to start a Smelter server on any of the ports."},
      fn port, err ->
        try_starting_on_port(port, err, env, bin_path, instance_id, utility_supervisor)
      end
    )
  end

  @spec try_starting_on_port(
          :inet.port_number(),
          String.t(),
          map(),
          String.t(),
          String.t(),
          Membrane.UtilitySupervisor.t()
        ) ::
          {:halt, {:ok, :inet.port_number()}} | {:cont, err :: String.t()}
  defp try_starting_on_port(port, err, env, bin_path, instance_id, utility_supervisor) do
    Membrane.Logger.debug("Trying to launch Smelter on port: #{port}")

    case start_on_port(port, env, bin_path, instance_id, utility_supervisor) do
      {:ok, pid} -> {:halt, {:ok, port, pid}}
      :error -> {:cont, err}
    end
  end

  @spec start_on_port(
          :inet.port_number(),
          map(),
          String.t(),
          String.t(),
          Membrane.UtilitySupervisor.t()
        ) :: {:ok, pid()} | :error
  defp start_on_port(lc_port, env, bin_path, instance_id, utility_supervisor) do
    env =
      Map.merge(env, %{
        "SMELTER_API_PORT" => to_string(lc_port),
        "SMELTER_WEB_RENDERER_ENABLE" => "false"
      })

    spec =
      Supervisor.child_spec(
        {MuonTrap.Daemon, [bin_path, _args = [], [env: env, log_output: :info]]},
        id: instance_id,
        restart: :temporary
      )

    {:ok, pid} = Membrane.UtilitySupervisor.start_child(utility_supervisor, spec)

    case wait_for_lc_startup(lc_port, pid, instance_id) do
      :started ->
        {:ok, pid}

      :not_started ->
        Process.exit(pid, :kill)
        :error
    end
  end

  @spec wait_for_lc_startup(:inet.port_number(), pid(), String.t()) :: :started | :not_started
  defp wait_for_lc_startup(lc_port, pid, instance_id) do
    0..300
    |> Enum.reduce_while(:not_started, fn _i, _acc ->
      Process.sleep(100)

      with {:is_alive, true} <- {:is_alive, Process.alive?(pid)},
           {:ok, response} <- ApiClient.get_status({@local_host, lc_port}) do
        if response.body["instance_id"] == instance_id do
          {:halt, :started}
        else
          {:halt, :not_started}
        end
      else
        {:is_alive, false} ->
          {:halt, :not_started}

        {:error, _reason} ->
          {:cont, :not_started}
      end
    end)
  end
end
