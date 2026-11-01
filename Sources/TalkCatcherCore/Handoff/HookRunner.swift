import Foundation

public struct HookResult: Sendable, Equatable {
  public let exitCode: Int32
  public let timedOut: Bool
  public let output: String

  public var succeeded: Bool { exitCode == 0 && !timedOut }
}

public struct HookRunner: Sendable {
  public var shell: URL
  public var timeout: Duration
  public var maxOutputBytes = 64 * 1024

  public init(shell: URL = URL(filePath: "/bin/zsh"), timeout: Duration = .seconds(600)) {
    self.shell = shell
    self.timeout = timeout
  }

  public static func environment(for recording: Recording) -> [String: String] {
    let formatter = ISO8601DateFormatter()
    formatter.timeZone = .current
    return [
      "TC_FILE": recording.url.path,
      "TC_STARTED_AT": formatter.string(from: recording.startedAt),
      "TC_ENDED_AT": formatter.string(from: recording.endedAt),
      "TC_DURATION_SEC": String(Int(recording.duration.rounded())),
      "TC_REASON": recording.reason.rawValue,
    ]
  }

  public func run(command: String, recording: Recording) async throws -> HookResult {
    let outputURL = FileManager.default.temporaryDirectory.appending(
      path: "talk-catcher-\(UUID().uuidString).log")
    FileManager.default.createFile(atPath: outputURL.path, contents: nil)
    defer { try? FileManager.default.removeItem(at: outputURL) }
    let outputHandle = try FileHandle(forWritingTo: outputURL)
    defer { try? outputHandle.close() }

    let process = Process()
    process.executableURL = shell
    // ログインシェルにして、ユーザーの PATH にある curl や whisper-cli を使えるようにする
    process.arguments = ["-lc", command, "talk-catcher", recording.url.path]
    process.environment = ProcessInfo.processInfo.environment.merging(
      Self.environment(for: recording)
    ) { $1 }
    // パイプだと出力が 64KB を超えたところで子が書き込みで止まるので、ファイルで受ける
    process.standardOutput = outputHandle
    process.standardError = outputHandle
    process.standardInput = FileHandle.nullDevice

    let (exits, exitContinuation) = AsyncStream.makeStream(of: Int32.self)
    process.terminationHandler = { finished in
      exitContinuation.yield(finished.terminationStatus)
      exitContinuation.finish()
    }
    try process.run()

    let pid = process.processIdentifier
    let timeout = self.timeout
    let killer = Task {
      do {
        try await Task.sleep(for: timeout)
      } catch {
        return false
      }
      kill(pid, SIGTERM)
      return true
    }
    var exitCode: Int32 = -1
    for await code in exits { exitCode = code }
    killer.cancel()
    let timedOut = await killer.value

    return HookResult(
      exitCode: exitCode, timedOut: timedOut,
      output: Self.tail(of: outputURL, bytes: maxOutputBytes))
  }

  private static func tail(of url: URL, bytes: Int) -> String {
    guard let data = try? Data(contentsOf: url) else { return "" }
    return String(decoding: data.suffix(bytes), as: UTF8.self)
  }
}
