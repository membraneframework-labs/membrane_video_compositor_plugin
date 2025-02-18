# Membrane Smelter Plugin

[![Hex.pm](https://img.shields.io/hexpm/v/membrane_smelter_plugin.svg)](https://hex.pm/packages/membrane_smelter_plugin)
[![API Docs](https://img.shields.io/badge/api-docs-yellow.svg?style=flat)](https://hexdocs.pm/membrane_smelter_plugin)
[![CircleCI](https://dl.circleci.com/status-badge/img/gh/membraneframework/membrane_smelter_plugin/tree/master.svg?style=svg)](https://dl.circleci.com/status-badge/redirect/gh/membraneframework/membrane_smelter_plugin/tree/master)

Membrane SDK for [Smelter](https://smelter.dev), that takes multiple input streams, transforms them according to provided transformations and composes them into output streams / videos.

It is part of [Membrane Multimedia Framework](https://membrane.stream).

## Installation

The package can be installed by adding `membrane_smelter_plugin` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:membrane_smelter_plugin, "~> 0.10.1"}
  ]
end
```

Smelter requires having locally installed:

- [FFmpeg 6.0](https://ffmpeg.org/download.html) - for streaming inputs / outputs to Smelter
- [wget](https://www.gnu.org/software/wget/) - for downloading Smelter binary file
- [tar](https://www.gnu.org/software/tar/) - for decompressing Smelter binary file

## Examples

Examples can be found in `examples` directory.

To run example run:

1. `cd examples`
2. `mix deps.get`
3. `mix run lib/[example_name].exs`

### Layout with shader example

The example presents dynamically added video arranged onto a tiled layout and "twisted" with the simple shader. Shaders can be used to create custom visual effects.

### Transition example

The example presents dynamic transition of input videos. Transitions are used for smooth, dynamical animations.

### Dynamic outputs example

The example presents dynamic outputs linking.
Multiple outputs are useful for live-streaming for multiple platforms (e.g. different layout for mobile devices), target resolutions
or any other case, when user want to process input videos differently.

### Offline processing example

Example of processing that does not need to be real time. Multiple offline sources (mp4 files) are composed together and
produce output mp4 file. To simplify the example the same input file is read multiple times as a separate inputs. Depending
on hardware capabilities this example can run faster or slower than real time.
