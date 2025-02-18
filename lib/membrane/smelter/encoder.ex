defmodule Membrane.Smelter.Encoder do
  @moduledoc false

  defmodule FFmpegH264 do
    @moduledoc """
    Options for H264 encoder from FFmpeg.
    """

    @typedoc """
    Encoder preset. See [FFmpeg docs](https://trac.ffmpeg.org/wiki/Encode/H.264#Preset)
    to learn more.
    """
    @type encoder_preset ::
            :ultrafast
            | :superfast
            | :veryfast
            | :faster
            | :fast
            | :medium
            | :slow
            | :slower
            | :veryslow
            | :placebo

    @typedoc """
    Raw FFmpeg encoder options. See [docs](https://ffmpeg.org/ffmpeg-codecs.html) for more.
    """
    @type ffmpeg_options :: %{(String.t() | atom()) => String.t()} | nil

    defstruct preset: :fast, ffmpeg_options: nil

    @type t :: %__MODULE__{
            preset: encoder_preset(),
            ffmpeg_options: ffmpeg_options()
          }
  end

  defimpl Jason.Encoder, for: FFmpegH264 do
    @spec encode(FFmpegH264.t(), Jason.Encode.opts()) :: iodata
    def encode(value, opts) do
      Jason.Encode.map(
        Map.take(value, [:preset, :ffmpeg_options]) |> Map.put(:type, :ffmpeg_h264),
        opts
      )
    end
  end

  defmodule Opus do
    @moduledoc """
    Options for OPUS encoder.
    """

    @typedoc """
    Encoder preset.
    """
    @type encoder_preset :: :quality | :voip | :lowest_latency

    @type channels :: :stereo | :mono

    @enforce_keys [:channels]
    defstruct @enforce_keys ++ [preset: :voip]

    @type t :: %__MODULE__{
            preset: encoder_preset(),
            channels: channels()
          }
  end

  defimpl Jason.Encoder, for: Opus do
    @spec encode(Opus.t(), Jason.Encode.opts()) :: iodata
    def encode(value, opts) do
      Jason.Encode.map(
        Map.take(value, [:preset, :channels]) |> Map.put(:type, :opus),
        opts
      )
    end
  end
end
