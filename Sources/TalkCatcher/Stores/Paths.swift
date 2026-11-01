import Foundation

enum Paths {
  static let recordings = URL.applicationSupportDirectory.appending(path: "talk-catcher/recordings")
  static let hookLog = URL.libraryDirectory.appending(path: "Logs/talk-catcher/hooks.log")
  static let appLog = URL.libraryDirectory.appending(path: "Logs/talk-catcher/app.log")

  static var model: URL? {
    Bundle.main.url(forResource: "silero_vad", withExtension: "onnx")
  }
}
