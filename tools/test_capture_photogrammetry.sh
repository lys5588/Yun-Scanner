#!/bin/bash
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
# Copyright 2026. See LICENSE and NOTICE.
set -euo pipefail
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
mkdir -p "$root/.build/camera-estimation-tests"
xcrun --sdk macosx swiftc -Onone -module-cache-path "${TMPDIR:-/tmp}/fable-swift-cache" \
  "$root/arkit-3dgs-scanner/Capture"/{Models,BlurFilter,MetricCameraAlignment,CapturePhotogrammetrySamples,CapturePhotogrammetry}.swift \
  "$root/arkit-3dgs-scanner/VideoImport/VideoPhotogrammetry.swift" \
  "$root/tools/test_capture_photogrammetry.swift" -o "$root/.build/camera-estimation-tests/test"
"$root/.build/camera-estimation-tests/test" "$@"
