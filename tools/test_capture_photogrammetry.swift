// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright 2026. See LICENSE and NOTICE.
import Foundation
import CoreVideo
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import simd

private func check(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !value() { throw NSError(domain: message, code: 1) }
}
private func rejects(_ message: String, _ body: () throws -> Void) throws {
    do { try body() } catch { return }
    throw NSError(domain: "Accepted invalid input: " + message, code: 1)
}
private func frame(_ id: Int, _ pose: simd_double4x4) -> FrameRecord {
    FrameRecord(id: id, timestamp: Double(id), transform: MetricCameraAlignment.rowMajor(pose),
                intrinsics: CameraIntrinsics(fx: 100, fy: 100, cx: 100, cy: 100, width: 200, height: 200),
                exposureDuration: 0.01, exposureOffsetEV: 0, estimatedBlurPx: 0, imageFile: "frame_\(id).jpg")
}
@available(macOS 26.0, *)
private func selfTest() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("camera-estimation-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    let rotation = simd_double3x3(simd_quatd(angle: 0.4, axis: simd_normalize(SIMD3(1,2,3))))
    let translation = SIMD3<Double>(3, -1, 2)
    let scale = 2.5
    var pairs: [MetricCameraAlignment.Pair] = []
    for i in 0..<12 {
        var estimated = matrix_identity_double4x4
        estimated.columns.3 = SIMD4(Double(i)*0.025, sin(Double(i))*0.03, 0, 1)
        let p = scale * rotation * MetricCameraAlignment.position(estimated) + translation
        let reference = simd_double4x4(columns: (SIMD4(rotation[0],0),SIMD4(rotation[1],0),SIMD4(rotation[2],0),SIMD4(p,1)))
        pairs.append(.init(id: i, estimated: estimated, reference: reference))
    }
    let alignment = try MetricCameraAlignment.solve(pairs)
    try check(abs(alignment.scale-scale) < 1e-8 && alignment.medianPositionErrorMeters < 1e-8, "known metric similarity")
    for pair in pairs {
        let actual = alignment.camera(pair.estimated)
        try check(MetricCameraAlignment.valid(actual), "scale must not enter camera rotation")
        try check(simd_length(actual[3]-pair.reference[3]) < 1e-8, "camera centers in original world")
    }
    var outliers = pairs; outliers[11].reference.columns.3.x += 3
    try check(try MetricCameraAlignment.solve(outliers).rejectedIDs == [11], "reject isolated bad correspondence")
    var still = pairs
    for i in still.indices { still[i].reference = still[0].reference }
    try rejects("stationary trajectory") { _ = try MetricCameraAlignment.solve(still) }
    var inconsistent = pairs
    for i in inconsistent.indices { inconsistent[i].reference.columns.3.y += i % 2 == 0 ? 0.3 : -0.3 }
    let disagreement = try MetricCameraAlignment.solve(inconsistent)
    try check(disagreement.medianPositionErrorMeters > 0.03 && disagreement.warnings?.contains("trajectory_disagreement_not_accuracy_failure") == true,
              "large disagreement is diagnostic, not proof RealityKit is wrong")
    var reflection = matrix_identity_double4x4; reflection[0][0] = -1
    try check(!MetricCameraAlignment.valid(reflection), "reflection is not a camera rotation")
    print("PASS metric registration, rigid cameras, outlier and degeneracy rejection")

    let k = simd_float3x3(columns: (SIMD3(50,0,0),SIMD3(0,50,0),SIMD3(50,50,1)))
    let inputs = pairs.map { CapturePhotogrammetrySamples.Input(record: frame($0.id,$0.reference), image: root.appendingPathComponent("unused"), depth: nil, confidence: nil, width: 100, height: 100) }
    var raw = pairs.map { p -> VideoPhotogrammetry.RawPose in
        let m = simd_float4x4(columns: (SIMD4<Float>(p.estimated[0]),SIMD4<Float>(p.estimated[1]),SIMD4<Float>(p.estimated[2]),SIMD4<Float>(p.estimated[3]))) * VideoPhotogrammetry.yzFlip()
        return .init(sampleID: p.id,imageFile:inputs[p.id].record.imageFile,timestamp:Double(p.id),translation:[],rotationIXIYIZR:[],transformColumnMajor:VideoPhotogrammetry.matrixColumnMajor(m),intrinsicsColumnMajor:VideoPhotogrammetry.matrixColumnMajor(k),lensDistortion:nil)
    }
    let points = (0..<20).map { VideoPhotogrammetry.Point(position: SIMD3(Float($0)*0.01,0,-2),rgb:SIMD3(10,20,30)) }
    let output = try CapturePhotogrammetry.align(raw:raw,points:points,inputs:inputs)
    try check(output.cameras.count == 12, "one result per valid saved keyframe")
    for camera in output.cameras {
        let c2w = MetricCameraAlignment.matrix(camera.transform)!
        let w2c = MetricCameraAlignment.matrix(camera.worldToCamera)!
        let cv = MetricCameraAlignment.matrix(camera.opencvWorldToCamera)!
        try check(camera.intrinsics.fx == 100 && camera.intrinsics.width == 200, "K restored to native pixels")
        let local = SIMD4<Double>(0.1,0.2,-2,1), world = c2w*local
        try check(simd_length(w2c*world-local) < 1e-8, "w2c inverse")
        try check(simd_length(cv*world-SIMD4(0.1,-0.2,2,1)) < 1e-8, "OpenCV conversion exactly once")
    }
    var fitInputs = inputs
    fitInputs[11] = .init(record:frame(11,outliers[11].reference),image:inputs[11].image,depth:nil,confidence:nil,width:100,height:100)
    let retained = try CapturePhotogrammetry.align(raw:raw,points:points,inputs:fitInputs)
    try check(retained.alignment.rejectedIDs == [11] && retained.cameras.count == 12,
              "fit exclusions must not delete usable camera estimates")
    try check(simd_length(MetricCameraAlignment.position(MetricCameraAlignment.matrix(retained.cameras[11].transform)!)-MetricCameraAlignment.position(outliers[11].reference)) > 2.9,
              "global alignment must preserve local trajectory differences")
    raw.removeLast()
    try check(try CapturePhotogrammetry.align(raw:raw,points:points,inputs:inputs).cameras.count == 11, "no fabricated missing poses")
    raw.append(raw[0])
    try rejects("duplicate sample ID") { _ = try CapturePhotogrammetry.align(raw:raw,points:points,inputs:inputs) }
    print("PASS per-frame correspondence, image-scaled K, camera conventions and missing frames")

    // Symmetric room points do not reveal the camera's forward axis. The known
    // rotating reference trajectory must resolve the convention without a position gate.
    var roomInputs: [CapturePhotogrammetrySamples.Input] = []
    var roomRaw: [VideoPhotogrammetry.RawPose] = []
    for i in 0..<12 {
        let r = simd_double3x3(simd_quatd(angle: Double(i)*0.4,axis:SIMD3(0,1,0)))
        let p = SIMD3<Double>(cos(Double(i)*0.4)*0.1,0,sin(Double(i)*0.4)*0.1)
        let m = simd_double4x4(columns:(SIMD4(r[0],0),SIMD4(r[1],0),SIMD4(r[2],0),SIMD4(p,1)))
        let ref = alignment.camera(m)
        roomInputs.append(.init(record:frame(i,ref),image:root.appendingPathComponent("unused"),depth:nil,confidence:nil,width:100,height:100))
        let mf = simd_float4x4(columns:(SIMD4<Float>(m[0]),SIMD4<Float>(m[1]),SIMD4<Float>(m[2]),SIMD4<Float>(m[3])))
        roomRaw.append(.init(sampleID:i,imageFile:frame(i,ref).imageFile,timestamp:Double(i),translation:[],rotationIXIYIZR:[],transformColumnMajor:VideoPhotogrammetry.matrixColumnMajor(mf),intrinsicsColumnMajor:VideoPhotogrammetry.matrixColumnMajor(k),lensDistortion:nil))
    }
    let roomPoints = (0..<120).map { i in VideoPhotogrammetry.Point(position:SIMD3(cos(Float(i)*Float.pi/60)*2,0,sin(Float(i)*Float.pi/60)*2),rgb:SIMD3(1,2,3)) }
    let room = try CapturePhotogrammetry.align(raw:roomRaw,points:roomPoints,inputs:roomInputs)
    try check(room.cameras.count == 12 && room.coordinateAdaptation == "direct_pose_as_gl_c2w", "measured camera correspondence resolves surrounding scene")
    print("PASS axis disambiguation using a rotating metric reference in a surrounding scene")

    // Red upper half / blue lower half detects a vertical flip against sensor depth.
    var pixels = Data()
    for y in 0..<200 { for _ in 0..<200 { pixels.append(contentsOf: y < 100 ? [255,0,0] : [0,0,255]) } }
    let image = CGImage(width:200,height:200,bitsPerComponent:8,bitsPerPixel:24,bytesPerRow:600,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:[],provider:CGDataProvider(data:pixels as CFData)!,decode:nil,shouldInterpolate:false,intent:.defaultIntent)!
    let imageURL = root.appendingPathComponent("sample.jpg")
    let destination = CGImageDestinationCreateWithURL(imageURL as CFURL,UTType.jpeg.identifier as CFString,1,nil)!
    CGImageDestinationAddImage(destination,image,[kCGImagePropertyOrientation:1] as CFDictionary)
    try check(CGImageDestinationFinalize(destination), "test JPEG")
    let depthURL = root.appendingPathComponent("depth.bin"), confidenceURL = root.appendingPathComponent("confidence.bin")
    var depth = Data()
    for v: Float in [1,2,3,4] { var bits = v.bitPattern.littleEndian; withUnsafeBytes(of:&bits) { depth.append(contentsOf:$0) } }
    try depth.write(to:depthURL); try Data([2,0,1,2]).write(to:confidenceURL)
    var record = inputs[0].record; record.depthWidth = 2; record.depthHeight = 2
    let input = CapturePhotogrammetrySamples.Input(record:record,image:imageURL,depth:depthURL,confidence:confidenceURL,width:100,height:100)
    let sequence = CapturePhotogrammetrySamples(inputs:[input])
    let sample = try sequence.sample(input)
    CVPixelBufferLockBaseAddress(sample.image, .readOnly)
    let rgb = CVPixelBufferGetBaseAddress(sample.image)!.assumingMemoryBound(to:UInt8.self)
    let stride = CVPixelBufferGetBytesPerRow(sample.image)
    try check(rgb[10*stride+10*4+2] > 200 && rgb[90*stride+10*4] > 200, "image/depth vertical orientation")
    CVPixelBufferUnlockBaseAddress(sample.image,.readOnly)
    let d = sample.depthDataMap!
    CVPixelBufferLockBaseAddress(d,.readOnly)
    let base = CVPixelBufferGetBaseAddress(d)!
    func value(_ x: Int,_ y: Int) -> Float { base.advanced(by:y*CVPixelBufferGetBytesPerRow(d)).assumingMemoryBound(to:Float.self)[x] }
    try check(value(10,10) == 1 && value(90,10).isNaN && value(10,90) == 3 && value(90,90) == 4, "metric depth/confidence alignment")
    CVPixelBufferUnlockBaseAddress(d,.readOnly)
    try check(sequence.suppliedDepthIDs == [0], "depth provenance")
    try Data([2,3,1,2]).write(to:confidenceURL)
    try rejects("bad confidence") { _ = try sequence.depthBuffer(input) }
    try Data([0,0,0,0]).write(to:confidenceURL)
    try check(try sequence.depthBuffer(input) == nil, "do not invent empty depth")
    sequence.cancel(); var iterator = sequence.makeIterator()
    try check(iterator.next() == nil, "cancel lazy sample loading")
    print("PASS image orientation, same-frame metric depth, confidence masking and lazy cancellation")

    try rejects("path traversal") { _ = try CapturePhotogrammetry.file("../outside",under:root) }
    try check(try CapturePhotogrammetry.file("sample.jpg",under:URL(fileURLWithPath:root.path)).path == imageURL.path, "directory URL slash must not reject valid files")
    let link = root.appendingPathComponent("linked.jpg")
    try FileManager.default.createSymbolicLink(at:link,withDestinationURL:imageURL)
    try rejects("symbolic link") { _ = try CapturePhotogrammetry.file("linked.jpg",under:root) }
    let encoder = JSONEncoder()
    var rows = Data()
    for r in inputs.map(\.record) { rows.append(try encoder.encode(r)); rows.append(10) }
    try check(try CapturePhotogrammetry.records(rows).count == 12, "raw records decode")
    var duplicate = rows; duplicate.append(try encoder.encode(inputs[0].record))
    try rejects("duplicate raw records") { _ = try CapturePhotogrammetry.records(duplicate) }
    let report = try await CapturePhotogrammetry.run(directory:root)
    try check(report.status == "failed" && report.cameraFile == nil, "invalid capture never published")
    print("PASS malformed-source guards and failed report without estimated parameters")
}

