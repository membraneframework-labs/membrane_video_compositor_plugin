defmodule OfflineProcessing do
  @moduledoc false

  use Membrane.Pipeline

  require Membrane.Logger

  alias Membrane.Smelter
  alias Membrane.Smelter.Request

  @video_output_id "video_output_1"
  @audio_output_id "audio_output_1"
  @shader_id "shader_1"
  @output_width 1280
  @output_height 720
  @shader_path "./lib/example_shader.wgsl"
  @output_file "samples/offline_processing_output.mp4"

  @impl true
  def handle_init(_ctx, %{server_setup: server_setup, sample_path: sample_path}) do
    spec = [
      child(:file_source, %Membrane.File.Source{location: sample_path})
      |> child(:mp4_demuxer, Membrane.MP4.Demuxer.ISOM),
      child(:smelter, %Smelter{
        framerate: {30, 1},
        server_setup: server_setup,
        composing_strategy: :offline_processing,
        init_requests: [
          register_shader_request_body()
        ]
      })
      |> via_out(Pad.ref(:video_output, @video_output_id),
        options: [
          encoder: %Smelter.Encoder.FFmpegH264{
            preset: :ultrafast
          },
          width: @output_width,
          height: @output_height,
          send_eos_when: :all_inputs,
          initial: %{
            root:
              scene([
                %{type: :input_stream, input_id: "video_input_0", id: "child_0"}
              ])
          }
        ]
      )
      |> child(:output_parser, %Membrane.H264.Parser{
        generate_best_effort_timestamps: %{framerate: {30, 1}},
        output_stream_structure: :avc1
      })
      |> child(:muxer, Membrane.MP4.Muxer.ISOM)
      |> child(:sink, %Membrane.File.Sink{location: @output_file}),
      get_child(:smelter)
      |> via_out(Pad.ref(:audio_output, @audio_output_id),
        options: [
          encoder: %Smelter.Encoder.Opus{
            channels: :stereo
          },
          send_eos_when: :all_inputs,
          initial: %{
            inputs: [
              %{input_id: "audio_input_0", volume: 0.2}
            ]
          }
        ]
      )
      |> child(:opus_output_parser, Membrane.Opus.Parser)
      |> get_child(:muxer)
    ]

    {[spec: spec], %{registered_compositor_streams: 0}}
  end

  @impl true
  def handle_setup(_ctx, state) do
    schedule_scene_update_1 =
      %Request.UpdateVideoOutput{
        output_id: @video_output_id,
        root:
          scene([
            %{type: :input_stream, input_id: "video_input_0", id: "child_0"},
            %{type: :input_stream, input_id: "video_input_0", id: "child_2"}
          ]),
        schedule_time: Membrane.Time.seconds(10)
      }

    schedule_scene_update_2 = %Request.UpdateVideoOutput{
      output_id: @video_output_id,
      root:
        scene([
          %{type: :input_stream, input_id: "video_input_0", id: "child_0"},
          %{type: :input_stream, input_id: "video_input_0", id: "child_1"},
          %{type: :input_stream, input_id: "video_input_0", id: "child_2"}
        ]),
      schedule_time: Membrane.Time.seconds(20)
    }

    schedule_audio_update = %Request.UpdateAudioOutput{
      output_id: @audio_output_id,
      inputs: [
        %{input_id: "audio_input_0"}
      ],
      schedule_time: Membrane.Time.seconds(30)
    }

    {[
       notify_child: {:smelter, schedule_scene_update_1},
       notify_child: {:smelter, schedule_scene_update_2},
       notify_child: {:smelter, schedule_audio_update}
     ], state}
  end

  @impl true
  def handle_child_notification(
        {:new_tracks, tracks},
        :mp4_demuxer,
        _membrane_ctx,
        state
      ) do
    spec =
      tracks
      |> Enum.map(fn {track_id, stream_format} ->
        case stream_format do
          %Membrane.H264{} ->
            get_child(:mp4_demuxer)
            |> via_out(Pad.ref(:output, track_id))
            |> child(:mp4_input_parser, %Membrane.H264.Parser{
              output_alignment: :nalu,
              output_stream_structure: :annexb,
              generate_best_effort_timestamps: %{framerate: {30, 1}}
            })
            |> via_in(Pad.ref(:video_input, "video_input_0"),
              options: [
                offset: Membrane.Time.seconds(5),
                required: true
              ]
            )
            |> get_child(:smelter)

          %Membrane.AAC{sample_rate: sample_rate, channels: channels} ->
            get_child(:mp4_demuxer)
            |> via_out(Pad.ref(:output, track_id))
            |> child(:aac_parser, Membrane.AAC.Parser)
            |> child(:aac_decoder, Membrane.AAC.FDK.Decoder)
            |> child(:converter, %Membrane.FFmpeg.SWResample.Converter{
              input_stream_format: %Membrane.RawAudio{
                channels: channels,
                sample_format: :s16le,
                sample_rate: sample_rate
              },
              output_stream_format: %Membrane.RawAudio{
                channels: 2,
                sample_format: :s16le,
                sample_rate: 48_000
              }
            })
            |> child(:audio_encoder, %Membrane.Opus.Encoder{
              application: :audio,
              input_stream_format: %Membrane.RawAudio{
                channels: 2,
                sample_format: :s16le,
                sample_rate: 48_000
              }
            })
            |> child(:audio_parser, %Membrane.Opus.Parser{
              generate_best_effort_timestamps?: true
            })
            |> via_in(Pad.ref(:audio_input, "audio_input_0"),
              options: [
                offset: Membrane.Time.seconds(5),
                required: true
              ]
            )
            |> get_child(:smelter)
        end
      end)

    {[spec: spec], state}
  end

  @impl true
  def handle_child_notification(
        {:input_delivered, Pad.ref(pad_type, pad_id), ctx},
        :smelter,
        _membrane_ctx,
        state
      ) do
    state = %{state | registered_compositor_streams: state.registered_compositor_streams + 1}

    if state.registered_compositor_streams == 4 do
      # send start when all inputs are connected
      {[notify_child: {:smelter, :start_composing}], state}
    else
      {[], state}
    end
  end

  @impl true
  def handle_child_notification(
        {:output_registered, Pad.ref(pad_type, pad_id), ctx},
        :smelter,
        _membrane_ctx,
        state
      ) do
    state = %{state | registered_compositor_streams: state.registered_compositor_streams + 1}

    if state.registered_compositor_streams == 4 do
      # send start when all inputs are connected
      {[notify_child: {:smelter, :start_composing}], state}
    else
      {[], state}
    end
  end

  @impl true
  def handle_child_notification(
        {:request_result, request, {:ok, result}},
        :smelter,
        _membrane_ctx,
        state
      ) do
    Membrane.Logger.debug(
      "Smelter request succeeded\nRequest: #{inspect(request)}\nResult: #{inspect(result)}"
    )

    {[], state}
  end

  @impl true
  def handle_child_notification(
        {:request_result, request,
         {:error, %Req.Response{status: response_code, body: response_body}}},
        :smelter,
        _membrane_ctx,
        state
      ) do
    if response_code != 200 do
      raise """
      Smelter request failed:
      Request: #{inspect(request)}.
      Response code: #{response_code}.
      Response body: #{inspect(response_body)}.
      """
    end

    {[], state}
  end

  @impl true
  def handle_child_notification(notification, child, _ctx, state) do
    Membrane.Logger.debug(
      "Received notification: #{inspect(notification)} from child: #{inspect(child)}."
    )

    {[], state}
  end

  @impl true
  def handle_element_end_of_stream(:sink, _pad_ref, _context, state) do
    {[terminate: :normal], state}
  end

  @impl true
  def handle_element_end_of_stream(element, pad_ref, _context, state) do
    {[], state}
  end

  @spec scene(any()) :: map()
  defp scene(children) do
    %{
      type: :shader,
      shader_id: @shader_id,
      resolution: %{
        width: @output_width,
        height: @output_height
      },
      children: [
        %{
          id: "tiles_0",
          type: :tiles,
          width: @output_width,
          height: @output_height,
          background_color: "#000088FF",
          transition: %{
            duration_ms: 300
          },
          margin: 10,
          children: children
        }
      ]
    }
  end

  defp register_shader_request_body() do
    %Request.RegisterShader{
      shader_id: @shader_id,
      source: File.read!(@shader_path)
    }
  end
end

Utils.FFmpeg.generate_sample_video()
server_setup = Utils.SmelterServer.server_setup({30, 1})

{:ok, supervisor, _pid} =
  Membrane.Pipeline.start_link(OfflineProcessing, %{
    server_setup: server_setup,
    sample_path: "samples/test.mp4"
  })

require Membrane.Logger

Process.monitor(supervisor)

receive do
  msg -> Membrane.Logger.info("Supervisor finished: #{inspect(msg)}")
end
