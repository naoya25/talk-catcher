import Foundation

public struct CaptureSettings: Codable, Sendable, Equatable {
  public var speechProbability: Float = 0.5
  public var minDBFS: Float = -35
  public var startSpeechSeconds: Double = 1
  public var prerollSeconds: Double = 3
  public var endSilenceSeconds: Double = 300
  public var tailSeconds: Double = 5
  public var maxLengthSeconds: Double = 3600

  public init() {}

  // 項目を足しても、前の版で保存した設定(コマンドなど)が読めなくならないようにする
  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let fallback = CaptureSettings()
    speechProbability =
      try container.decodeIfPresent(Float.self, forKey: .speechProbability)
      ?? fallback.speechProbability
    minDBFS = try container.decodeIfPresent(Float.self, forKey: .minDBFS) ?? fallback.minDBFS
    startSpeechSeconds =
      try container.decodeIfPresent(Double.self, forKey: .startSpeechSeconds)
      ?? fallback.startSpeechSeconds
    prerollSeconds =
      try container.decodeIfPresent(Double.self, forKey: .prerollSeconds) ?? fallback.prerollSeconds
    endSilenceSeconds =
      try container.decodeIfPresent(Double.self, forKey: .endSilenceSeconds)
      ?? fallback.endSilenceSeconds
    tailSeconds =
      try container.decodeIfPresent(Double.self, forKey: .tailSeconds) ?? fallback.tailSeconds
    maxLengthSeconds =
      try container.decodeIfPresent(Double.self, forKey: .maxLengthSeconds)
      ?? fallback.maxLengthSeconds
  }
}

public enum AudioFormat {
  public static let sampleRate: Double = 16_000
  public static let chunkSize = 512
  public static let chunkSeconds = Double(chunkSize) / sampleRate
  public static let bufferSeconds: Double = 30

  public static func chunks(forSeconds seconds: Double) -> Int {
    Int((seconds / chunkSeconds).rounded())
  }
}
