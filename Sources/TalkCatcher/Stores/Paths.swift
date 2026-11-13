import Foundation

enum Paths {
  static let recordings = URL.applicationSupportDirectory.appending(path: "talk-catcher/recordings")
  /// 録音中に区切った音声の一時置き場。文字にしたら消える
  static let chunks = URL.applicationSupportDirectory.appending(path: "talk-catcher/recordings/.chunks")
  /// 区切りごとの文字。agent がここを読みに来る
  static let transcripts = URL.applicationSupportDirectory.appending(path: "talk-catcher/transcripts")
  static let defaultWhisperModel = URL.applicationSupportDirectory.appending(
    path: "talk-catcher/models/ggml-large-v3-turbo-q5_0.bin")
  static let hookLog = URL.libraryDirectory.appending(path: "Logs/talk-catcher/hooks.log")
  static let appLog = URL.libraryDirectory.appending(path: "Logs/talk-catcher/app.log")

  static var model: URL? {
    Bundle.main.url(forResource: "silero_vad", withExtension: "onnx")
  }
}
