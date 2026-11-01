import Foundation
import os

/// 統合ログは権限が無いと読めないので、マイクの開け閉めのような後で追いたい出来事はファイルにも残す
struct AppLog: Sendable {
  private let url: URL
  private let logger = Logger(subsystem: "com.naoya25.talk-catcher", category: "app")

  init(url: URL) {
    self.url = url
  }

  func notice(_ message: String) {
    logger.notice("\(message, privacy: .public)")
    write(message)
  }

  func error(_ message: String) {
    logger.error("\(message, privacy: .public)")
    write("エラー: " + message)
  }

  private func write(_ message: String) {
    let formatter = ISO8601DateFormatter()
    formatter.timeZone = .current
    let line = "[\(formatter.string(from: Date()))] \(message)\n"
    try? FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    if !FileManager.default.fileExists(atPath: url.path) {
      FileManager.default.createFile(atPath: url.path, contents: nil)
    }
    guard let handle = try? FileHandle(forWritingTo: url) else { return }
    defer { try? handle.close() }
    _ = try? handle.seekToEnd()
    try? handle.write(contentsOf: Data(line.utf8))
  }
}
