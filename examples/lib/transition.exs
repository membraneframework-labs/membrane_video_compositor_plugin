defmodule TransitionPipeline do
  @moduledoc false

  use Membrane.Pipeline

  require Membrane.Logger

  alias Membrane.Smelter
  alias Membrane.Smelter.{Context, Encoder, OutputOptions, Request}

  @output_width 1280
  @output_height 720
  @output_id "output"
  @rescaler_id "rescaler"

  @impl true
  def handle_init(_ctx, %{sample_path: sample_path, server_setup: server_setup}) do
    spec =
      child(:smelter, %Membrane.Smelter{
        framerate: {30, 1},
        server_setup: server_setup
      })
      |> via_out(Pad.ref(:video_output, @output_id),
        options: [
          encoder: %Encoder.FFmpegH264{
            preset: :ultrafast
          },
          width: @output_width,
          height: @output_height,
          initial: %{root: %{type: :view}}
        ]
      )
      |> child(:output_parser, Membrane.H264.Parser)
      |> child(:output_decoder, Membrane.H264.FFmpeg.Decoder)
      |> child(:sdl_player, Membrane.SDL.Player)

    {[spec: spec], %{sample_path: sample_path}}
  end

  @impl true
  def handle_setup(_ctx, state) do
    Process.send_after(self(), {:add_input, "input_0"}, 1000)
    Process.send_after(self(), {:add_input, "input_1"}, 5000)

    {[], state}
  end

  @impl true
  def handle_child_notification(
        {:input_registered, Pad.ref(_pad_type, input_id), lc_ctx},
        :smelter,
        _ctx,
        state
      ) do
    request =
      case input_id do
        "input_0" ->
          %Request.UpdateVideoOutput{
            output_id: @output_id,
            root: single_input_scene("input_0")
          }

        "input_1" ->
          %Request.UpdateVideoOutput{
            output_id: @output_id,
            root: double_inputs_scene("input_0", "input_1")
          }
      end

    {[
       {:notify_child, {:smelter, request}}
     ], state}
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
      Request: `#{inspect(request)}.
      Response code: #{response_code}.
      Response body: #{inspect(response_body)}.
      """
    end

    {[], state}
  end

  @impl true
  def handle_child_notification(_notification, _child, _ctx, state) do
    {[], state}
  end

  @impl true
  def handle_info(
        {:add_input, input_id},
        _ctx,
        state = %{sample_path: sample_path}
      ) do
    spec =
      child({:video_src, input_id}, %Membrane.File.Source{
        location: sample_path
      })
      |> child({:input_parser, input_id}, %Membrane.H264.Parser{
        output_alignment: :nalu,
        generate_best_effort_timestamps: %{framerate: {30, 1}}
      })
      |> child({:realtimer, input_id}, Membrane.Realtimer)
      |> via_in(Pad.ref(:video_input, input_id))
      |> get_child(:smelter)

    {[spec: spec], state}
  end

  defp single_input_scene(input_id) do
    %{
      type: :view,
      children: [
        %{
          type: :rescaler,
          mode: :fit,
          id: @rescaler_id,
          top: 0,
          right: 0,
          width: @output_width,
          height: @output_height,
          transition: %{
            duration_ms: 1000
          },
          child: %{
            type: :input_stream,
            input_id: input_id
          }
        }
      ]
    }
  end

  defp double_inputs_scene(first_input_id, second_input_id) do
    %{
      type: :view,
      children: [
        %{
          type: :rescaler,
          mode: :fit,
          child: %{
            type: :input_stream,
            input_id: second_input_id
          }
        },
        %{
          type: :rescaler,
          mode: :fit,
          id: @rescaler_id,
          top: 10,
          right: 10,
          width: div(@output_width, 3),
          height: div(@output_height, 3),
          transition: %{
            duration_ms: 1000
          },
          child: %{
            type: :input_stream,
            input_id: first_input_id
          }
        }
      ]
    }
  end
end

Utils.FFmpeg.generate_sample_video()

server_setup = Utils.SmelterServer.server_setup({30, 1})

{:ok, _supervisor, _pid} =
  Membrane.Pipeline.start_link(TransitionPipeline, %{
    sample_path: "samples/testsrc.h264",
    server_setup: server_setup
  })

Process.sleep(:infinity)
