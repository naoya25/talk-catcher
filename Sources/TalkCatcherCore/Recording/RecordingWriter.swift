import AVFoundation

public enum RecordingWriterError: Error {
  case unsupportedFormat
}

final class RecordingWriter {
  private static let pcmFormat = AVAudioFormat(
    commonFormat: .pcmFormatFloat32,
    sampleRate: AudioFormat.sampleRate,
    channels: 1,
    interleaved: false
  )

  private let partialURL: URL
  private var file: AVAudioFile?
  private(set) var writtenFrames: AVAudioFramePosition = 0

  init(partialURL: URL) throws {
    guard let format = Self.pcmFormat else { throw RecordingWriterError.unsupportedFormat }
    try FileManager.default.createDirectory(
      at: partialURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    self.partialURL = partialURL
    file = try AVAudioFile(
      forWriting: partialURL, settings: format.settings, commonFormat: .pcmFormatFloat32,
      interleaved: false)
  }

  func append(_ samples: [Float]) throws {
    guard let file, let format = Self.pcmFormat,
      let buffer = AVAudioPCMBuffer(
        pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
      let channel = buffer.floatChannelData
    else { throw RecordingWriterError.unsupportedFormat }
    for (offset, sample) in samples.enumerated() { channel[0][offset] = sample }
    buffer.frameLength = AVAudioFrameCount(samples.count)
    try file.write(from: buffer)
    writtenFrames += AVAudioFramePosition(samples.count)
  }

  func finish(keepingFrames frames: AVAudioFramePosition, to destination: URL) throws {
    file = nil
    defer { try? FileManager.default.removeItem(at: partialURL) }

    let source = try AVAudioFile(
      forReading: partialURL, commonFormat: .pcmFormatFloat32, interleaved: false)
    let settings: [String: Any] = [
      AVFormatIDKey: kAudioFormatMPEG4AAC,
      AVSampleRateKey: AudioFormat.sampleRate,
      AVNumberOfChannelsKey: 1,
      AVEncoderBitRateKey: 48_000,
    ]
    let output = try AVAudioFile(
      forWriting: destination, settings: settings, commonFormat: .pcmFormatFloat32,
      interleaved: false)
    let blockFrames: AVAudioFrameCount = 160_000
    var remaining = min(frames, source.length)
    guard
      let buffer = AVAudioPCMBuffer(pcmFormat: source.processingFormat, frameCapacity: blockFrames)
    else {
      throw RecordingWriterError.unsupportedFormat
    }
    while remaining > 0 {
      try source.read(
        into: buffer,
        frameCount: AVAudioFrameCount(min(AVAudioFramePosition(blockFrames), remaining)))
      if buffer.frameLength == 0 { break }
      try output.write(from: buffer)
      remaining -= AVAudioFramePosition(buffer.frameLength)
    }
  }

  func discard() {
    file = nil
    try? FileManager.default.removeItem(at: partialURL)
  }
}
