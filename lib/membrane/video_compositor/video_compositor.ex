defmodule Membrane.VideoCompositor do
  @moduledoc """
  Membrane SDK for [VideoCompositor](https://github.com/membraneframework/video_compositor),
  used for dynamic, real-time video composition.

  This bin sends videos from input pads to VideoCompositor server via RTP and output composed videos received back.

  Inputs and outputs registration is automatic.
  In any time user can send `t:vc_request\0` to bin, which would be send to VideoCompositor app,
  to specify [scene](https://github.com/membraneframework/video_compositor/wiki/Main-concepts#scene),
  [register images](https://github.com/membraneframework/video_compositor/wiki/Api-%E2%80%90-renderers#image), 
  [shader](https://github.com/membraneframework/video_compositor/wiki/Api-%E2%80%90-renderers#shader) and
  any other request supported in VideoCompositor API.

  For more details, check out [VideoCompositor wiki](https://github.com/membraneframework/video_compositor/wiki/Main-concepts).
  """

  use Membrane.Bin

  require Membrane.Logger

  alias Membrane.{Pad, RTP, UDP}
  alias Membrane.VideoCompositor.{InputState, OutputState, Resolution, State}
  alias Membrane.VideoCompositor.Request, as: VcReq
  alias Rambo
  alias Req

  @type encoder_preset ::
          :ultrafast
          | :superfast
          | :veryfast
          | :faster
          | :fast
          | :medium
          | :slow
          | :slower
          | :veryslow
          | :placebo

  @type ip :: {non_neg_integer(), non_neg_integer(), non_neg_integer(), non_neg_integer()}
  @type port_number :: non_neg_integer()
  @type input_id :: String.t()
  @type output_id :: String.t()

  @type vc_request :: {:vc_request, map()}

  @local_host {127, 0, 0, 1}
  @udp_buffer_size 1024 * 1024

  def_options framerate: [
                spec: non_neg_integer(),
                description: "Stream format for the output video of the compositor"
              ],
              init_web_renderer?: [
                spec: boolean(),
                description:
                  "Enable web renderer support. If false, an attempt to register any transformation that is using a web renderer will fail.",
                default: true
              ],
              stream_fallback_timeout: [
                spec: Membrane.Time.t(),
                description:
                  "Timeout that defines when the compositor should switch to fallback on the input stream that stopped sending frames.",
                default: Membrane.Time.second()
              ],
              start_composing_strategy: [
                spec: :on_init | :on_message,
                description:
                  "Specifies when VideoCompositor starts composing frames.
                  In `:on_message` strategy, `:start_composing` message have to be send to start composing.",
                default: :on_init
              ],
              vc_server_port_number: [
                spec: non_neg_integer(),
                description:
                  "Port on which VC server should run. Port have to be unused. In case of running multiple VC elements, those values should be unique.",
                default: 8001
              ]

  def_input_pad :input,
    accepted_format: %Membrane.H264{alignment: :nalu, stream_structure: :annexb},
    availability: :on_request,
    options: [
      input_id: [
        spec: input_id(),
        description: "Input identifier."
      ]
    ]

  def_output_pad :output,
    accepted_format: %Membrane.H264{alignment: :nalu, stream_structure: :annexb},
    availability: :on_request,
    options: [
      resolution: [
        spec: Resolution.t(),
        description: "Resolution of output stream."
      ],
      output_id: [
        spec: output_id(),
        description: "Output identifier."
      ],
      encoder_preset: [
        spec: encoder_preset(),
        description:
          "Preset for an encoder. See [FFmpeg docs](https://trac.ffmpeg.org/wiki/Encode/H.264#Preset) to learn more.",
        default: :medium
      ]
    ]

  @impl true
  def handle_init(_ctx, opt) do
    vc_port = opt.vc_server_port_number
    :ok = start_vc_server(vc_port)

    :ok = VcReq.init(opt.framerate, opt.stream_fallback_timeout, opt.init_web_renderer?, vc_port)

    if opt.start_composing_strategy == :on_init do
      :ok = VcReq.start_composing(vc_port)
    end

    {[],
     %State{
       inputs: [],
       outputs: [],
       framerate: opt.framerate,
       vc_port: vc_port
     }}
  end

  @impl true
  def handle_pad_added(input_ref = Pad.ref(:input, pad_id), ctx, state = %State{inputs: inputs}) do
    input_id = ctx.options.input_id
    input_port = register_input_stream(input_id, state)

    state = %State{
      state
      | inputs: [
          %InputState{input_id: input_id, port_number: input_port, pad_ref: input_ref} | inputs
        ]
    }

    spec =
      bin_input(Pad.ref(:input, pad_id))
      |> via_in(Pad.ref(:input, pad_id),
        options: [payloader: RTP.H264.Payloader]
      )
      |> child({:rtp_sender, pad_id}, RTP.SessionBin)
      |> via_out(Pad.ref(:rtp_output, pad_id), options: [encoding: :H264])
      |> child({:upd_sink, pad_id}, %UDP.Sink{
        destination_port_no: input_port,
        destination_address: @local_host
      })

    {[notify_parent: {:input_registered, input_ref, input_id, State.ctx(state)}, spec: spec],
     state}
  end

  @impl true
  def handle_pad_added(
        output_ref = Pad.ref(:output, pad_id),
        ctx,
        state = %State{outputs: outputs}
      ) do
    port = register_output_stream(ctx.options, state)
    output_id = ctx.options.output_id

    state = %State{
      state
      | outputs: [
          %OutputState{output_id: output_id, pad_ref: output_ref, port_number: port}
          | outputs
        ]
    }

    spec =
      child(Pad.ref(:upd_source, pad_id), %UDP.Source{
        local_port_no: port,
        local_address: @local_host,
        recv_buffer_size: @udp_buffer_size
      })
      |> via_in(Pad.ref(:rtp_input, pad_id))
      |> child({:rtp_receiver, pad_id}, RTP.SessionBin)

    {[notify_parent: {:output_registered, output_ref, output_id, State.ctx(state)}, spec: spec],
     state}
  end

  @impl true
  def handle_pad_removed(input_ref = Pad.ref(:input, pad_id), _ctx, state = %State{}) do
    state = remove_input(state, input_ref)
    {[remove_child: [{:rtp_sender, pad_id}, {:upd_sink, pad_id}]], state}
  end

  @impl true
  def handle_pad_removed(output_ref = Pad.ref(:output, pad_id), _ctx, state = %State{}) do
    state = remove_output(state, output_ref)
    {[remove_child: [{:rtp_receiver, pad_id}, {:upd_source, pad_id}]], state}
  end

  @impl true
  def handle_parent_notification(:start_composing, _ctx, state = %State{}) do
    :ok = VcReq.start_composing(state.vc_port)
    {[], state}
  end

  @impl true
  def handle_parent_notification({:vc_request, request_body}, _ctx, state = %State{}) do
    case VcReq.send_custom_request(request_body, state.vc_port) do
      {:ok, response} ->
        if response.status != 200 do
          Membrane.Logger.error(
            "Request\n#{inspect(request_body)}\nfailed with error:\n#{inspect(response.body)}"
          )
        end

        {[notify_parent: {:vc_request_response, request_body, response, State.ctx(state)}], state}

      {:error, err} ->
        Membrane.Logger.error("Request: #{request_body} failed. Error: #{err}.")
        {[], state}
    end
  end

  @impl true
  def handle_parent_notification(_notification, _ctx, state = %State{}) do
    {[], state}
  end

  @impl true
  def handle_child_notification(
        {:new_rtp_stream, ssrc, _pt, _ext},
        {:rtp_receiver, pad_id},
        _ctx,
        state
      ) do
    spec =
      get_child({:rtp_receiver, pad_id})
      |> via_out(Pad.ref(:output, ssrc), options: [depayloader: RTP.H264.Depayloader])
      |> bin_output(Pad.ref(:output, pad_id))

    {[spec: spec], state}
  end

  @impl true
  def handle_child_notification(_msg, _child, _ctx, state) do
    {[], state}
  end

  @spec start_vc_server(port_number()) :: :ok
  defp start_vc_server(vc_port) do
    architecture = system_architecture() |> Atom.to_string()

    vc_app_path =
      File.cwd!()
      |> Path.join("video_compositor_app/#{architecture}/video_compositor/video_compositor")

    spawn(fn ->
      Rambo.run(vc_app_path, [], env: %{"MEMBRANE_VIDEO_COMPOSITOR_API_PORT" => "#{vc_port}"})
    end)

    started? =
      0..50
      |> Enum.reduce_while(false, fn _i, _acc ->
        sleep_time_ms = 100
        :timer.sleep(sleep_time_ms)

        case VcReq.send_custom_request(%{}, vc_port) do
          {:ok, _} -> {:halt, true}
          {:error, _} -> {:cont, false}
        end
      end)

    unless started? do
      raise "Failed to startup and connect to VideoCompositor server."
    end

    :ok
  end

  @spec system_architecture() :: :darwin_aarch64 | :darwin_x86_64 | :linux_x86_64
  defp system_architecture() do
    case :os.type() do
      {:unix, :darwin} ->
        system_architecture = :erlang.system_info(:system_architecture) |> to_string()

        cond do
          Regex.match?(~r/aarch64/, system_architecture) ->
            :darwin_aarch64

          Regex.match?(~r/x86_64/, system_architecture) ->
            :darwin_x86_64

          true ->
            raise "Unsupported system architecture: #{system_architecture}"
        end

      {:unix, :linux} ->
        :linux_x86_64

      os_type ->
        raise "Unsupported os type: #{os_type}"
    end
  end

  @spec register_input_stream(input_id(), State.t(), port_number()) ::
          port_number()
  defp register_input_stream(input_id, state, input_port \\ 4000) do
    if state |> State.used_ports() |> MapSet.member?(input_port) do
      register_input_stream(input_id, state, input_port + 2)
    else
      case VcReq.register_input_stream(input_id, input_port, state.vc_port) do
        :ok ->
          input_port

        {:error, %Req.Response{}} ->
          register_input_stream(
            input_id,
            state,
            input_port + 2
          )

        _other ->
          raise "Register input failed"
      end
    end
  end

  @spec register_output_stream(map(), State.t(), port_number()) :: port_number()
  defp register_output_stream(pad_options, state, output_port \\ 5000) do
    if state |> State.used_ports() |> MapSet.member?(output_port) do
      register_output_stream(pad_options, state, output_port + 2)
    else
      :ok =
        VcReq.register_output_stream(
          pad_options.output_id,
          output_port,
          pad_options.resolution,
          pad_options.encoder_preset,
          state.vc_port
        )

      output_port
    end
  end

  @spec remove_input(State.t(), Membrane.Pad.ref()) :: State.t()
  defp remove_input(state = %State{inputs: inputs}, input_ref) do
    input_id =
      inputs
      |> Enum.find(fn %InputState{pad_ref: ref} -> ref == input_ref end)
      |> then(fn %InputState{input_id: id} -> id end)

    :ok = VcReq.unregister_input_stream(input_id, state.vc_port)

    inputs = Enum.reject(inputs, fn %InputState{pad_ref: ref} -> ref == input_ref end)

    %State{state | inputs: inputs}
  end

  @spec remove_output(State.t(), Membrane.Pad.ref()) :: State.t()
  defp remove_output(state = %State{outputs: outputs}, output_ref) do
    output_id =
      outputs
      |> Enum.find(fn %OutputState{pad_ref: ref} -> ref == output_ref end)
      |> then(fn %OutputState{output_id: id} -> id end)

    outputs = Enum.reject(outputs, fn %OutputState{pad_ref: ref} -> ref == output_ref end)

    :ok = VcReq.unregister_output_stream(output_id, state.vc_port)

    %State{state | outputs: outputs}
  end
end
