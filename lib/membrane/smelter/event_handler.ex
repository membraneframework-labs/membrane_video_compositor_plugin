defmodule Membrane.Smelter.EventHandler do
  @moduledoc false

  use WebSockex

  require Membrane.Logger
  require Membrane.Pad

  alias Membrane.Pad

  @spec start_link({{:inet.ip_address(), :inet.port_number()}, pid()}) ::
          {:ok, pid} | {:error, term}
  def start_link({lc_address, parent_pid}) do
    {lc_ip, lc_port} = lc_address
    lc_ip = lc_ip |> Tuple.to_list() |> Enum.join(".")

    WebSockex.start_link("ws://#{lc_ip}:#{lc_port}/ws", __MODULE__, %{parent_pid: parent_pid})
  end

  @impl true
  def handle_connect(_conn, state) do
    send(state.parent_pid, :websocket_connected)
    {:ok, state}
  end

  @impl true
  def handle_frame({:text, msg}, state) do
    {:ok, msg} = Jason.decode(msg)

    case msg_to_event(msg) do
      nil -> :ok
      event -> send(state.parent_pid, {:websocket_message, event})
    end

    {:ok, state}
  end

  @impl true
  def handle_frame({type, msg}, state) do
    Membrane.Logger.debug(
      "Unknown WebSocket message - Type: #{inspect(type)} -- Message: #{inspect(msg)}"
    )

    {:ok, state}
  end

  @impl true
  def handle_cast(_message, state) do
    {:ok, state}
  end

  @spec msg_to_event(any()) :: {any(), Pad.ref()} | nil
  defp msg_to_event(msg) do
    case msg do
      %{"type" => "VIDEO_INPUT_DELIVERED", "input_id" => input_id} ->
        {:input_delivered, Pad.ref(:video_input, input_id)}

      %{"type" => "VIDEO_INPUT_PLAYING", "input_id" => input_id} ->
        {:input_playing, Pad.ref(:video_input, input_id)}

      %{"type" => "VIDEO_INPUT_EOS", "input_id" => input_id} ->
        {:input_eos, Pad.ref(:video_input, input_id)}

      %{"type" => "AUDIO_INPUT_DELIVERED", "input_id" => input_id} ->
        {:input_delivered, Pad.ref(:audio_input, input_id)}

      %{"type" => "AUDIO_INPUT_PLAYING", "input_id" => input_id} ->
        {:input_playing, Pad.ref(:audio_input, input_id)}

      %{"type" => "AUDIO_INPUT_EOS", "input_id" => input_id} ->
        {:input_eos, Pad.ref(:audio_input, input_id)}

      # Membrane.Element.Action.end_of_stream() is send automatically by TCP plugin after TCP connection is closed.
      # Sending this message can be misleading, as TCP plugin may still process some data after this event is received.
      # Therefore, users should rely on Membrane EOS messages instead of this one.
      %{"type" => "OUTPUT_DONE", "output_id" => _output_id} ->
        nil

      _other ->
        nil
    end
  end
end
