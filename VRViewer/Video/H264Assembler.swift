import CoreMedia
import Foundation

/// Convierte el flujo H.264 del PC (NALs sueltos, Annex-B o AVCC) en
/// CMSampleBuffers listos para `AVSampleBufferDisplayLayer`.
final class H264Assembler {

    private var sps: Data?
    private var pps: Data?
    private var formatDescription: CMVideoFormatDescription?
    private var needsFormat = true

    func reset() {
        sps = nil
        pps = nil
        formatDescription = nil
        needsFormat = true
    }

    func sampleBuffer(from packet: Data) -> CMSampleBuffer? {
        let units = Self.nalUnits(in: packet)
        guard !units.isEmpty else { return nil }

        var hasPicture = false
        for unit in units {
            guard let first = unit.first else { continue }
            switch first & 0x1F {
            case 7:
                sps = unit
                needsFormat = true
            case 8:
                pps = unit
                needsFormat = true
            case 1, 5:
                hasPicture = true
            default:
                break
            }
        }

        if needsFormat {
            rebuildFormatDescription()
        }

        guard hasPicture, let format = formatDescription else { return nil }

        let avcc = Self.avcc(from: units)
        guard !avcc.isEmpty else { return nil }

        return Self.makeSampleBuffer(avcc: avcc, format: format)
    }

    // MARK: - Formato

    private func rebuildFormatDescription() {
        guard let sps, let pps, !sps.isEmpty, !pps.isEmpty else { return }

        var description: CMVideoFormatDescription?
        let status: OSStatus = sps.withUnsafeBytes { spsRaw -> OSStatus in
            pps.withUnsafeBytes { ppsRaw -> OSStatus in
                guard let spsBase = spsRaw.bindMemory(to: UInt8.self).baseAddress,
                      let ppsBase = ppsRaw.bindMemory(to: UInt8.self).baseAddress else {
                    return -1
                }
                var pointers: [UnsafePointer<UInt8>] = [spsBase, ppsBase]
                var sizes: [Int] = [sps.count, pps.count]
                return pointers.withUnsafeMutableBufferPointer { pointerBuffer -> OSStatus in
                    sizes.withUnsafeMutableBufferPointer { sizeBuffer -> OSStatus in
                        guard let pointerBase = pointerBuffer.baseAddress,
                              let sizeBase = sizeBuffer.baseAddress else { return -1 }
                        return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                            allocator: kCFAllocatorDefault,
                            parameterSetCount: 2,
                            parameterSetPointers: pointerBase,
                            parameterSetSizes: sizeBase,
                            nalUnitHeaderLength: 4,
                            formatDescriptionOut: &description
                        )
                    }
                }
            }
        }

        if status == noErr, let description {
            formatDescription = description
            needsFormat = false
        }
    }

    // MARK: - NAL

    private static func nalUnits(in data: Data) -> [Data] {
        let bytes = [UInt8](data)
        guard bytes.count > 4 else { return [] }

        // Annex B: 00 00 00 01 / 00 00 01
        if bytes[0] == 0, bytes[1] == 0, bytes[2] == 0, bytes[3] == 1
            || (bytes[0] == 0 && bytes[1] == 0 && bytes[2] == 1) {
            return annexBSplit(bytes)
        }

        // AVCC: longitud de 4 bytes por delante
        let length = (Int(bytes[0]) << 24) | (Int(bytes[1]) << 16) | (Int(bytes[2]) << 8) | Int(bytes[3])
        if length > 0, length <= bytes.count - 4 {
            return avccSplit(bytes)
        }

        // Un único NAL sin start code
        return [data]
    }

    private static func annexBSplit(_ bytes: [UInt8]) -> [Data] {
        var starts: [(offset: Int, size: Int)] = []
        var index = 0
        while index + 2 < bytes.count {
            if bytes[index] == 0, bytes[index + 1] == 0 {
                if bytes[index + 2] == 1 {
                    starts.append((index, 3))
                    index += 3
                    continue
                }
                if index + 3 < bytes.count, bytes[index + 2] == 0, bytes[index + 3] == 1 {
                    starts.append((index, 4))
                    index += 4
                    continue
                }
            }
            index += 1
        }

        guard !starts.isEmpty else { return [Data(bytes)] }

        var units: [Data] = []
        for (position, start) in starts.enumerated() {
            let payloadStart = start.offset + start.size
            let payloadEnd = position + 1 < starts.count ? starts[position + 1].offset : bytes.count
            if payloadEnd > payloadStart {
                units.append(Data(bytes[payloadStart..<payloadEnd]))
            }
        }
        return units
    }

    private static func avccSplit(_ bytes: [UInt8]) -> [Data] {
        var units: [Data] = []
        var offset = 0
        while offset + 4 <= bytes.count {
            let length = (Int(bytes[offset]) << 24) | (Int(bytes[offset + 1]) << 16)
                | (Int(bytes[offset + 2]) << 8) | Int(bytes[offset + 3])
            offset += 4
            guard length > 0, offset + length <= bytes.count else { break }
            units.append(Data(bytes[offset..<(offset + length)]))
            offset += length
        }
        return units
    }

    private static func avcc(from units: [Data]) -> Data {
        var output = Data()
        for unit in units where !unit.isEmpty {
            let length = UInt32(unit.count).bigEndian
            withUnsafeBytes(of: length) { output.append(contentsOf: $0) }
            output.append(unit)
        }
        return output
    }

    // MARK: - Sample buffer

    private static func makeSampleBuffer(avcc: Data, format: CMVideoFormatDescription) -> CMSampleBuffer? {
        let length = avcc.count
        var blockBuffer: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault,
                                                        memoryBlock: nil,
                                                        blockLength: length,
                                                        blockAllocator: kCFAllocatorDefault,
                                                        customBlockSource: nil,
                                                        offsetToData: 0,
                                                        dataLength: length,
                                                        flags: 0,
                                                        blockBufferOut: &blockBuffer)
        guard status == kCMBlockBufferNoErr, let block = blockBuffer else { return nil }

        status = avcc.withUnsafeBytes { raw -> OSStatus in
            guard let base = raw.baseAddress else { return -1 }
            return CMBlockBufferReplaceDataBytes(with: base,
                                                 blockBuffer: block,
                                                 offsetIntoDestination: 0,
                                                 dataLength: length)
        }
        guard status == kCMBlockBufferNoErr else { return nil }

        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 60),
                                        presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
                                        decodeTimeStamp: .invalid)
        var sampleSize = length
        var sampleBuffer: CMSampleBuffer?
        status = CMSampleBufferCreateReady(allocator: kCFAllocatorDefault,
                                           dataBuffer: block,
                                           formatDescription: format,
                                           sampleCount: 1,
                                           sampleTimingEntryCount: 1,
                                           sampleTimingArray: &timing,
                                           sampleSizeEntryCount: 1,
                                           sampleSizeArray: &sampleSize,
                                           sampleBufferOut: &sampleBuffer)
        guard status == kCMBlockBufferNoErr, let buffer = sampleBuffer else { return nil }

        if let attachments = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0),
                                           to: CFMutableDictionary.self)
            CFDictionarySetValue(dictionary,
                                 Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }

        return buffer
    }
}