@main struct CapturePhotogrammetryTests {
    static func main() async throws {
        guard #available(macOS 26.0, *) else { throw NSError(domain:"Requires macOS 26 or later",code:1) }
        let args = Array(CommandLine.arguments.dropFirst())
        if args.isEmpty { try await selfTest(); return }
        try check(args.count == 3 && ["--replay","--cancel"].contains(args[0]), "usage: --replay|--cancel SOURCE NEW_OUTPUT")
        let source = URL(fileURLWithPath:args[1]), output = URL(fileURLWithPath:args[2])
        try check(!FileManager.default.fileExists(atPath:output.path), "replay output must be new")
        try FileManager.default.copyItem(at:source,to:output)
        let before = try Data(contentsOf:output.appendingPathComponent("poses.jsonl"))
        let task = Task { try await CapturePhotogrammetry.run(directory:output) { print("progress \($0)") } }
        if args[0] == "--cancel" { try await Task.sleep(for:.milliseconds(500)); task.cancel() }
        do {
            let report = try await task.value
            print(String(data:try JSONEncoder().encode(report),encoding:.utf8)!)
            try check(args[0] != "--cancel", "cancellation must throw")
        } catch is CancellationError {
            try check(CapturePhotogrammetry.readReport(in:output)?.status == "cancelled", "cancellation acknowledgement")
            print("PASS actual RealityKit cancellation")
        }
        try check(try Data(contentsOf:output.appendingPathComponent("poses.jsonl")) == before, "original camera bytes changed")
    }
}
