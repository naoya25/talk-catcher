import AVFoundation
import Foundation
import Testing

@testable import TalkCatcherCore

private let modelURL = URL(filePath: #filePath)
  .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
  .appending(path: "Resources/silero_vad.onnx")

private func chunks(of samples: [Float]) -> [[Float]] {
  stride(from: 0, to: samples.count - AudioFormat.chunkSize + 1, by: AudioFormat.chunkSize).map {
    Array(samples[$0..<$0 + AudioFormat.chunkSize])
  }
}

private func synthesizedSpeech() throws -> [Float] {
  let url = FileManager.default.temporaryDirectory.appending(
    path: "talk-catcher-say-\(UUID().uuidString).wav")
  defer { try? FileManager.default.removeItem(at: url) }
  let say = Process()
  say.executableURL = URL(filePath: "/usr/bin/say")
  say.arguments = [
    "-v", "Kyoko", "-o", url.path, "--file-format=WAVE", "--data-format=LEF32@16000",
    "おはようございます。今日の会議の資料はもう共有しましたか",
  ]
  try say.run()
  say.waitUntilExit()
  let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
  let buffer = try #require(
    AVAudioPCMBuffer(
      pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
  try file.read(into: buffer)
  let channel = try #require(buffer.floatChannelData)
  return Array(UnsafeBufferPointer(start: channel[0], count: Int(buffer.frameLength)))
}

@Suite(
  .enabled(
    if: FileManager.default.fileExists(atPath: modelURL.path), "scripts/fetch-model.sh でモデルを取ってから"))
struct SileroVADTests {
  @Test("無音は声と判定しない")
  func silenceIsNotSpeech() throws {
    let vad = try SileroVAD(modelURL: modelURL)
    let probabilities = try chunks(of: [Float](repeating: 0, count: 16_000)).map {
      try vad.probability(of: $0)
    }
    #expect(probabilities.allSatisfy { $0 < 0.5 })
  }

  @Test("合成音声の発話は声と判定する")
  func synthesizedSpeechIsSpeech() throws {
    let vad = try SileroVAD(modelURL: modelURL)
    let probabilities = try chunks(of: synthesizedSpeech()).map { try vad.probability(of: $0) }
    let voicedRatio = Double(probabilities.filter { $0 >= 0.5 }.count) / Double(probabilities.count)
    #expect(voicedRatio > 0.5)
  }

  @Test("512 サンプル以外は受け付けない")
  func rejectsWrongChunkSize() throws {
    let vad = try SileroVAD(modelURL: modelURL)
    #expect(throws: VoiceDetectorError.self) { try vad.probability(of: [0, 0, 0]) }
  }
}
