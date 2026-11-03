#!/bin/bash
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
# Copyright 2026. See LICENSE and NOTICE.
set -euo pipefail
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
mkdir -p "$root/.build/beta-tests"
capture="$root/arkit-3dgs-scanner/Capture"
training="$root/arkit-3dgs-scanner/Training"
swiftc -Onone -module-cache-path "${TMPDIR:-/tmp}/fable-swift-cache" \
  "$capture"/{Localization,Models,BlurFilter,CaptureConfig,DepthSampleFilter,RefusionEngine,SurfaceTSDF,ExportManager,TrainingFrameSelector,MetricCameraAlignment}.swift \
  "$root/arkit-3dgs-scanner/History"/{ScanLibrary,GaussianModelImport}.swift "$training"/*.swift \
  "$root/arkit-3dgs-scanner/Beta/"{BetaSceneArchive,BetaReconstructionExport}.swift "$root/tools/test_beta_scene.swift" "$root/tools/test_beta_filtered_export.swift" \
  -o "$root/.build/beta-tests/test_beta_scene"
"$root/.build/beta-tests/test_beta_scene" "$@"
