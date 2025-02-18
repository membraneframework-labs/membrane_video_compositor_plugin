defmodule Membrane.Smelter.VideoOutputProcessor do
  @moduledoc false
  # Forwards buffers and send specified output stream format.

  use Membrane.Filter

  def_options output_stream_format: [
                spec: Membrane.H264.t()
              ]

  def_input_pad :input,
    accepted_format: %Membrane.H264{alignment: :nalu, stream_structure: :annexb},
    availability: :on_request,
    flow_control: :auto

  def_output_pad :output,
    accepted_format: %Membrane.H264{alignment: :nalu, stream_structure: :annexb},
    flow_control: :auto

  @impl true
  def handle_init(_ctx, opt) do
    {[],
     %{
       output_stream_format: opt.output_stream_format
     }}
  end

  @impl true
  def handle_buffer(_pad, buffer, _ctx, state) do
    {[buffer: {:output, buffer}], state}
  end

  @impl true
  def handle_stream_format(_pad, _stream_format, _ctx, state) do
    {[stream_format: {:output, state.output_stream_format}], state}
  end

  @impl true
  def handle_event(:input, event, _ctx, state) do
    {[event: {:output, event}], state}
  end

  @impl true
  def handle_event(:output, %Membrane.KeyframeRequestEvent{}, _ctx, state) do
    {[notify_parent: :keyframe_request], state}
  end

  @impl true
  def handle_event(:output, event, _ctx, state) do
    {[event: {:input, event}], state}
  end
end

defmodule Membrane.Smelter.AudioOutputProcessor do
  @moduledoc false

  use Membrane.Filter
  alias Membrane.{Opus, RemoteStream}

  def_input_pad :input,
    accepted_format: %RemoteStream{type: :packetized, content_format: Opus},
    availability: :on_request,
    flow_control: :auto

  def_output_pad :output,
    accepted_format: %RemoteStream{type: :packetized, content_format: Opus},
    flow_control: :auto

  @impl true
  def handle_init(_ctx, _opt) do
    {[], %{}}
  end

  @impl true
  def handle_buffer(_pad, buffer, _ctx, state) do
    {[buffer: {:output, buffer}], state}
  end

  @impl true
  def handle_stream_format(_pad, stream_format, _ctx, state) do
    {[stream_format: {:output, stream_format}], state}
  end
end
