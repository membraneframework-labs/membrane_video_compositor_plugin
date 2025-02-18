defmodule Utils.SmelterServer do
  @moduledoc false

  # The same value as default in `api_port`.
  @smelter_port 8081

  @doc """
  If SMELTER_PATH env var exists start Smelter instance.
  Returns server_setup
  """
  @spec server_setup(Membrane.RawVideo.framerate()) ::
          {:start_locally, String.t()} | :already_started
  def server_setup(framerate) do
    case System.get_env("SMELTER_PATH") do
      nil ->
        :start_locally

      lc_location ->
        start_lc_server(lc_location, framerate)
    end
  end

  defp start_lc_server(lc_location, framerate) do
    true = File.exists?(lc_location)

    case File.dir?(lc_location) do
      true ->
        start_lc_server_with_cargo(lc_location, framerate)
        Process.sleep(3000)
        :already_started

      false ->
        {:start_locally, lc_location}
    end
  end

  defp start_lc_server_with_cargo(lc_directory_path, framerate) do
    {_, 0} =
      "cargo"
      |> MuonTrap.cmd([
        "build",
        "-r",
        "--no-default-features",
        "--manifest-path",
        Path.join(lc_directory_path, "Cargo.toml"),
        "--bin",
        "smelter"
      ])

    {framerate_num, framerate_den} = framerate
    framerate_str = "#{framerate_num}/#{framerate_den}"

    children = [
      {MuonTrap.Daemon,
       [
         "cargo",
         [
           "run",
           "-r",
           "--no-default-features",
           "--manifest-path",
           Path.join(lc_directory_path, "Cargo.toml"),
           "--bin",
           "smelter"
         ],
         [
           env: %{
             "SMELTER_API_PORT" => "#{@smelter_port}",
             "SMELTER_WEB_RENDERER_ENABLE" => "false",
             "SMELTER_OUTPUT_FRAMERATE" => framerate_str
           }
         ]
       ]}
    ]

    opts = [strategy: :one_for_one, name: Utils.SmelterServer]
    Supervisor.start_link(children, opts)
  end
end
