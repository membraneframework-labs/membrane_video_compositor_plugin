defmodule Membrane.Smelter.Examples.Mixfile do
  use Mix.Project

  @version "0.7.0"

  def project do
    [
      app: :membrane_smelter_plugin_examples,
      version: @version,
      elixir: "~> 1.13",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      dialyzer: dialyzer()
    ]
  end

  def application do
    [
      extra_applications: []
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib", "test"]

  defp deps do
    [
      # Membrane
      {:membrane_core, "~> 1.0"},
      {:membrane_smelter_plugin, path: ".."},
      # VC API requests
      {:req, "~> 0.4.0"},
      # Examples
      {:membrane_file_plugin, "~> 0.17.0"},
      {:membrane_realtimer_plugin, "~> 0.9.0"},
      {:membrane_sdl_plugin, "~> 0.18.5"},
      {:membrane_h26x_plugin, "~> 0.10.1"},
      {:membrane_h264_ffmpeg_plugin, "~> 0.32.0"},
      {:membrane_hackney_plugin, "~> 0.11.0"},
      {:membrane_mp4_plugin, "~> 0.34.2"},
      {:membrane_portaudio_plugin, "~> 0.19.2"},
      {:membrane_ogg_plugin, "~> 0.3.0"},
      {:membrane_ffmpeg_swresample_plugin, "~> 0.19.2"},
      {:membrane_aac_plugin, "~> 0.18.1"},
      {:membrane_aac_fdk_plugin, "~> 0.18.8"},
      # Dev
      {:ex_doc, ">= 0.0.0", only: :dev, runtime: false},
      {:dialyxir, ">= 0.0.0", only: :dev, runtime: false},
      {:credo, ">= 0.0.0", only: :dev, runtime: false}
    ]
  end

  defp dialyzer() do
    opts = [
      flags: [:error_handling],
      plt_add_apps: [:mix]
    ]

    if System.get_env("CI") == "true" do
      # Store PLTs in cacheable directory for CI
      [plt_local_path: "priv/plts", plt_core_path: "priv/plts"] ++ opts
    else
      opts
    end
  end
end
