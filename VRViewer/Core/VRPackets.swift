import Foundation

/// Construcción de los paquetes binarios del protocolo "CVR".
/// IMPORTANTE: este archivo debe mantenerse byte a byte idéntico al
/// `VrUdpSender.doSendLoop()` de Android, o el driver de SteamVR no entiende nada.
enum VRPackets {

    // Puertos del protocolo (los mismos que usa el driver del PC).
    static let dataPort: UInt16 = 47291
    static let authPort: UInt16 = 47292
    static let controlPort: UInt16 = 47293
    static let announcePort: UInt16 = 47294
    static let streamPort: UInt16 = 47295
    static let qualityPort: UInt16 = 47296
    static let audioPort: UInt16 = 47298

    /// 49 floats = 196 bytes.
    static let dataPacketSize = 196

    /// Clave compartida HMAC del handshake (idéntica a la del driver).
    static let secret: [UInt8] = [
        0x4b, 0x3a, 0x1f, 0x08, 0xc2, 0x77, 0x9e, 0x34,
        0x05, 0xab, 0x61, 0xd9, 0xf8, 0x2e, 0x47, 0xbc
    ]

    /// Paquete de tracking (196 bytes, todos los floats little-endian).
    ///
    /// Layout:
    ///   0   : token de sesión (4 bytes tal cual los manda el PC)
    ///   4   : mano izquierda  (20 floats)
    ///   84  : mano derecha    (20 floats)
    ///   164 : HMD             (8 floats)
    static func dataPacket(token: [UInt8],
                           left: HandPose,
                           right: HandPose,
                           leftPad: GamepadState,
                           rightPad: GamepadState,
                           hmd: Quat,
                           hmdEnabled: Bool,
                           sixDof: HeadPose6DoF?,
                           sixDofEnabled: Bool) -> [UInt8] {

        var bytes = [UInt8](repeating: 0, count: dataPacketSize)

        bytes.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }

            func putFloat(_ value: Float, at index: Int) {
                base.storeBytes(of: value.bitPattern.littleEndian,
                                toByteOffset: index * 4,
                                as: UInt32.self)
            }

            // Token de sesión: se copian los 4 bytes crudos que devolvió el PC.
            for i in 0..<4 {
                base.storeBytes(of: token[i], toByteOffset: i, as: UInt8.self)
            }

            var slot = 1 // el slot 0 son los 4 bytes del token
            func put(_ value: Float) {
                putFloat(value, at: slot)
                slot += 1
            }

            func putHand(_ hand: HandPose, pad: GamepadState) {
                let trigger = max(pad.trigger, hand.pinch)
                let grip = max(pad.grip, hand.grip)

                put(hand.x)
                put(hand.y)
                put(hand.z)
                put(hand.quat.x)
                put(hand.quat.y)
                put(hand.quat.z)
                put(hand.quat.w)
                put(trigger)
                put(grip)
                put(pad.joyX)
                put(pad.joyY)
                put(pad.sysBtn ? 1 : 0)
                put(pad.appBtn ? 1 : 0)
                put(pad.clickBtn ? 1 : 0)
                put(hand.tracked ? 1 : 0)
                put(hand.curlThumb)
                put(hand.curlIndex)
                put(hand.curlMiddle)
                put(hand.curlRing)
                put(hand.curlPinky)
            }

            putHand(left, pad: leftPad)
            putHand(right, pad: rightPad)

            if sixDofEnabled, let pose = sixDof, pose.tracked {
                put(pose.x)
                put(pose.y)
                put(pose.z)
                put(pose.quat.x)
                put(pose.quat.y)
                put(pose.quat.z)
                put(pose.quat.w)
                put(1)
            } else if hmdEnabled {
                put(0)
                put(1.6)
                put(0)
                put(hmd.x)
                put(hmd.y)
                put(hmd.z)
                put(hmd.w)
                put(1)
            } else {
                put(0)
                put(1.6)
                put(0)
                put(0)
                put(0)
                put(0)
                put(1)
                put(0)
            }
        }

        return bytes
    }

    /// "QUAL" + width + height + bitrate + fps (13 bytes, big-endian).
    static func qualityPacket(width: Int, height: Int, bitrateBps: Int, fps: Int) -> [UInt8] {
        var bytes = [UInt8]()
        bytes.append(contentsOf: Array("QUAL".utf8))

        func putShort(_ v: UInt16) {
            bytes.append(UInt8((v >> 8) & 0xFF))
            bytes.append(UInt8(v & 0xFF))
        }
        func putInt(_ v: UInt32) {
            bytes.append(UInt8((v >> 24) & 0xFF))
            bytes.append(UInt8((v >> 16) & 0xFF))
            bytes.append(UInt8((v >> 8) & 0xFF))
            bytes.append(UInt8(v & 0xFF))
        }

        putShort(UInt16(clamping: width))
        putShort(UInt16(clamping: height))
        putInt(UInt32(clamping: bitrateBps))
        bytes.append(UInt8(clamping: fps))
        return bytes
    }
}

/// Presets de calidad de stream, iguales a los del proyecto Android.
enum StreamQuality {
    struct ResolutionPreset {
        let label: String
        let width: Int
        let height: Int
    }

    static let resolutions: [ResolutionPreset] = [
        ResolutionPreset(label: "854×480", width: 854, height: 480),
        ResolutionPreset(label: "1280×720", width: 1280, height: 720),
        ResolutionPreset(label: "1600×900", width: 1600, height: 900),
        ResolutionPreset(label: "1920×1080", width: 1920, height: 1080)
    ]

    static let fpsOptions = [30, 45, 60]

    static let bitrateMin = 2.0
    static let bitrateMax = 12.0
    static let bitrateStep = 1.0
}
