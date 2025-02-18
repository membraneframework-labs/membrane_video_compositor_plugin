defmodule DynamicOutputsPipeline do
  @moduledoc false

  # Every 5 seconds add new output stream. After 10 seconds from its creation
  # remove it.

  use Membrane.Pipeline

  require Membrane.Logger

  alias Membrane.Smelter
  alias Membrane.Smelter.{Context, Encoder, OutputOptions, Request}

  @output_width 1920
  @output_height 1080
  @layout_id "layout"

  @impl true
  def handle_init(_ctx, %{sample_path: sample_path, server_setup: server_setup}) do
    spec =
      child(:smelter, %Membrane.Smelter{
        framerate: {30, 1},
        server_setup: server_setup
      })

    0..5
    |> Enum.each(fn count ->
      delay_ms = 5_000 * count

      Process.send_after(
        self(),
        {:register_output, "output_#{count}"},
        delay_ms
      )
    end)

    0..10
    |> Enum.each(fn count ->
      delay_ms = 2_000 * count

      Process.send_after(
        self(),
        {:register_input, "input_#{count}"},
        delay_ms
      )
    end)

    {[spec: spec], %{sample_path: sample_path, smelter_ctx: %Smelter.Context{}}}
  end

  @impl true
  def handle_child_notification(
        {:output_registered, Pad.ref(_pad_type, output_id), smelter_ctx},
        :smelter,
        _ctx,
        state
      ) do
    Process.send_after(self(), {:remove_output, output_id}, 10_000)
    {[], %{state | smelter_ctx: smelter_ctx}}
  end

  @impl true
  def handle_child_notification(
        {:input_registered, input_id, smelter_ctx},
        :smelter,
        _ctx,
        state
      ) do
    actions =
      smelter_ctx.video_outputs
      |> Enum.map(fn output_id ->
        request =
          %Request.UpdateVideoOutput{
            output_id: output_id,
            root: scene(smelter_ctx, output_id)
          }

        {:notify_child, {:smelter, request}}
      end)

    {actions, %{state | smelter_ctx: smelter_ctx}}
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
  def handle_child_notification(notification, child, _ctx, state) do
    Membrane.Logger.debug(
      "Received notification: #{inspect(notification)} from child: #{inspect(child)}."
    )

    {[], state}
  end

  @impl true
  def handle_info({:register_input, input_id}, _ctx, state) do
    spec =
      child({:video_src, input_id}, %Membrane.File.Source{location: state.sample_path})
      |> child({:input_parser, input_id}, %Membrane.H264.Parser{
        output_alignment: :nalu,
        generate_best_effort_timestamps: %{framerate: {30, 1}}
      })
      |> child({:realtimer, input_id}, Membrane.Realtimer)
      |> via_in(Pad.ref(:video_input, input_id))
      |> get_child(:smelter)

    {[spec: spec], state}
  end

  @impl true
  def handle_info({:register_output, output_id}, _ctx, state) do
    links =
      get_child(:smelter)
      |> via_out(Pad.ref(:video_output, output_id),
        options: [
          encoder: %Encoder.FFmpegH264{
            preset: :ultrafast
          },
          width: @output_width,
          height: @output_height,
          initial: %{
            root: scene(state.smelter_ctx, output_id)
          }
        ]
      )
      |> child({:output_parser, output_id}, Membrane.H264.Parser)
      |> child({:output_decoder, output_id}, Membrane.H264.FFmpeg.Decoder)
      |> child({:sdl_player, output_id}, Membrane.SDL.Player)

    spec = {links, group: output_group_id(output_id)}

    {[spec: spec], state}
  end

  @impl true
  def handle_info({:remove_output, output_id}, _ctx, state) do
    {[remove_children: output_group_id(output_id)], state}
  end

  @spec scene(Smelter.Context.t(), Smelter.output_id()) :: map()
  defp scene(ctx, output_id) do
    %{
      id: "tile_#{output_id}",
      type: :tiles,
      padding: 10,
      transition: %{
        duration_ms: 300
      },
      children:
        ctx.video_inputs
        |> Enum.map(fn input_id ->
          %{type: :input_stream, input_id: input_id, id: "#{output_id}_#{input_id}"}
        end)
    }
  end

  defp output_group_id(output_id) do
    "output_group_#{output_id}"
  end
end

Utils.FFmpeg.generate_sample_video()

server_setup = Utils.SmelterServer.server_setup({30, 1})

{:ok, _supervisor, _pid} =
  Membrane.Pipeline.start_link(DynamicOutputsPipeline, %{
    sample_path: "samples/testsrc.h264",
    server_setup: server_setup
  })

Process.sleep(:infinity)
