import Foundation

enum VRMath {

    /// Convierte una matriz 3x3 en fila-mayor (R0..R8) a cuaternión.
    /// Misma implementación que `matrixToQuaternion` del proyecto Android.
    static func quaternion(fromMatrix m: [Float]) -> Quat {
        guard m.count >= 9 else { return .identity }
        let m00 = m[0], m01 = m[1], m02 = m[2]
        let m10 = m[3], m11 = m[4], m12 = m[5]
        let m20 = m[6], m21 = m[7], m22 = m[8]

        var x: Float = 0, y: Float = 0, z: Float = 0, w: Float = 1
        let trace = m00 + m11 + m22

        if trace > 0 {
            let s = 0.5 / (trace + 1).squareRoot()
            w = 0.25 / s
            x = (m21 - m12) * s
            y = (m02 - m20) * s
            z = (m10 - m01) * s
        } else if m00 > m11 && m00 > m22 {
            let s = 2 * (1 + m00 - m11 - m22).squareRoot()
            w = (m21 - m12) / s
            x = 0.25 * s
            y = (m01 + m10) / s
            z = (m02 + m20) / s
        } else if m11 > m22 {
            let s = 2 * (1 + m11 - m00 - m22).squareRoot()
            w = (m02 - m20) / s
            x = (m01 + m10) / s
            y = 0.25 * s
            z = (m12 + m21) / s
        } else {
            let s = 2 * (1 + m22 - m00 - m11).squareRoot()
            w = (m10 - m01) / s
            x = (m02 + m20) / s
            y = (m12 + m21) / s
            z = 0.25 * s
        }

        let q = Quat(x: x, y: y, z: z, w: w)
        return q.length < 1e-6 ? .identity : q.normalized
    }

    /// Remapeo de ejes equivalente a
    /// `SensorManager.remapCoordinateSystem(R, AXIS_MINUS_Y, AXIS_X, out)`.
    static func remapMinusYAxisX(_ m: [Float]) -> [Float] {
        guard m.count >= 9 else { return m }
        return [
            -m[3], -m[4], -m[5],
             m[0],  m[1],  m[2],
             m[6],  m[7],  m[8]
        ]
    }

    static func clamp(_ value: Float, _ low: Float, _ high: Float) -> Float {
        min(max(value, low), high)
    }

    static func mapRange(_ v: Float, _ i0: Float, _ i1: Float, _ o0: Float, _ o1: Float) -> Float {
        let c = clamp(v, min(i0, i1), max(i0, i1))
        if abs(i1 - i0) < 1e-9 { return o0 }
        return o0 + (c - i0) / (i1 - i0) * (o1 - o0)
    }

    static func dot3(_ a: [Float], _ b: [Float]) -> Float {
        a[0] * b[0] + a[1] * b[1] + a[2] * b[2]
    }

    static func cross3(_ a: [Float], _ b: [Float]) -> [Float] {
        [
            a[1] * b[2] - a[2] * b[1],
            a[2] * b[0] - a[0] * b[2],
            a[0] * b[1] - a[1] * b[0]
        ]
    }

    static func normalize3(_ v: [Float]) -> [Float] {
        let len = (v[0] * v[0] + v[1] * v[1] + v[2] * v[2]).squareRoot()
        guard len > 1e-6 else { return [0, 1, 0] }
        return [v[0] / len, v[1] / len, v[2] / len]
    }

    /// Base ortonormal (x, y, z) -> cuaternión.
    static func quaternion(xAxis: [Float], yAxis: [Float], zAxis: [Float]) -> Quat {
        let m: [Float] = [
            xAxis[0], yAxis[0], zAxis[0],
            xAxis[1], yAxis[1], zAxis[1],
            xAxis[2], yAxis[2], zAxis[2]
        ]
        return quaternion(fromMatrix: m)
    }
}

/// Filtro One Euro (mismo comportamiento que `OneEurofilter.kt`).
final class OneEuroFilter {
    private let minCutoff: Float
    private let beta: Float
    private let dCutoff: Float

    private var xPrev: Float?
    private var dxPrev: Float = 0
    private var tPrev: Double = 0

    init(minCutoff: Float = 1.0, beta: Float = 0.03, dCutoff: Float = 1.0) {
        self.minCutoff = minCutoff
        self.beta = beta
        self.dCutoff = dCutoff
    }

    private func alpha(cutoff: Float, dt: Float) -> Float {
        let tau = 1 / (2 * Float.pi * max(cutoff, 1e-4))
        return 1 / (1 + tau / dt)
    }

    func filter(_ x: Float, timestampMs: Double) -> Float {
        guard let prev = xPrev else {
            xPrev = x
            tPrev = timestampMs
            return x
        }

        let dtMs = max(timestampMs - tPrev, 1)
        let dt = Float(dtMs / 1000.0)
        tPrev = timestampMs

        let dx = (x - prev) / dt
        let aD = alpha(cutoff: dCutoff, dt: dt)
        let dxHat = aD * dx + (1 - aD) * dxPrev
        dxPrev = dxHat

        let cutoff = minCutoff + beta * abs(dxHat)
        let a = alpha(cutoff: cutoff, dt: dt)
        let xHat = a * x + (1 - a) * prev
        xPrev = xHat
        return xHat
    }

    func reset() {
        xPrev = nil
        dxPrev = 0
        tPrev = 0
    }
}
