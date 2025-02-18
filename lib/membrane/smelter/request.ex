defmodule Membrane.Smelter.Request do
  @moduledoc """
  Notifications that can be sent to Smelter to trigger certain actions.

  After request is handled (but not necessarily completed e.g. if you schedule some action) the bin will
  respond with `t:result/0`.
  """

  alias Membrane.Smelter.ApiClient

  defmodule RegisterImage do
    @moduledoc """
    Request to register an image.
    """

    @typedoc """
    Image type
    """
    @type image_type :: :png | :jpeg | :gif | :svg

    @enforce_keys [:image_id, :asset_type]
    defstruct @enforce_keys ++ [url: nil, path: nil, resolution: nil]

    @typedoc """
    - Fields `url` and `path` are mutually exclusive. Exactly one of them should be set at the time.
    - Field `resolution` is only supported when `:asset_type` is set to `:svg`.
    """
    @type t :: %__MODULE__{
            image_id: String.t(),
            asset_type: image_type(),
            url: String.t() | nil,
            path: String.t() | nil,
            resolution: %{width: non_neg_integer(), height: non_neg_integer()} | nil
          }
  end

  defimpl ApiClient.IntoRequest, for: RegisterImage do
    @spec into_request(RegisterImage.t()) :: ApiClient.request()
    def into_request(request) do
      maybe_resolution =
        case request.asset_type do
          :svg -> %{resolution: request.resolution}
          _type -> %{}
        end

      body =
        %{
          asset_type: request.asset_type,
          path: request.path,
          url: request.url
        }
        |> Map.merge(maybe_resolution)

      encoded_id = URI.encode_www_form(request.image_id)
      {:post, "/api/image/#{encoded_id}/register", body}
    end
  end

  defmodule RegisterShader do
    @moduledoc """
    Request to register a shader instance.
    """

    @enforce_keys [:shader_id, :source]
    defstruct @enforce_keys ++ []

    @typedoc """
    WGSL shader source code. [Learn more](https://smelter.dev/fundamentals/concepts/shaders).
    """
    @type shader_source :: String.t()

    @type t :: %__MODULE__{
            shader_id: String.t(),
            source: shader_source()
          }
  end

  defimpl ApiClient.IntoRequest, for: RegisterShader do
    @spec into_request(RegisterShader.t()) :: ApiClient.request()
    def into_request(request) do
      body = %{
        source: request.source
      }

      encoded_id = URI.encode_www_form(request.shader_id)
      {:post, "/api/shader/#{encoded_id}/register", body}
    end
  end

  defmodule UnregisterImage do
    @moduledoc """
    Request to unregister an image.
    """

    @enforce_keys [:image_id]
    defstruct @enforce_keys ++ []

    @type t :: %__MODULE__{
            image_id: String.t()
          }
  end

  defimpl ApiClient.IntoRequest, for: UnregisterImage do
    @spec into_request(UnregisterImage.t()) :: ApiClient.request()
    def into_request(request) do
      encoded_id = URI.encode_www_form(request.image_id)
      {:post, "/api/image/#{encoded_id}/unregister", %{}}
    end
  end

  defmodule UnregisterShader do
    @moduledoc """
    Request to unregister a shader instance.
    """

    @enforce_keys [:shader_id]
    defstruct @enforce_keys ++ []

    @type t :: %__MODULE__{
            shader_id: String.t()
          }
  end

  defimpl ApiClient.IntoRequest, for: UnregisterShader do
    @spec into_request(UnregisterShader.t()) :: ApiClient.request()
    def into_request(request) do
      encoded_id = URI.encode_www_form(request.shader_id)
      {:post, "/api/shader/#{encoded_id}/unregister", %{}}
    end
  end

  defmodule UnregisterInput do
    @moduledoc """
    Request to unregister an input stream. Unregister will happen automatically when you unlink the
    pads.
    """

    alias Membrane.Smelter

    @enforce_keys [:input_id]
    defstruct @enforce_keys ++ [schedule_time: nil]

    @type t :: %__MODULE__{
            input_id: Smelter.input_id(),
            schedule_time: Membrane.Time | nil
          }
  end

  defimpl ApiClient.IntoRequest, for: UnregisterInput do
    @spec into_request(UnregisterInput.t()) :: ApiClient.request()
    def into_request(request) do
      body = %{
        schedule_time_ms:
          case request.schedule_time do
            nil -> nil
            offset -> Membrane.Time.as_milliseconds(offset, :round)
          end
      }

      encoded_id = URI.encode_www_form(request.input_id)
      {:post, "/api/input/#{encoded_id}/unregister", body}
    end
  end

  defmodule UnregisterOutput do
    @moduledoc """
    Request to unregister an output stream. Unregister will happen automatically when you unlink the
    pads.
    """

    alias Membrane.Smelter

    @enforce_keys [:output_id]
    defstruct @enforce_keys ++ [schedule_time: nil]

    @type t :: %__MODULE__{
            output_id: Smelter.output_id(),
            schedule_time: Membrane.Time | nil
          }
  end

  defimpl ApiClient.IntoRequest, for: UnregisterOutput do
    @spec into_request(UnregisterOutput.t()) :: ApiClient.request()
    def into_request(request) do
      body = %{
        schedule_time_ms:
          case request.schedule_time do
            nil -> nil
            offset -> Membrane.Time.as_milliseconds(offset, :round)
          end
      }

      encoded_id = URI.encode_www_form(request.output_id)
      {:post, "/api/output/#{encoded_id}/unregister", body}
    end
  end

  defmodule UpdateVideoOutput do
    @moduledoc """
    Request to update the scene definition that describes what should be rendered on a specified output.
    """

    alias Membrane.Smelter

    @enforce_keys [:output_id, :root]
    defstruct @enforce_keys ++ [schedule_time: nil]

    @typedoc """
    - `:output_id` - Id of the output that should be updated.
    - `:root` - Root of a component tree/scene that should be rendered for the output. [Learn more](https://smelter.dev/http-api/overview#components)
    - `:schedule_time` - Schedule this update at a specific time. Time is measured from Smelter
    start. If not defined, update will be applied immediately.
    """
    @type t :: %__MODULE__{
            output_id: Smelter.output_id(),
            root: any(),
            schedule_time: Membrane.Time | nil
          }
  end

  defimpl ApiClient.IntoRequest, for: UpdateVideoOutput do
    @spec into_request(UpdateVideoOutput.t()) :: ApiClient.request()
    def into_request(request) do
      body = %{
        video: %{
          root: request.root
        },
        schedule_time_ms:
          case request.schedule_time do
            nil -> nil
            offset -> Membrane.Time.as_milliseconds(offset, :round)
          end
      }

      encoded_id = URI.encode_www_form(request.output_id)
      {:post, "/api/output/#{encoded_id}/update", body}
    end
  end

  defmodule UpdateAudioOutput do
    @moduledoc """
    Request to update configuration of an audio output. You can define what inputs and volume should
    be used to produce the output.
    """

    alias Membrane.Smelter

    @enforce_keys [:output_id, :inputs]
    defstruct @enforce_keys ++ [schedule_time: nil]

    @typedoc """
    - `input_id` - ID of an input that will be used to produce output.
    - `volume` - Number between 0 and 1 that represent volume of the input.
    """
    @type input :: %{input_id: Smelter.input_id(), volume: float() | nil}

    @typedoc """
    - `:output_id` - Id of the output that should be updated.
    - `:inputs` - Inputs and their configuration that should be mixed to produce the output audio.
    - `:schedule_time` - Schedule this update at a specific time. Time is measured from Smelter
    start. If not defined, update will be applied immediately.
    """
    @type t :: %__MODULE__{
            output_id: Smelter.output_id(),
            inputs: list(input()),
            schedule_time: Membrane.Time | nil
          }
  end

  defimpl ApiClient.IntoRequest, for: UpdateAudioOutput do
    @spec into_request(UpdateAudioOutput.t()) :: ApiClient.request()
    def into_request(request) do
      body = %{
        audio: %{
          inputs: request.inputs
        },
        schedule_time_ms:
          case request.schedule_time do
            nil -> nil
            offset -> Membrane.Time.as_milliseconds(offset, :round)
          end
      }

      encoded_id = URI.encode_www_form(request.output_id)
      {:post, "/api/output/#{encoded_id}/update", body}
    end
  end

  defmodule KeyframeRequest do
    @moduledoc """
    Request to trigger additional keyframe generation for a specified output.
    """

    @enforce_keys [:output_id]
    defstruct @enforce_keys

    @typedoc """
    - `:output_id` - Id of the output for which additional keyframe should be generated.
    """
    @type t :: %__MODULE__{
            output_id: Membrane.Smelter.output_id()
          }
  end

  defimpl ApiClient.IntoRequest, for: KeyframeRequest do
    @spec into_request(KeyframeRequest.t()) :: ApiClient.request()
    def into_request(request) do
      encoded_id = URI.encode_www_form(request.output_id)
      {:post, "/api/output/#{encoded_id}/request_keyframe", %{}}
    end
  end

  @type t ::
          RegisterImage.t()
          | RegisterShader.t()
          | UnregisterImage.t()
          | UnregisterShader.t()
          | UnregisterInput.t()
          | UnregisterOutput.t()
          | UpdateVideoOutput.t()
          | UpdateAudioOutput.t()
          | KeyframeRequest.t()

  @type result :: {:request_result, t(), {:ok, any()} | {:error, any()}}
end
