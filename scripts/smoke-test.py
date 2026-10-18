#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 FVTVLIX and PLSTK contributors.

"""Exercise the real media pipeline using generated footage, never personal files."""
import json
import math
from pathlib import Path
import shutil
import signal
import struct
import subprocess
import time

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "TestOutput"
OUT.mkdir(exist_ok=True)
CLI = ROOT / ".build/debug/local-video"
FFMPEG = shutil.which("ffmpeg")
FFPROBE = shutil.which("ffprobe")
assert FFMPEG and FFPROBE and CLI.exists(), "Run swift build and install FFmpeg first"


def run(*args):
    return subprocess.run([str(x) for x in args], check=True, capture_output=True).stdout


def ff(*args):
    return run(FFMPEG, "-hide_banner", "-loglevel", "error", "-y", *args)


def probe(path):
    return json.loads(run(FFPROBE, "-v", "error", "-count_frames", "-show_streams", "-show_format", "-of", "json", path))


def project(name, files, ranges, size=(320, 180)):
    path = OUT / (name + ".localvideo")
    run(CLI, "create", path, *files)
    value = json.loads(path.read_text())
    value["width"], value["height"] = size
    for clip, (start, end) in zip(value["clips"], ranges):
        clip["inFrame"], clip["outFrame"] = start, end
    path.write_text(json.dumps(value, indent=2))
    run(CLI, "validate", path)
    return path


def rgb(path, at):
    return list(ff("-ss", str(at), "-i", path, "-frames:v", "1", "-vf", "scale=1:1", "-f", "rawvideo", "-pix_fmt", "rgb24", "pipe:1"))


def rms(path, at):
    raw = ff("-ss", str(at), "-i", path, "-t", "0.2", "-vn", "-ac", "1", "-ar", "48000", "-f", "f32le", "pipe:1")
    samples = struct.unpack("<" + "f" * (len(raw) // 4), raw)
    return math.sqrt(sum(x*x for x in samples) / len(samples))


red, blue = OUT / "red tone.mp4", OUT / "blue silent.mp4"
ff("-f", "lavfi", "-i", "color=c=red:s=320x180:r=30:d=3", "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000:duration=3", "-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac", "-shortest", red)
ff("-f", "lavfi", "-i", "color=c=blue:s=320x180:r=30:d=2", "-c:v", "libx264", "-pix_fmt", "yuv420p", blue)
edit = project("two-clips", [red, blue], [(30, 75), (15, 45)])
rendered = OUT / "two-clips.mp4"
run(CLI, "render", edit, rendered)
info = probe(rendered)
video = next(s for s in info["streams"] if s["codec_type"] == "video")
assert int(video["nb_read_frames"]) == 75, video
assert abs(float(info["format"]["duration"]) - 2.5) < 1 / 30
assert (video["width"], video["height"]) == (320, 180)
assert rgb(rendered, .5)[0] > 220 and rgb(rendered, 1.7)[2] > 220
assert rgb(rendered, 1.46)[0] > 220 and rgb(rendered, 1.51)[2] > 220, "Cut boundary shifted"
assert rms(rendered, .6) > .03 and rms(rendered, 1.8) < .001, "Audio does not follow its clip"

# Preserve a delayed audio stream's alignment instead of pulling the tone to time zero.
delayed = OUT / "delayed audio.mp4"
ff("-f", "lavfi", "-i", "color=c=green:s=320x180:r=30:d=3", "-itsoffset", "1", "-f", "lavfi", "-i", "sine=frequency=880:sample_rate=48000:duration=2", "-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac", delayed)
delayed_edit = project("delayed-audio", [delayed], [(15, 75)])
delayed_out = OUT / "delayed-audio.mp4"
run(CLI, "render", delayed_edit, delayed_out)
assert rms(delayed_out, .1) < .001 and rms(delayed_out, .8) > .03, "Delayed audio moved relative to video"

# Variable-rate, portrait input with rotation metadata; the render normalizes time and orientation.
portrait, rotated = OUT / "portrait.mp4", OUT / "rotated.mp4"
ff("-f", "lavfi", "-i", "testsrc2=s=180x320:r=30:d=3", "-vf", "select='if(lt(t,1),not(mod(n,2)),1)'", "-fps_mode", "vfr", "-c:v", "libx264", "-pix_fmt", "yuv420p", portrait)
ff("-display_rotation", "90", "-i", portrait, "-c", "copy", rotated)
rotated_probe = json.loads(run(CLI, "probe", rotated))
assert abs(rotated_probe["rotation"]) == 90
rotation_edit = project("rotated-vfr", [rotated], [(15, 75)])
rotation_out = OUT / "rotated-vfr.mp4"
run(CLI, "render", rotation_edit, rotation_out)
rotation_info = probe(rotation_out)
rotation_video = next(s for s in rotation_info["streams"] if s["codec_type"] == "video")
assert int(rotation_video["nb_read_frames"]) == 60
assert abs(float(rotation_info["format"]["duration"]) - 2) < 1/30
assert not any("rotation" in side for side in rotation_video.get("side_data_list", [])), "Output would rotate twice"
expected = ff("-ss", "0.7", "-i", rotated, "-frames:v", "1", "-vf", "scale=320:180:force_original_aspect_ratio=decrease:force_divisible_by=2,pad=320:180:(ow-iw)/2:(oh-ih)/2,setsar=1,scale=32:18", "-f", "rawvideo", "-pix_fmt", "rgb24", "pipe:1")
actual = ff("-ss", "0.2", "-i", rotation_out, "-frames:v", "1", "-vf", "scale=32:18", "-f", "rawvideo", "-pix_fmt", "rgb24", "pipe:1")
mean_error = sum(abs(a-b) for a,b in zip(expected, actual)) / len(expected)
assert mean_error < 15, ("Orientation/frame mismatch", mean_error)

# Exercise actual in-flight cancellation and ensure a previous output survives.
cancel_edit = project("cancel", [red] * 20, [(0, 90)] * 20, size=(1920, 1080))
cancel_out = OUT / "cancel-output.mp4"
sentinel = b"previous completed export"
cancel_out.write_bytes(sentinel)
process = subprocess.Popen([str(CLI), "render", str(cancel_edit), str(cancel_out)], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
time.sleep(.5)
assert process.poll() is None, "Cancellation test finished before signal"
process.send_signal(signal.SIGINT)
stdout, stderr = process.communicate(timeout=15)
assert process.returncode == 130, stderr
assert cancel_out.read_bytes() == sentinel
assert not list(OUT.glob(".*.mp4")), "Temporary output was not cleaned up"

report = {
    "two_clip_export": {"seconds": 2.5, "frames": 75, "color_cut_correct": True, "tone_then_silence": True},
    "delayed_audio_alignment": "passed",
    "rotated_variable_frame_rate_export": {"seconds": 2, "frames": 60, "orientation_mean_error": mean_error},
    "cancellation_preserves_previous_output": True,
    "note": "Synthetic local media; no Cardboard code, services, or account used. GUI is checked separately."
}
(OUT / "verification.json").write_text(json.dumps(report, indent=2))
print(json.dumps(report, indent=2))
