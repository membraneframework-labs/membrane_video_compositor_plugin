defmodule Membrane.Smelter.ApiClient do
  @moduledoc false

  require Membrane.Logger

  @type http_method :: :post | :get
  @type request :: {http_method(), path :: String.t(), body :: any()}

  @type request_result ::
          {:ok, Req.Response.t()}
          | {:error, {:response, Req.Response.t()}}
          | {:error, Exception.t()}

  defprotocol IntoRequest do
    @moduledoc false

    alias Membrane.Smelter.ApiClient

    @spec into_request(any()) :: ApiClient.request()
    def into_request(data)
  end

  @spec start_composing({:inet.ip_address(), :inet.port_number()}) :: request_result()
  def start_composing(lc_address) do
    {:post, "/api/start", %{}} |> send_request(lc_address)
  end

  @spec get_status({:inet.ip_address(), :inet.port_number()}) :: request_result()
  def get_status(lc_address) do
    {:get, "/status", nil} |> send_request(lc_address)
  end

  @spec send_request(request(), {:inet.ip_address(), :inet.port_number()}) :: request_result()
  def send_request(request, lc_address) do
    {lc_ip, lc_port} = lc_address
    lc_ip = lc_ip |> Tuple.to_list() |> Enum.join(".")

    {method, route, body} = request
    {:ok, _apps} = Application.ensure_all_started(:req)

    retry_delay_ms = fn retry_count -> retry_count * 100 end
    req = Req.new(base_url: "http://#{lc_ip}:#{lc_port}", retry_delay: retry_delay_ms)

    response =
      case method do
        :post -> Req.post(req, url: route, json: body)
        :get -> Req.get(req, url: route)
      end

    handle_request_result(response)
  end

  @spec handle_request_result({:ok, Req.Response.t()} | {:error, Exception.t()}) ::
          request_result()
  defp handle_request_result(req_result) do
    case req_result do
      {:ok, resp = %Req.Response{status: 200}} -> {:ok, resp}
      {:ok, resp} -> {:error, {:response, resp}}
      {:error, exception} -> {:error, exception}
    end
  end
end
