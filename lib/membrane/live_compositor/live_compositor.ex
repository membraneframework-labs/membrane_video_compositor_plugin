defmodule Membrane.LiveCompositor do
  @moduledoc """
  Membrane SDK for [LiveCompositor](https://github.com/membraneframework/live_compositor).

  ## Input streams

  Each input pad has a format `Pad.ref(:video_input, input_id)` or `Pad.ref(:audio_input, input_id)`,
  where `input_id` is a string. `input_id` needs to be unique for all input pads, in particular
  you can't have audio and video input pads with the same id.

  See `Membrane.LiveCompositor.Lifecycle` for input stream lifecycle notifications.

  ## Output streams

  Each output pad has a format `Pad.ref(:video_output, output_id)` or `Pad.ref(:audio_output, output_id)`,
  where `output_id` is a string. `output_id` needs to be unique for all output pads, in particular
  you can't have audio and video output pads with the same id.

  After registering and linking an output stream the LiveCompositor will notify the parent with
  [`output_registered/0`](`t:Membrane.LiveCompositor.Lifecycle.output_registered/0`).

  ## Composition specification - `video`

  To specify what LiveCompositor should render you can:
  - Define `initial` option when connecting `:video_output` pad.
  - Send [`Request.UpdateVideoOutput`](`Membrane.LiveCompositor.Request.UpdateVideoOutput`)
  notification to update a scene on an already connected pad.

  For example, code snippet bellow will update content of a stream from `Pad.ref(:video_output, "output_0")`
  to include streams from `Pad.ref(:video_input, "input_0")` and `Pad.ref(:video_input, "input_1")`
  side by side using [`Tiles`](https://compositor.live/docs/api/components/Tiles) component.

  ```
  scene_update_request =  %Request.UpdateVideoOutput{
    output_id: "output_0"
    root: %{
      type: :tiles,
      children: [
        { type: "input_stream", input_id: "input_0" },
        { type: "input_stream", input_id: "input_1" }
      ]
    }
  }

  {[notify_child: {:live_compositor, scene_update_request}]}
  ```

  `:root` option specifies root component of a scene that will be rendered on the output stream.
  Concept of a component is explained [here](https://compositor.live/docs/concept/component). For
  actual component definitions see LiveCompositor documentation e.g.
  [`View`](https://compositor.live/docs/api/components/View),
  [`Tiles`](https://compositor.live/docs/api/components/Tiles), ...

  ## Composition specification - `audio`

  - Define `initial` option when connecting `:audio_output` pad.
  - Send [`Request.UpdateAudioOutput`](`Membrane.LiveCompositor.Request.UpdateAudioOutput`)
  notification to audio composition on an already connected pad.

  For example, code snippet bellow will update content of a stream from `Pad.ref(:video_output, "output_0")`
  to include streams from `Pad.ref(:video_input, "input_0")` and `Pad.ref(:video_input, "input_1")`
  mixed together, where `"input_0"` is mixed at half volume.

  ```
  audio_update_request =  %Request.UpdateAudioOutput{
    output_id: "output_0"
    inputs: [
      { input_id: "input_0", volume: 0.5 },
      { input_id: "input_1" }
    ]
  }

  {[notify_child: {:live_compositor, audio_update_request}]}
  ```

  ## Notifications

  LiveCompositor bin can send following notifications to the parent process.
  - [`Lifecycle.notification/0`](`t:Membrane.LiveCompositor.Lifecycle.notification/0`) -
  Notification about lifecycle of input/output streams.
  - [`Request.result/0`](`t:Membrane.LiveCompositor.Request.result/0`) - Result of a
  `Membrane.LiveCompositor.Request` sent from the parent process.

  ## LiveCompositor documentation

  This documentation covers mostly Elixr/Membrane specific API. For platform/language independent topics
  that are not covered here check [LiveCompositor documentation](https://compositor.live/docs/category/api-reference).
  """

  use Membrane.Bin

  require Membrane.Logger

  alias Jason.Encoder

  alias Membrane.{Opus, Pad, RemoteStream, RTP, TCP}

  alias Membrane.LiveCompositor.{
    ApiClient,
    ApiClient.IntoRequest,
    Context,
    Encoder,
    EventHandler,
    Request,
    ServerRunner,
    State,
    StreamsHandler
  }

  @typedoc """
  Input stream id, uniquely identifies an input pad.
  """
  @type input_id :: String.t()

  @typedoc """
  Output stream id, uniquely identifies an output pad.
  """
  @type output_id :: String.t()

  @typedoc """
  Range of ports.
  """
  @type port_range :: {lower_bound :: :inet.port_number(), upper_bound :: :inet.port_number()}

  @typedoc """
  Supported output sample rates.
  """
  @type output_sample_rate :: 8_000 | 12_000 | 16_000 | 24_000 | 48_000

  @typedoc """
  Condition that defines when output stream should end depending on the
  EOS received on inputs.
  """
  @type send_eos_condition ::
          nil
          | :any_input
          | :all_inputs
          | {:any_of, list(input_id())}
          | {:all_of, list(input_id())}

  @local_host {127, 0, 0, 1}

  def_options framerate: [
                spec: Membrane.RawVideo.framerate_t(),
                description: "Framerate of LiveCompositor outputs."
              ],
              output_sample_rate: [
                spec: output_sample_rate(),
                default: 48_000,
                description: "Sample rate of audio on LiveCompositor outputs."
              ],
              api_port: [
                spec: :inet.port_number() | port_range(),
                description: """
                Port number or port range where API of a LiveCompositor will be hosted.
                """,
                default: 8081
              ],
              stream_fallback_timeout: [
                spec: Membrane.Time.t(),
                description: """
                Timeout that defines when the LiveCompositor should switch to fallback on
                the input stream that stopped sending frames.
                """,
                default: Membrane.Time.seconds(2)
              ],
              composing_strategy: [
                spec: :real_time_auto_init | :real_time | :offline_processing,
                description: """
                Specifies LiveCompositor mode for composing frames:
                - `:real_time` - Frames are produced at a rate dictated by real time clock. The parent
                process has to send `:start_composing` message to start.
                - `:real_time_auto_init` - The same as `:real_time`, but the pipeline starts
                automatically and sending `:start_composing` message is not necessary.
                - `:offline_processing`
                  - Output streams will be produced faster than in real time if input streams are
                  ready.
                  - Never drop output frames, even if the encoder or rendering process is not able to
                  process data in real time.

                    When using this option, make sure to register the output stream before starting;
                    otherwise, the compositor will run in a busy loop processing data far into the future.
                """,
                default: :real_time_auto_init
              ],
              server_setup: [
                spec: :already_started | :start_locally | {:start_locally, path :: String.t()},
                description: """
                Defines how the LiveCompositor bin should start-up a LiveCompositor server.

                Available options:
                - `:start_locally` - LC server is automatically started.
                - `{:start_locally, path}` - LC server is automatically started, but different binary
                is used to spawn the process.
                - `:already_started` - LiveCompositor bin assumes, that LC server is already started
                and is available on a specified port. When this option is selected, the `api_port`
                option need to specify an exact port number (not a range).
                """,
                default: :start_locally
              ],
              init_requests: [
                spec: list(Request.t()),
                description: """
                Requests that will be sent on startup to the LC server. It's main use case is to
                register renderers that will be needed in the scene from the very beginning.

                Example:
                ```
                [%Request.RegisterShader{
                  shader_id: "example_shader_1",
                  source: "<shader sources>"
                }]
                ```
                """,
                default: []
              ]

  def_input_pad :video_input,
    accepted_format: %Membrane.H264{alignment: :nalu, stream_structure: :annexb},
    availability: :on_request,
    options: [
      required: [
        spec: boolean(),
        default: false,
        description: """
        If stream is marked required the LiveCompositor will delay processing new frames until
        frames are available. In particular, if there is at least one required input stream and the
        encoder is not able to produce frames on time, the output stream will also be delayed. This
        delay will happen regardless of whether required input stream was on time or not.
        """
      ],
      offset: [
        spec: Membrane.Time.t() | nil,
        default: nil,
        description: """
        An optional offset used for stream synchronization. This value represents how PTS values of the
        stream are shifted relative to the start request. If not defined streams are synchronized
        based on the delivery times of initial frames.
        """
      ],
      port: [
        spec: :inet.port_number() | port_range(),
        description: """
        Port number or port range.

        Internally LiveCompositor server communicates with this pipeline locally over RTP.
        This value defines which TCP ports will be used.
        """,
        default: {10_000, 60_000}
      ]
    ]

  def_input_pad :audio_input,
    accepted_format:
      any_of(
        %Opus{self_delimiting?: false},
        %RemoteStream{type: :packetized, content_format: Opus},
        %RemoteStream{type: :packetized, content_format: nil}
      ),
    availability: :on_request,
    options: [
      required: [
        spec: boolean(),
        default: false,
        description: """
        If stream is marked required the LiveCompositor will delay processing new frames until
        frames are available. In particular, if there is at least one required input stream and the
        encoder is not able to produce frames on time, the output stream will also be delayed. This
        delay will happen regardless of whether required input stream was on time or not.
        """
      ],
      offset: [
        spec: Membrane.Time.t() | nil,
        default: nil,
        description: """
        An optional offset used for stream synchronization. This value represents how PTS values of the
        stream are shifted relative to the start request. If not defined streams are synchronized
        based on the delivery times of initial frames.
        """
      ],
      port: [
        spec: :inet.port_number() | port_range(),
        description: """
        Port number or port range.

        Internally LiveCompositor server communicates with this pipeline locally over RTP.
        This value defines which TCP ports will be used.
        """,
        default: {10_000, 60_000}
      ]
    ]

  def_output_pad :video_output,
    accepted_format: %Membrane.H264{alignment: :nalu, stream_structure: :annexb},
    availability: :on_request,
    options: [
      port: [
        spec: :inet.port_number() | port_range(),
        description: """
        Port number or port range.

        Internally LiveCompositor server communicates with this pipeline locally over RTP.
        This value defines which TCP ports will be used.
        """,
        default: {10_000, 60_000}
      ],
      width: [
        spec: non_neg_integer()
      ],
      height: [
        spec: non_neg_integer()
      ],
      encoder: [
        spec: Encoder.FFmpegH264.t()
      ],
      send_eos_when: [
        spec: send_eos_condition(),
        default: nil,
        description: """
        Condition for automatically finishing output stream in response to end of input streams.

        - `{:any_of, input_ids}` - End the output stream if any of the inputs from the list finished
        or if they don't exist.
        - `{:all_of, input_ids}` - End the output stream if all of the inputs from the list finished
        or if they don't exist.
        - `:any_input` - End the output stream when any input stream finishes.
        - `:all_inputs` - End the output stream when all of the input streams have finished. This
        also includes a case where no inputs are were ever connected.
        """
      ],
      initial: [
        spec: any(),
        description: """
        Initial scene that will be rendered on this output.

        Example:
        ```
        %{
          root: %{
            type: :view,
            children: [
              %{ type: :input_stream, input_id: "input_0" }
            ]
          }
        }
        ```

        To change the scene after the registration you can send `%Request.UpdateVideoOutput{}`
        notification.

        Format of the `:root` field is documented [here](https://compositor.live/docs/concept/component).
        For specific options see documentation pages for each component e.g.
        [`View`](https://compositor.live/docs/api/components/View),
        [`Tiles`](https://compositor.live/docs/api/components/Tiles), ...
        """
      ]
    ]

  def_output_pad :audio_output,
    accepted_format: %RemoteStream{type: :packetized, content_format: Opus},
    availability: :on_request,
    options: [
      port: [
        spec: :inet.port_number() | port_range(),
        description: """
        Port number or port range.

        Internally LiveCompositor server communicates with this pipeline locally over RTP.
        This value defines which TCP ports will be used.
        """,
        default: {10_000, 60_000}
      ],
      encoder: [
        spec: Encoder.Opus.t()
      ],
      send_eos_when: [
        spec: send_eos_condition(),
        default: nil,
        description: """
        Condition for automatically finishing output stream in response to end of input streams.

        - `{:any_of, input_ids}` - End the output stream if any of the inputs from the list finished
        or if they don't exist.
        - `{:all_of, input_ids}` - End the output stream if all of the inputs from the list finished
        or if they don't exist.
        - `:any_input` - End the output stream when any input stream finishes.
        - `:all_inputs` - End the output stream when all of the input streams have finished. This
        also includes a case where no inputs are were ever connected.
        """
      ],
      initial: [
        spec: any(),
        description: """
        Initial audio mixer configuration that will be produced on this output.

        Example:
        ```
        %{
          inputs: [
            %{ input_id: "input_0" },
            %{ input_id: "input_0", volume: 0.5 }
          ]
        }
        ```

        To change the scene after the registration you can send `%Request.UpdateAudioOutput{}`
        notification.
        """
      ]
    ]

  @impl true
  def handle_init(_ctx, opt) do
    {[], opt}
  end

  @impl true
  def handle_setup(ctx, opt) do
    {:ok, lc_port, server_pid} =
      ServerRunner.ensure_server_started(opt)

    Membrane.ResourceGuard.register(
      ctx.resource_guard,
      fn -> Process.exit(server_pid, :kill) end,
      tag: :live_compositor_server
    )

    opt.init_requests
    |> Enum.each(fn request ->
      {:ok, _} =
        IntoRequest.into_request(request)
        |> ApiClient.send_request(lc_port)
    end)

    Membrane.UtilitySupervisor.start_link_child(
      ctx.utility_supervisor,
      {EventHandler, {lc_port, self()}}
    )

    {[setup: :incomplete],
     %State{
       output_framerate: opt.framerate,
       output_sample_rate: opt.output_sample_rate,
       composing_strategy: opt.composing_strategy,
       lc_port: lc_port,
       context: %Context{}
     }}
  end

  @impl true
  def handle_pad_added(input_ref = Pad.ref(:video_input, pad_id), ctx, state) do
    state = %State{state | context: Context.add_stream(input_ref, state.context)}

    {:ok, port} =
      StreamsHandler.register_video_input_stream(pad_id, ctx.pad_options, state)

    {state, ssrc} = State.next_ssrc(state)

    links =
      bin_input(input_ref)
      |> via_in(Pad.ref(:input, ssrc),
        options: [payloader: RTP.H264.Payloader]
      )
      |> child({:rtp_sender, pad_id}, RTP.SessionBin)
      |> via_out(Pad.ref(:rtp_output, ssrc), options: [payload_type: 96])
      |> child({:tcp_encapsulator, pad_id}, RTP.TCP.Encapsulator)
      |> child({:tcp_sink, input_ref}, %TCP.Sink{
        connection_side: {:client, @local_host, port}
      })

    spec = {links, group: input_group_id(pad_id)}

    {[spec: spec], state}
  end

  @impl true
  def handle_pad_added(input_ref = Pad.ref(:audio_input, pad_id), ctx, state) do
    state = %State{state | context: Context.add_stream(input_ref, state.context)}

    {:ok, port} =
      StreamsHandler.register_audio_input_stream(pad_id, ctx.pad_options, state)

    {state, ssrc} = State.next_ssrc(state)

    links =
      bin_input(input_ref)
      |> via_in(Pad.ref(:input, ssrc),
        options: [payloader: RTP.Opus.Payloader]
      )
      |> child({:rtp_sender, pad_id}, RTP.SessionBin)
      |> via_out(Pad.ref(:rtp_output, ssrc), options: [payload_type: 97, clock_rate: 48_000])
      |> child({:tcp_encapsulator, pad_id}, RTP.TCP.Encapsulator)
      |> child({:tcp_sink, input_ref}, %TCP.Sink{
        connection_side: {:client, @local_host, port}
      })

    spec = {links, group: input_group_id(pad_id)}

    {[spec: spec], state}
  end

  @impl true
  def handle_pad_added(output_ref = Pad.ref(:video_output, pad_id), ctx, state) do
    state = %State{state | context: Context.add_stream(output_ref, state.context)}
    {:ok, port} = StreamsHandler.register_video_output_stream(pad_id, ctx.pad_options, state)

    output_stream_format = %Membrane.H264{
      framerate: state.output_framerate,
      alignment: :nalu,
      stream_structure: :annexb,
      width: ctx.pad_options.width,
      height: ctx.pad_options.height
    }

    links =
      [
        child({:tcp_source, output_ref}, %TCP.Source{
          connection_side: {:client, @local_host, port}
        })
        |> child({:tcp_decapsulator, pad_id}, RTP.TCP.Decapsulator)
        |> via_in(Pad.ref(:rtp_input, pad_id))
        |> child({:rtp_receiver, output_ref}, RTP.SessionBin),
        child({:output_processor, pad_id}, %Membrane.LiveCompositor.VideoOutputProcessor{
          output_stream_format: output_stream_format
        })
        |> bin_output(Pad.ref(:video_output, pad_id))
      ]

    spec = {links, group: output_group_id(pad_id)}

    {[spec: spec], state}
  end

  @impl true
  def handle_pad_added(output_ref = Pad.ref(:audio_output, pad_id), ctx, state) do
    state = %State{state | context: Context.add_stream(output_ref, state.context)}
    {:ok, port} = StreamsHandler.register_audio_output_stream(pad_id, ctx.pad_options, state)

    links = [
      child({:tcp_source, output_ref}, %TCP.Source{
        connection_side: {:client, @local_host, port}
      })
      |> child({:tcp_decapsulator, pad_id}, RTP.TCP.Decapsulator)
      |> via_in(Pad.ref(:rtp_input, pad_id))
      |> child({:rtp_receiver, output_ref}, RTP.SessionBin),
      child({:output_processor, pad_id}, Membrane.LiveCompositor.AudioOutputProcessor)
      |> bin_output(Pad.ref(:audio_output, pad_id))
    ]

    spec = {links, group: output_group_id(pad_id)}

    {[spec: spec], state}
  end

  @impl true
  def handle_pad_removed(input_ref = Pad.ref(input_type, pad_id), _ctx, state)
      when input_type in [:audio_input, :video_input] do
    # If EOS was not received yet, unregister will be called in `handle_element_end_of_stream/4`
    if MapSet.member?(state.tcp_sink_eos, input_ref) do
      {:ok, _resp} =
        %Request.UnregisterInput{input_id: pad_id}
        |> IntoRequest.into_request()
        |> ApiClient.send_request(state.lc_port)
    end

    state = %State{
      state
      | tcp_sink_eos: MapSet.delete(state.tcp_sink_eos, input_ref),
        context: Context.remove_input(pad_id, state.context)
    }

    {[remove_children: input_group_id(pad_id)], state}
  end

  @impl true
  def handle_pad_removed(Pad.ref(:video_output, pad_id), _ctx, state) do
    {:ok, _resp} =
      %Request.UnregisterOutput{output_id: pad_id}
      |> IntoRequest.into_request()
      |> ApiClient.send_request(state.lc_port)

    state = %State{state | context: Context.remove_output(pad_id, state.context)}
    {[remove_children: output_group_id(pad_id)], state}
  end

  @impl true
  def handle_pad_removed(Pad.ref(:audio_output, pad_id), _ctx, state) do
    {:ok, _resp} =
      %Request.UnregisterOutput{output_id: pad_id}
      |> IntoRequest.into_request()
      |> ApiClient.send_request(state.lc_port)

    state = %State{state | context: Context.remove_output(pad_id, state.context)}
    {[remove_children: output_group_id(pad_id)], state}
  end

  @impl true
  def handle_parent_notification(:start_composing, _ctx, state) do
    {:ok, _response} =
      ApiClient.start_composing(state.lc_port)

    {[], state}
  end

  @impl true
  def handle_parent_notification(req = %module{}, _ctx, state)
      when module in [
             Request.RegisterImage,
             Request.RegisterShader,
             Request.UnregisterImage,
             Request.UnregisterShader,
             Request.UnregisterInput,
             Request.UnregisterOutput,
             Request.UpdateVideoOutput,
             Request.UpdateAudioOutput
           ] do
    response =
      IntoRequest.into_request(req)
      |> ApiClient.send_request(state.lc_port)

    case response do
      {:error, exception} ->
        Membrane.Logger.error(
          "LiveCompositor failed to send a request: #{inspect(req)}.\nException: #{inspect(exception)}."
        )

      {:ok, _result} ->
        nil
    end

    {[notify_parent: {:request_result, req, response}], state}
  end

  @impl true
  def handle_parent_notification(notification, _ctx, state) do
    Membrane.Logger.warning(
      "LiveCompositor received unknown notification from the parent: #{inspect(notification)}!"
    )

    {[], state}
  end

  @impl true
  def handle_child_notification(
        {:new_rtp_stream, ssrc, _payload_type, _extensions},
        {:rtp_receiver, ref = Pad.ref(:video_output, pad_id)},
        _ctx,
        state = %State{}
      ) do
    links =
      get_child({:rtp_receiver, ref})
      |> via_out(Pad.ref(:output, ssrc),
        options: [depayloader: RTP.H264.Depayloader, clock_rate: 90_000]
      )
      |> get_child({:output_processor, pad_id})

    actions = [spec: {links, group: output_group_id(pad_id)}]

    {actions, state}
  end

  @impl true
  def handle_child_notification(
        {:new_rtp_stream, ssrc, _payload_type, _extensions},
        {:rtp_receiver, ref = Pad.ref(:audio_output, pad_id)},
        _ctx,
        state = %State{}
      ) do
    links =
      get_child({:rtp_receiver, ref})
      |> via_out(Pad.ref(:output, ssrc),
        options: [depayloader: RTP.Opus.Depayloader, clock_rate: 48_000]
      )
      |> get_child({:output_processor, pad_id})

    {[spec: {links, group: output_group_id(pad_id)}], state}
  end

  @impl true
  def handle_child_notification(
        {:connection_info, _ip, _port},
        {:tcp_sink, pad_ref},
        _ctx,
        state = %State{}
      ) do
    {[notify_parent: {:input_registered, pad_ref, state.context}], state}
  end

  @impl true
  def handle_child_notification(
        {:connection_info, _ip, _port},
        {:tcp_source, pad_ref},
        _ctx,
        state = %State{}
      ) do
    {[notify_parent: {:output_registered, pad_ref, state.context}], state}
  end

  @impl true
  def handle_child_notification(msg, child, _ctx, state) do
    Membrane.Logger.debug(
      "Unknown msg received from child: #{inspect(msg)}, child: #{inspect(child)}"
    )

    {[], state}
  end

  @impl true
  def handle_info(:websocket_connected, _ctx, state) do
    if state.composing_strategy == :real_time_auto_init do
      {:ok, _resp} = ApiClient.start_composing(state.lc_port)
    end

    {[setup: :complete], state}
  end

  @impl true
  def handle_info({:websocket_message, {event_type, event_data}}, _ctx, state) do
    {[notify_parent: {event_type, event_data, state.context}], state}
  end

  @impl true
  def handle_info(msg, _ctx, state) do
    Membrane.Logger.debug("Unknown msg received: #{inspect(msg)}")

    {[], state}
  end

  @impl true
  def handle_element_end_of_stream(
        {:tcp_sink, input_ref = Pad.ref(_pad_type, pad_id)},
        _pad,
        ctx,
        state
      ) do
    state =
      if Map.has_key?(ctx.pads, input_ref) do
        %State{state | tcp_sink_eos: MapSet.put(state.tcp_sink_eos, input_ref)}
      else
        {:ok, _resp} =
          %Request.UnregisterInput{input_id: pad_id}
          |> IntoRequest.into_request()
          |> ApiClient.send_request(state.lc_port)

        state
      end

    {[], state}
  end

  @impl true
  def handle_element_end_of_stream(_child, _pad, _ctx, state) do
    {[], state}
  end

  @spec input_group_id(input_id()) :: String.t()
  defp input_group_id(input_id) do
    "input_group_#{input_id}"
  end

  @spec output_group_id(output_id()) :: String.t()
  defp output_group_id(output_id) do
    "output_group_#{output_id}"
  end
end
