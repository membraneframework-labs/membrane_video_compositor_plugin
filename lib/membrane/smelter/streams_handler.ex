defmodule Membrane.Smelter.StreamsHandler do
  @moduledoc false

  alias Membrane.Smelter
  alias Membrane.Smelter.{ApiClient, State}

  @spec register_video_input_stream(String.t(), map(), State.t()) ::
          {:ok, :inet.port_number()} | {:error, any()}
  def register_video_input_stream(pad_id, input_pad_opts, state) do
    body = %{
      type: :rtp_stream,
      transport_protocol: :tcp_server,
      port: input_pad_opts.port |> map_port,
      video: %{
        decoder: :ffmpeg_h264
      },
      required: input_pad_opts.required,
      offset_ms:
        case input_pad_opts.offset do
          nil -> nil
          offset -> Membrane.Time.as_milliseconds(offset, :round)
        end
    }

    encoded_id = URI.encode_www_form(pad_id)

    {:post, "/api/input/#{encoded_id}/register", body}
    |> ApiClient.send_request(state.lc_address)
    |> map_response
  end

  @spec register_audio_input_stream(String.t(), map(), State.t()) ::
          {:ok, :inet.port_number()} | {:error, any()}
  def register_audio_input_stream(pad_id, input_pad_opts, state) do
    body = %{
      type: :rtp_stream,
      transport_protocol: :tcp_server,
      port: input_pad_opts.port |> map_port,
      audio: %{
        decoder: :opus
      },
      required: input_pad_opts.required,
      offset_ms:
        case input_pad_opts.offset do
          nil -> nil
          offset -> Membrane.Time.as_milliseconds(offset, :round)
        end
    }

    encoded_id = URI.encode_www_form(pad_id)

    {:post, "/api/input/#{encoded_id}/register", body}
    |> ApiClient.send_request(state.lc_address)
    |> map_response
  end

  @spec register_video_output_stream(String.t(), map(), State.t()) ::
          {:ok, :inet.port_number()} | {:error, any()}
  def register_video_output_stream(pad_id, output_pad_opts, state) do
    body = %{
      type: :rtp_stream,
      transport_protocol: :tcp_server,
      port: output_pad_opts.port |> map_port,
      video: %{
        send_eos_when: map_eos_cond(output_pad_opts.send_eos_when),
        resolution: %{
          width: output_pad_opts.width,
          height: output_pad_opts.height
        },
        encoder: output_pad_opts.encoder,
        initial: output_pad_opts.initial
      }
    }

    encoded_id = URI.encode_www_form(pad_id)

    {:post, "/api/output/#{encoded_id}/register", body}
    |> ApiClient.send_request(state.lc_address)
    |> map_response
  end

  @spec register_audio_output_stream(String.t(), map(), State.t()) ::
          {:ok, :inet.port_number()} | {:error, any()}
  def register_audio_output_stream(pad_id, output_pad_opts, state) do
    body = %{
      type: :rtp_stream,
      transport_protocol: :tcp_server,
      port: output_pad_opts.port |> map_port,
      audio: %{
        send_eos_when: map_eos_cond(output_pad_opts.send_eos_when),
        encoder: output_pad_opts.encoder,
        initial: output_pad_opts.initial
      }
    }

    encoded_id = URI.encode_www_form(pad_id)

    {:post, "/api/output/#{encoded_id}/register", body}
    |> ApiClient.send_request(state.lc_address)
    |> map_response
  end

  @spec map_eos_cond(Smelter.send_eos_condition()) :: any()
  defp map_eos_cond(cond) do
    case cond do
      nil -> nil
      :any_input -> %{any_input: true}
      :all_inputs -> %{all_inputs: true}
      {:any_of, input_ids} -> %{any_of: input_ids}
      {:all_of, input_ids} -> %{all_of: input_ids}
    end
  end

  @spec map_port(Smelter.port_range() | :inet.port_number()) ::
          String.t() | :inet.port_number()
  defp map_port(port) do
    case port do
      {start, endd} -> "#{start}:#{endd}"
      exact_port -> exact_port
    end
  end

  defp map_response(response) do
    case response do
      {:ok, response} -> {:ok, response.body["port"]}
      {:error, err} -> {:error, err}
    end
  end
end
