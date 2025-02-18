defmodule Membrane.Smelter.RtcpByeSender do
  @moduledoc false

  use Membrane.Filter

  alias Membrane.{Buffer, RemoteStream, RTCP, RTP}

  def_options ssrc: [
                spec: non_neg_integer()
              ]

  def_input_pad :input,
    accepted_format: %RemoteStream{type: :packetized, content_format: RTP},
    flow_control: :auto

  def_output_pad :output,
    accepted_format: %RemoteStream{type: :packetized, content_format: RTP},
    flow_control: :auto

  @impl true
  def handle_init(_ctx, opt) do
    {[], %{ssrc: opt.ssrc}}
  end

  @impl true
  def handle_buffer(_pad, buffer, _ctx, state) do
    {[buffer: {:output, buffer}], state}
  end

  @impl true
  def handle_stream_format(_pad, stream_format, _ctx, state) do
    {[stream_format: {:output, stream_format}], state}
  end

  @impl true
  def handle_end_of_stream(_pad, _context, state) do
    packet = %RTCP.ByePacket{
      ssrcs: [state.ssrc],
      reason: "EOS"
    }

    {[
       buffer: {:output, %Buffer{payload: RTCP.Packet.serialize(packet)}},
       end_of_stream: :output
     ], state}
  end
end
