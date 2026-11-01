import Foundation

public enum FinishReason: String, Codable, Sendable {
  case silence
  case maxLength = "max_length"
  case stopped
  case manual
  case quit
}

public struct Recording: Codable, Sendable, Hashable {
  public let url: URL
  public let startedAt: Date
  public let endedAt: Date
  public let reason: FinishReason

  public init(url: URL, startedAt: Date, endedAt: Date, reason: FinishReason) {
    self.url = url
    self.startedAt = startedAt
    self.endedAt = endedAt
    self.reason = reason
  }

  public var duration: TimeInterval { endedAt.timeIntervalSince(startedAt) }
}
