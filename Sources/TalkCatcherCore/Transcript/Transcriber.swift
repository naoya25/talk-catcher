import AVFoundation
import Foundation

/// 区切った音声を whisper.cpp で文字にし、録音ごとのフォルダに 0001.txt の形で置く
///
/// 区切った音声は `chunks/<録音ID>/` に一時的に書き、文字にしたら消す。
/// 録音が切れたら、その録音の一時フォルダごと消す。文字のフォルダは残す
public actor Transcriber {
  public struct Config: Sendable, Equatable {
    public var whisperPath: String
    public var modelPath: String
    public var language: String

    public init(whisperPath: String, modelPath: String, language: String) {
      self.whisperPath = whisperPath
      self.modelPath = modelPath
      self.language = language
    }
  }

  public enum Outcome: Sendable {
    case written(URL)
    case failed(String)
  }

  private let chunksDirectory: URL
  private let transcriptsDirectory: URL
  private var config: Config
  private let report: @Sendable (Outcome) -> Void
  /// 区切りは届いた順に1つずつ文字にする。whisper を並べて走らせると、1つずつより遅くなる
  private var tail: Task<Void, Never>?

  public init(
    chunksDirectory: URL, transcriptsDirectory: URL, config: Config,
    report: @escaping @Sendable (Outcome) -> Void
  ) {
    self.chunksDirectory = chunksDirectory
    self.transcriptsDirectory = transcriptsDirectory
    self.config = config
    self.report = report
  }

  public func update(config: Config) { self.config = config }

  public func submit(_ segment: AudioSegment) {
    enqueue { await self.transcribe(segment) }
  }

  /// 録音が切れたあと、その録音の区切りを全部文字にしてから一時フォルダを消す
  public func end(recordingID: String) {
    let directory = chunksDirectory.appending(path: recordingID)
    enqueue { try? FileManager.default.removeItem(at: directory) }
  }

  /// 積んだ仕事が全部終わるまで待つ(テスト用)
  public func drain() async { await tail?.value }

  private func enqueue(_ work: @escaping @Sendable () async -> Void) {
    let previous = tail
    tail = Task {
      await previous?.value
      await work()
    }
  }

  private func transcribe(_ segment: AudioSegment) async {
    let name = String(format: "%04d", segment.number)
    let audio = chunksDirectory.appending(path: "\(segment.recordingID)/\(name).wav")
    let folder = transcriptsDirectory.appending(path: segment.recordingID)
    // whisper は -of に .txt を付けて書く。書きかけを agent に読ませないよう、隠しファイルに書いてから名前を変える
    let partialBase = folder.appending(path: ".\(name)")
    let destination = folder.appending(path: "\(name).txt")
    defer { try? FileManager.default.removeItem(at: audio) }
    do {
      try Self.writeWAV(segment.samples, to: audio)
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      let config = self.config
      try await Self.run(
        config.whisperPath,
        arguments: [
          "-m", config.modelPath, "-l", config.language, "-nt", "-np", "-otxt",
          "-of", partialBase.path, "-f", audio.path,
        ])
      let partial = URL(filePath: partialBase.path + ".txt")
      let text = try String(contentsOf: partial, encoding: .utf8)
      try? FileManager.default.removeItem(at: partial)
      let header = "[\(Self.clock(segment.startSeconds))-\(Self.clock(segment.endSeconds))]\n"
      try (header + text).write(to: destination, atomically: true, encoding: .utf8)
      report(.written(destination))
    } catch {
      report(.failed("\(segment.recordingID)/\(name) を文字にできなかった: \(error.localizedDescription)"))
    }
  }

  static func writeWAV(_ samples: [Float], to url: URL) throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let settings: [String: Any] = [
      AVFormatIDKey: kAudioFormatLinearPCM,
      AVSampleRateKey: AudioFormat.sampleRate,
      AVNumberOfChannelsKey: 1,
      AVLinearPCMBitDepthKey: 16,
      AVLinearPCMIsFloatKey: false,
    ]
    let file = try AVAudioFile(
      forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
    guard
      let buffer = AVAudioPCMBuffer(
        pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(samples.count)),
      let channel = buffer.floatChannelData
    else { throw RecordingWriterError.unsupportedFormat }
    for (offset, sample) in samples.enumerated() { channel[0][offset] = sample }
    buffer.frameLength = AVAudioFrameCount(samples.count)
    try file.write(from: buffer)
  }

  struct CommandFailed: LocalizedError {
    let status: Int32
    let output: String
    var errorDescription: String? { "終了コード \(status): \(output)" }
  }

  static func run(_ executable: String, arguments: [String]) async throws {
    let process = Process()
    process.executableURL = URL(filePath: executable)
    process.arguments = arguments
    // whisper は読み込みのログを標準エラーにたくさん出す。Pipe だと詰まって止まるのでファイルに逃がす
    let log = FileManager.default.temporaryDirectory.appending(path: "talk-catcher-\(UUID().uuidString).log")
    FileManager.default.createFile(atPath: log.path, contents: nil)
    let errors = try FileHandle(forWritingTo: log)
    defer {
      try? errors.close()
      try? FileManager.default.removeItem(at: log)
    }
    process.standardOutput = FileHandle.nullDevice
    process.standardError = errors
    let status: Int32 = try await withCheckedThrowingContinuation { continuation in
      process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
      do { try process.run() } catch { continuation.resume(throwing: error) }
    }
    guard status == 0 else {
      let data = (try? Data(contentsOf: log)) ?? Data()
      let text = String(decoding: data.suffix(400), as: UTF8.self)
      throw CommandFailed(status: status, output: text)
    }
  }

  static func clock(_ seconds: Double) -> String {
    let total = Int(seconds.rounded())
    return String(format: "%02d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
  }
}
