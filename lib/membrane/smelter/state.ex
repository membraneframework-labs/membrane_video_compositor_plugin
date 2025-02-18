defmodule Membrane.Smelter.State do
  @moduledoc false

  require Membrane.Pad
  alias Membrane.Smelter
  alias Membrane.Smelter.Context

  @enforce_keys [
    :output_framerate,
    :output_sample_rate,
    :lc_address,
    :context,
    :composing_strategy
  ]
  defstruct @enforce_keys ++ [server_pid: nil, last_ssrc: 0]

  @type t :: %__MODULE__{
          context: Context.t(),
          output_framerate: Membrane.RawVideo.framerate(),
          output_sample_rate: Smelter.output_sample_rate(),
          composing_strategy: :real_time_auto_init | :real_time | :offline_processing,
          lc_address: {ip :: :inet.ip_address(), :inet.port_number()},
          server_pid: pid() | nil
        }

  @spec next_ssrc(t()) :: {t(), non_neg_integer()}
  def next_ssrc(state = %__MODULE__{last_ssrc: last_ssrc}) do
    {%__MODULE__{state | last_ssrc: last_ssrc + 1}, last_ssrc}
  end
end
