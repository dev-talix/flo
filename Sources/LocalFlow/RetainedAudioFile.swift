import AVFoundation

enum RetainedAudioFile {
    static func write(samples: [Float], sampleRate: Double, to url: URL) throws {
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try writePCM(samples: samples, sampleRate: sampleRate, to: temporary)
        // Publish only after AVAudioFile closes and finalizes the header.
        if FileManager.default.fileExists(atPath: url.path) {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
        } else {
            try FileManager.default.moveItem(at: temporary, to: url)
        }
    }

    private static func writePCM(samples: [Float], sampleRate: Double, to url: URL) throws {
        guard sampleRate.isFinite, sampleRate > 0,
              let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                                         channels: 1, interleaved: false),
              FileManager.default.createFile(atPath: url.path, contents: Data(), attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        guard !samples.isEmpty else { return }
        let capacity = min(samples.count, 16_384)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(capacity)),
              let channel = buffer.floatChannelData?[0] else { throw CocoaError(.fileWriteUnknown) }
        try samples.withUnsafeBufferPointer { source in
            var offset = 0
            while offset < source.count {
                let count = min(capacity, source.count - offset)
                channel.update(from: source.baseAddress!.advanced(by: offset), count: count)
                buffer.frameLength = AVAudioFrameCount(count)
                try file.write(from: buffer)
                offset += count
            }
        }
    }
}
