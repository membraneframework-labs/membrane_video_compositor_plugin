defmodule Membrane.VideoCompositor.Request do
  @moduledoc false

  require Membrane.Logger

  alias Membrane.VideoCompositor
  alias Membrane.VideoCompositor.OutputOptions

  @local_host_url "127.0.0.1"
  @type request_result ::
          {:ok, Req.Response.t()}
          | {:error_response_code, Req.Response.t()}
          | {:error, Exception.t()}

  @spec start_composing(:inet.port_number()) :: request_result()
  def start_composing(vc_port) do
    %{
      type: :start
    }
    |> send_request(vc_port)
  end

  @spec register_input_stream(
          VideoCompositor.input_id(),
          :inet.port_number(),
          :inet.port_number()
        ) ::
          request_result()
  def register_input_stream(input_id, input_port_number, vc_port) do
    %{
      type: :register,
      entity_type: :input_stream,
      input_id: "#{input_id}",
      port: input_port_number,
      video: %{
        codec: :h264
      }
    }
    |> send_request(vc_port)
  end

  @spec wait_for_frame_on_input(
          VideoCompositor.input_id(),
          :inet.port_number()
        ) :: request_result()
  def wait_for_frame_on_input(input_id, vc_port) do
    %{
      type: :query,
      query: :wait_for_next_frame,
      input_id: input_id
    }
    |> send_request(vc_port)
  end

  @spec unregister_input_stream(VideoCompositor.input_id(), :inet.port_number()) ::
          request_result()
  def unregister_input_stream(input_id, vc_port) do
    %{
      type: :unregister,
      entity_type: :input_stream,
      input_id: input_id
    }
    |> send_request(vc_port)
  end

  @spec unregister_output_stream(VideoCompositor.output_id(), :inet.port_number()) ::
          request_result()
  def unregister_output_stream(output_id, vc_port) do
    %{
      type: :unregister,
      entity_type: :output_stream,
      output_id: output_id
    }
    |> send_request(vc_port)
  end

  @spec register_output_stream(
          OutputOptions.t(),
          :inet.port_number(),
          :inet.port_number()
        ) :: request_result()
  def register_output_stream(output_opt, stream_port, vc_port) do
    %{
      type: :register,
      entity_type: :output_stream,
      output_id: output_opt.id,
      port: stream_port,
      ip: @local_host_url,
      resolution: %{
        width: output_opt.width,
        height: output_opt.height
      },
      encoder_preset: output_opt.encoder_preset
    }
    |> send_request(vc_port)
  end

  @spec send_request(VideoCompositor.request_body(), :inet.port_number()) ::
          request_result()
  def send_request(request_body, vc_port) do
    {:ok, _} = Application.ensure_all_started(:req)

    vc_port
    |> vc_api_url()
    |> Req.post(json: request_body)
    |> handle_request_result()
  end

  @spec get_status(:inet.port_number()) :: request_result()
  def get_status(vc_port) do
    {:ok, _} = Application.ensure_all_started(:req)

    "#{vc_url(vc_port)}/status"
    |> Req.get()
    |> handle_request_result()
  end

  @spec handle_request_result({:ok, Req.Response.t()} | {:error, Exception.t()}) ::
          request_result()
  defp handle_request_result(req_result) do
    case req_result do
      {:ok, resp = %Req.Response{status: 200}} -> {:ok, resp}
      {:ok, resp} -> {:error_response_code, resp}
      {:error, exception} -> {:error, exception}
    end
  end

  defp vc_url(vc_server_port) do
    "http://#{@local_host_url}:#{vc_server_port}"
  end

  defp vc_api_url(vc_server_port) do
    "#{vc_url(vc_server_port)}/--/api"
  end
end
