// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright 2026. See LICENSE and NOTICE.
import Foundation
import simd

/// Registers a separately estimated camera trajectory to the original ARKit world.
/// Agreement with ARKit establishes a coordinate/scale reference, not ground-truth accuracy.
nonisolated enum MetricCameraAlignment {
    struct Pair {
        var id: Int
        var estimated: simd_double4x4
        var reference: simd_double4x4
    }
    struct Result: Codable, Sendable {
        var scale: Double
        var rotationRowMajor: [Double]
        var translationMeters: [Double]
        var inlierIDs: [Int]
        var rejectedIDs: [Int]
        var medianPositionErrorMeters: Double
        var p90PositionErrorMeters: Double
        var medianRotationErrorDegrees: Double
        var referenceRadiusMeters: Double
        var rotation: simd_double3x3 {
            simd_double3x3(columns: (SIMD3(rotationRowMajor[0], rotationRowMajor[3], rotationRowMajor[6]),
                                    SIMD3(rotationRowMajor[1], rotationRowMajor[4], rotationRowMajor[7]),
                                    SIMD3(rotationRowMajor[2], rotationRowMajor[5], rotationRowMajor[8])))
        }
        var translation: SIMD3<Double> { SIMD3(translationMeters[0], translationMeters[1], translationMeters[2]) }
        func point(_ p: SIMD3<Double>) -> SIMD3<Double> { scale * (rotation * p) + translation }
        func camera(_ pose: simd_double4x4) -> simd_double4x4 {
            let r = rotation * MetricCameraAlignment.rotation(pose)
            return simd_double4x4(columns: (SIMD4(r.columns.0, 0), SIMD4(r.columns.1, 0),
                                            SIMD4(r.columns.2, 0), SIMD4(point(MetricCameraAlignment.position(pose)), 1)))
        }
    }
    enum Failure: String, Error { case invalidCameras, insufficientMotion, inconsistentTrajectories }
    static func matrix(_ values: [Double]) -> simd_double4x4? {
        guard values.count == 16, values.allSatisfy(\.isFinite) else { return nil }
        let m = simd_double4x4(columns: (SIMD4(values[0],values[4],values[8],values[12]),
                                       SIMD4(values[1],values[5],values[9],values[13]),
                                       SIMD4(values[2],values[6],values[10],values[14]),
                                       SIMD4(values[3],values[7],values[11],values[15])))
        return valid(m) ? m : nil
    }
    static func rowMajor(_ m: simd_double4x4) -> [Double] {
        (0..<4).flatMap { r in (0..<4).map { c in m[c][r] } }
    }
    static func position(_ m: simd_double4x4) -> SIMD3<Double> { SIMD3(m[3].x,m[3].y,m[3].z) }
    static func rotation(_ m: simd_double4x4) -> simd_double3x3 {
        simd_double3x3(columns: (SIMD3(m[0].x,m[0].y,m[0].z), SIMD3(m[1].x,m[1].y,m[1].z), SIMD3(m[2].x,m[2].y,m[2].z)))
    }
    static func valid(_ m: simd_double4x4) -> Bool {
        guard (0..<4).allSatisfy({ c in (0..<4).allSatisfy { m[c][$0].isFinite } }),
              abs(m[0].w) < 1e-4, abs(m[1].w) < 1e-4, abs(m[2].w) < 1e-4, abs(m[3].w-1) < 1e-4 else { return false }
        let r = rotation(m), eye = r.transpose * r
        return abs(simd_determinant(r)-1) < 0.005 &&
            (0..<3).allSatisfy { c in (0..<3).allSatisfy { abs(eye[c][$0] - (c == $0 ? 1 : 0)) < 0.005 } }
    }
    static func quantile(_ values: [Double], _ fraction: Double = 0.5) -> Double {
        guard !values.isEmpty else { return .infinity }
        let sorted = values.sorted()
        return sorted[min(sorted.count-1, Int(Double(sorted.count-1)*fraction))]
    }
    static func solve(_ pairs: [Pair]) throws -> Result {
        guard pairs.count >= 8, Set(pairs.map(\.id)).count == pairs.count,
              pairs.allSatisfy({ valid($0.estimated) && valid($0.reference) }) else { throw Failure.invalidCameras }
        func fit(_ selected: [Pair]) throws -> Result {
            // Camera orientations resolve rotation even for planar/linear camera paths.
            let quaternions = selected.map { simd_normalize(simd_quatd(rotation($0.reference) * rotation($0.estimated).transpose)) }
            let anchor = quaternions[0].vector
            let sum = quaternions.reduce(SIMD4<Double>(repeating: 0)) { $0 + (simd_dot($1.vector, anchor) < 0 ? -$1.vector : $1.vector) }
            guard simd_length(sum) > 1e-8 else { throw Failure.inconsistentTrajectories }
            let r = simd_double3x3(simd_quatd(vector: simd_normalize(sum)))
            let n = Double(selected.count)
            let a = selected.reduce(SIMD3<Double>(repeating: 0)) { $0 + position($1.estimated) } / n
            let b = selected.reduce(SIMD3<Double>(repeating: 0)) { $0 + position($1.reference) } / n
            let variance = selected.reduce(0.0) { $0 + simd_length_squared(position($1.estimated)-a) }
            let radius = sqrt(selected.reduce(0.0) { $0 + simd_length_squared(position($1.reference)-b) } / n)
            guard variance > 1e-12, radius >= 0.02 else { throw Failure.insufficientMotion }
            let scale = selected.reduce(0.0) { $0 + simd_dot(position($1.reference)-b, r*(position($1.estimated)-a)) } / variance
            guard scale.isFinite, scale > 1e-6, scale < 1e6 else { throw Failure.inconsistentTrajectories }
            let t = b-scale*(r*a)
            return Result(scale: scale, rotationRowMajor: (0..<3).flatMap { row in (0..<3).map { r[$0][row] } },
                          translationMeters: [t.x,t.y,t.z], inlierIDs: [], rejectedIDs: [], medianPositionErrorMeters: 0,
                          p90PositionErrorMeters: 0, medianRotationErrorDegrees: 0, referenceRadiusMeters: radius)
        }
        func errors(_ pair: Pair, _ result: Result) -> (Double, Double) {
            let delta = rotation(pair.reference).transpose * result.rotation * rotation(pair.estimated)
            let angle = 2 * acos(min(1, abs(simd_normalize(simd_quatd(delta)).real))) * 180 / .pi
            return (simd_length(result.point(position(pair.estimated))-position(pair.reference)), angle)
        }
        var selected = pairs
        for _ in 0..<4 {
            let fit = try fit(selected)
            let residuals = selected.map { errors($0, fit) }
            let limit = max(0.03, 3 * quantile(residuals.map { $0.0 }))
            let angularLimit = max(5, 3 * quantile(residuals.map { $0.1 }))
            let kept = selected.filter { let e = errors($0, fit); return e.0 <= limit && e.1 <= angularLimit }
            guard kept.count >= 8, kept.count * 5 >= pairs.count * 4 else { throw Failure.inconsistentTrajectories }
            if kept.count == selected.count { break }
            selected = kept
        }
        var result = try fit(selected)
        let residuals = selected.map { errors($0, result) }
        result.medianPositionErrorMeters = quantile(residuals.map { $0.0 })
        result.p90PositionErrorMeters = quantile(residuals.map { $0.0 }, 0.9)
        result.medianRotationErrorDegrees = quantile(residuals.map { $0.1 })
        guard result.medianPositionErrorMeters <= max(0.03, 0.03*result.referenceRadiusMeters),
              result.p90PositionErrorMeters <= max(0.08, 0.08*result.referenceRadiusMeters),
              result.medianRotationErrorDegrees <= 5 else { throw Failure.inconsistentTrajectories }
        result.inlierIDs = selected.map(\.id)
        let ids = Set(result.inlierIDs)
        result.rejectedIDs = pairs.filter { !ids.contains($0.id) }.map(\.id)
        return result
    }
}
