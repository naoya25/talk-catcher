import Foundation

public struct HookLog: Sendable {
  public let url: URL

  public init(url: URL) {
    self.url = url
  }

  func append(item: HandoffQueue.Item, result: HookResult) {
    let formatter = ISO8601DateFormatter()
    formatter.timeZone = .current
    var lines = [
      "[\(formatter.string(from: Date()))] \(item.recording.url.lastPathComponent) \(item.attempts)回目"
    ]
    if !result.output.isEmpty { lines.append(result.output.trimmingCharacters(in: .newlines)) }
    lines.append(result.timedOut ? "時間切れで止めた" : "exit \(result.exitCode)")
    let text = lines.joined(separator: "\n") + "\n\n"

    try? FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    if !FileManager.default.fileExists(atPath: url.path) {
      FileManager.default.createFile(atPath: url.path, contents: nil)
    }
    guard let handle = try? FileHandle(forWritingTo: url) else { return }
    defer { try? handle.close() }
    _ = try? handle.seekToEnd()
    try? handle.write(contentsOf: Data(text.utf8))
  }
}
