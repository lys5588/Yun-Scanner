#!/bin/bash
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
# Copyright 2026. See LICENSE and NOTICE.
set -euo pipefail
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
mkdir -p "$root/.build/video-frame-tests"
xcrun --sdk macosx swiftc -Onone -module-cache-path "${TMPDIR:-/tmp}/fable-swift-cache" \
  "$root/arkit-3dgs-scanner/Capture"/{Models,BlurFilter,Localization,FrameWriter,CaptureStreamRecorder,CaptureVideoFrames}.swift \
  "$root/tools/test_capture_video_frames.swift" -o "$root/.build/video-frame-tests/test"
"$root/.build/video-frame-tests/test" "$@"
