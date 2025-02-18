defmodule Membrane.Smelter.Context do
  @moduledoc """
  Context of Smelter. Specifies Smelter inputs and outputs.
  """

  require Membrane.Pad

  alias Membrane.Pad
  alias Membrane.Smelter

  defstruct video_inputs: [], audio_inputs: [], video_outputs: [], audio_outputs: []

  @typedoc """
  Context of Smelter. Specifies Smelter inputs and outputs.
  """
  @type t :: %__MODULE__{
          video_inputs: list(Smelter.input_id()),
          audio_inputs: list(Smelter.input_id()),
          video_outputs: list(Smelter.output_id()),
          audio_outputs: list(Smelter.output_id())
        }

  @doc false
  @spec add_stream(Pad.ref(), t()) :: t()
  def add_stream(Pad.ref(pad_type, id), ctx = %__MODULE__{}) do
    if !String.valid?(id) do
      raise """
        All Smelter pads need to be defined as `Pad.ref(pad_name, pad_id)`
        where `pad_id` is a string.
      """
    end

    # Don't optimize this with [%State.Input{...} | inputs]
    # Adding this at the beginning is O(1) instead of O(N),
    # but this way this list is always ordered by insert order.
    # Since this list should be small, preserving order with O(N) is better
    # (order is preserved in returned VC context, state is more consistent etc.)

    case pad_type do
      :video_input ->
        ensure_no_inputs_with_id(id, ctx)
        %__MODULE__{ctx | video_inputs: ctx.video_inputs ++ [id]}

      :audio_input ->
        ensure_no_inputs_with_id(id, ctx)
        %__MODULE__{ctx | audio_inputs: ctx.audio_inputs ++ [id]}

      :video_output ->
        ensure_no_outputs_with_id(id, ctx)
        %__MODULE__{ctx | video_outputs: [id | ctx.video_outputs]}

      :audio_output ->
        ensure_no_outputs_with_id(id, ctx)
        %__MODULE__{ctx | audio_outputs: [id | ctx.audio_outputs]}
    end
  end

  @doc false
  @spec remove_input(Smelter.input_id(), t()) :: t()
  def remove_input(input_id, ctx = %__MODULE__{audio_inputs: audio, video_inputs: video}) do
    audio = audio |> Enum.reject(fn id -> input_id == id end)
    video = video |> Enum.reject(fn id -> input_id == id end)
    %__MODULE__{ctx | audio_inputs: audio, video_inputs: video}
  end

  @doc false
  @spec remove_output(Smelter.output_id(), t()) :: t()
  def remove_output(output_id, ctx = %__MODULE__{audio_outputs: audio, video_outputs: video}) do
    audio = audio |> Enum.reject(fn id -> output_id == id end)
    video = video |> Enum.reject(fn id -> output_id == id end)
    %__MODULE__{ctx | audio_outputs: audio, video_outputs: video}
  end

  defp get_input(input_id, ctx) do
    ctx.audio_inputs |> Enum.find(fn id -> input_id == id end) ||
      ctx.video_inputs |> Enum.find(fn id -> input_id == id end)
  end

  defp ensure_no_inputs_with_id(input_id, ctx) do
    input = get_input(input_id, ctx)

    if input != nil do
      raise """
      You can only register one input at the time with a specific id. Input pad
      with id "#{input_id}" was already connected.
      """
    end
  end

  defp get_output(output_id, ctx) do
    ctx.audio_outputs |> Enum.find(fn id -> output_id == id end) ||
      ctx.video_outputs |> Enum.find(fn id -> output_id == id end)
  end

  defp ensure_no_outputs_with_id(output_id, ctx) do
    output = get_output(output_id, ctx)

    if output != nil do
      raise """
      You can only register one output at the time with a specific id. Output pad
      with id "#{output_id}" was already connected.
      """
    end
  end
end
