public struct SessionMachine: Sendable {
  public struct Config: Sendable, Equatable {
    public var startChunks: Int
    // 話し声は息継ぎで途切れるので、この長さまでの切れ目は同じ発話として数える
    public var startGapChunks = AudioFormat.chunks(forSeconds: 0.3)
    public var prerollChunks: Int
    public var endSilenceChunks: Int
    public var tailChunks: Int
    public var maxLengthChunks: Int

    public init(settings: CaptureSettings) {
      startChunks = AudioFormat.chunks(forSeconds: settings.startSpeechSeconds)
      prerollChunks = AudioFormat.chunks(forSeconds: settings.prerollSeconds)
      endSilenceChunks = AudioFormat.chunks(forSeconds: settings.endSilenceSeconds)
      tailChunks = AudioFormat.chunks(forSeconds: settings.tailSeconds)
      maxLengthChunks = AudioFormat.chunks(forSeconds: settings.maxLengthSeconds)
    }
  }

  public enum Phase: Sendable, Equatable {
    case idle
    case recording(startChunk: Int, lastVoicedChunk: Int)
  }

  public enum Action: Sendable, Equatable {
    case start(fromChunk: Int)
    /// `endChunk` は含まない
    case finish(endChunk: Int, reason: FinishReason)
  }

  public var config: Config
  public private(set) var phase: Phase = .idle
  private var voicedChunks = 0
  private var firstVoicedChunk = 0
  private var gapChunks = 0

  public init(config: Config) {
    self.config = config
  }

  public mutating func feed(chunk: Int, voiced: Bool) -> [Action] {
    switch phase {
    case .idle:
      countSpeech(chunk: chunk, voiced: voiced)
      guard voicedChunks >= config.startChunks else { return [] }
      let start = max(0, firstVoicedChunk - config.prerollChunks)
      phase = .recording(startChunk: start, lastVoicedChunk: chunk)
      return [.start(fromChunk: start)]

    case .recording(let start, var lastVoiced):
      if voiced { lastVoiced = chunk }
      if chunk - lastVoiced >= config.endSilenceChunks {
        reset()
        return [.finish(endChunk: lastVoiced + 1 + config.tailChunks, reason: .silence)]
      }
      if chunk + 1 - start >= config.maxLengthChunks {
        phase = .recording(startChunk: chunk + 1, lastVoicedChunk: lastVoiced)
        return [.finish(endChunk: chunk + 1, reason: .maxLength), .start(fromChunk: chunk + 1)]
      }
      phase = .recording(startChunk: start, lastVoicedChunk: lastVoiced)
      return []
    }
  }

  public mutating func stop(at chunk: Int, reason: FinishReason) -> Action? {
    guard case .recording(_, let lastVoiced) = phase else { return nil }
    reset()
    return .finish(endChunk: min(chunk + 1, lastVoiced + 1 + config.tailChunks), reason: reason)
  }

  public mutating func reset() {
    phase = .idle
    voicedChunks = 0
    gapChunks = 0
  }

  private mutating func countSpeech(chunk: Int, voiced: Bool) {
    if voiced {
      if voicedChunks == 0 { firstVoicedChunk = chunk }
      voicedChunks += 1
      gapChunks = 0
    } else if voicedChunks > 0 {
      gapChunks += 1
      if gapChunks > config.startGapChunks {
        voicedChunks = 0
        gapChunks = 0
      }
    }
  }
}
