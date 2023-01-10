defmodule Membrane.VideoCompositor.Test.Pipeline do
  @moduledoc false
  use ExUnit.Case

  import Membrane.Testing.Assertions

  alias Membrane.RawVideo
  alias Membrane.Testing.Pipeline, as: TestingPipeline
  alias Membrane.VideoCompositor.RustStructs.BaseVideoPlacement
  alias Membrane.VideoCompositor.Test.Support.Pipeline.H264, as: PipelineH264
  alias Membrane.VideoCompositor.Test.Support.Pipeline.PacketLoss, as: PipelinePacketLoss
  alias Membrane.VideoCompositor.Test.Support.Utils

  @hd_video %RawVideo{
    width: 1280,
    height: 720,
    framerate: {30, 1},
    pixel_format: :I420,
    aligned: true
  }

  @full_hd_video %RawVideo{
    width: 1920,
    height: 1080,
    framerate: {30, 1},
    pixel_format: :I420,
    aligned: true
  }

  @empty_video_transformations Membrane.VideoCompositor.VideoTransformations.get_empty_video_transformations()

  describe "Checks h264 pipeline on merging four videos on 2x2 grid" do
    @describetag :tmp_dir

    @tag wgpu: true
    test "2s 720p 30fps h264", %{tmp_dir: tmp_dir} do
      test_h264_pipeline(@hd_video, 2, "short_videos", tmp_dir)
    end

    @tag wgpu: true
    test "1s 1080p 30fps h264", %{tmp_dir: tmp_dir} do
      test_h264_pipeline(@full_hd_video, 1, "short_videos", tmp_dir)
    end

    @tag long_wgpu: true, timeout: 1_000_000
    test "30s 720p 30fps h264", %{tmp_dir: tmp_dir} do
      test_h264_pipeline(@hd_video, 30, "long_videos", tmp_dir)
    end

    @tag long_wgpu: true, timeout: 1_000_000
    test "60s 1080p 30fps h264", %{tmp_dir: tmp_dir} do
      test_h264_pipeline(@full_hd_video, 30, "long_videos", tmp_dir)
    end
  end

  defp test_h264_pipeline(video_caps, duration, sub_dir_name, tmp_dir) do
    alias Membrane.VideoCompositor.Pipeline.Utils.{InputStream, Options}

    {input_path, _output_path, _ref_file_name} =
      Utils.prepare_testing_video(
        video_caps,
        duration,
        "h264",
        tmp_dir,
        sub_dir_name
      )

    out_caps = %RawVideo{
      video_caps
      | width: video_caps.width * 2,
        height: video_caps.height * 2
    }

    output_path =
      Path.join(
        tmp_dir,
        "out_#{duration}s_#{out_caps.width}x#{out_caps.height}_#{div(elem(out_caps.framerate, 0), elem(out_caps.framerate, 1))}fps.raw"
      )

    positions = [
      {0, 0},
      {video_caps.width, 0},
      {0, video_caps.height},
      {video_caps.width, video_caps.height}
    ]

    inputs =
      for pos <- positions,
          do: %InputStream{
            placement: %BaseVideoPlacement{
              position: pos,
              size: {video_caps.width, video_caps.height}
            },
            transformations: @empty_video_transformations,
            caps: video_caps,
            input: input_path
          }

    options = %Options{
      inputs: inputs,
      output: output_path,
      caps: out_caps
    }

    assert {:ok, pid} = TestingPipeline.start_link(module: PipelineH264, custom_args: options)

    assert_pipeline_playback_changed(pid, _, :playing)

    assert_end_of_stream(pid, :sink, :input, 1_000_000)
    TestingPipeline.terminate(pid, blocking?: true)
  end

  describe "Checks packet loss pipeline on merging four videos on 2x2 grid" do
    @describetag :tmp_dir

    @tag wgpu: true
    test "2s 720p 30fps h264", %{tmp_dir: tmp_dir} do
      test_h264_pipeline_with_packet_loss(
        @hd_video,
        2,
        "short_videos",
        tmp_dir
      )
    end

    @tag wgpu: true
    test "1s 1080p 30fps h264", %{tmp_dir: tmp_dir} do
      test_h264_pipeline_with_packet_loss(
        @full_hd_video,
        1,
        "short_videos",
        tmp_dir
      )
    end
  end

  defp test_h264_pipeline_with_packet_loss(
         video_caps,
         duration,
         sub_dir_name,
         tmp_dir
       ) do
    alias Membrane.VideoCompositor.Pipeline.Utils.{InputStream, Options}

    {input_path, output_path, _ref_file_name} =
      Utils.prepare_testing_video(video_caps, duration, "h264", tmp_dir, sub_dir_name)

    positions = [
      {0, 0},
      {video_caps.width, 0},
      {0, video_caps.height},
      {video_caps.width, video_caps.height}
    ]

    inputs =
      for pos <- positions,
          do: %InputStream{
            placement: %BaseVideoPlacement{
              position: pos,
              size: {video_caps.width, video_caps.height}
            },
            transformations: @empty_video_transformations,
            caps: video_caps,
            input: input_path
          }

    out_caps = %RawVideo{video_caps | width: video_caps.width * 2, height: video_caps.height * 2}

    options = %Options{
      inputs: inputs,
      output: output_path,
      caps: out_caps
    }

    assert {:ok, pid} =
             TestingPipeline.start_link(module: PipelinePacketLoss, custom_args: options)

    assert_pipeline_playback_changed(pid, _, :playing)

    assert_end_of_stream(pid, :sink, :input, 1_000_000)
    TestingPipeline.terminate(pid, blocking?: true)
  end
end
