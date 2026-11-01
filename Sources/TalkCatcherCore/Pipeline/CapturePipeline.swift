import AVFoundation

public actor CapturePipeline {
  public enum Phase: Sendable, Equatable {
    case idle
    case recording(startedAt: Date, lastVoiceAt: Date)
  }

  public struct Status: Sendable, Equatable {
    public var phase: Phase
    public var level: Float
    public var voiced: Bool
  }

  public enum Event: Sendable {
    case status(Status)
    case recorded(Recording)
    case failed(String)
  }

  public nonisolated let events: AsyncStream<Event>
  private let continuation: AsyncStream<Event>.Continuation
  private let directory: URL
  private let detector: any VoiceDetector
  private let ringCapacity = AudioFormat.chunks(forSeconds: AudioFormat.bufferSeconds)
  private let statusInterval = 3

  private var settings: CaptureSettings
  private var machine: SessionMachine
  private var pending: [Float] = []
  private var ring: [(index: Int, samples: [Float])] = []
  private var nextChunk = 0
  private var origin: Date?
  private var writer: RecordingWriter?
  private var writerStartChunk = 0
  private var earliestStartChunk = 0
  private var lastPhase: Phase = .idle

  public init(
    settings: CaptureSettings,
    directory: URL,
    makeDetector: @Sendable () throws -> any VoiceDetector
  ) throws {
    self.settings = settings
    self.directory = directory
    machine = SessionMachine(config: .init(settings: settings))
    detector = try makeDetector()
    (events, continuation) = AsyncStream.makeStream(of: Event.self)
  }

  public func update(settings: CaptureSettings) {
    self.settings = settings
    machine.config = .init(settings: settings)
  }

  public func process(_ samples: [Float]) {
    if origin == nil { origin = Date() }
    pending += samples
    while pending.count >= AudioFormat.chunkSize {
      let chunk = Array(pending.prefix(AudioFormat.chunkSize))
      pending.removeFirst(AudioFormat.chunkSize)
      handle(chunk)
    }
  }

  /// 録音中なら今の分を区切って書き出す。聞くのはそのまま続ける
  public func cut(reason: FinishReason) -> Recording? {
    guard case .finish(let endChunk, let reason)? = machine.stop(at: nextChunk - 1, reason: reason)
    else { return nil }
    // 区切った直後にまた声が出ても、さかのぼって同じ音を次の1本に入れない
    earliestStartChunk = endChunk
    let recording = finish(endChunk: endChunk, reason: reason)
    publishStatus(level: AudioLevel.floor, voiced: false, force: true)
    return recording
  }

  /// 録音中なら今の分を区切って書き出し、聞き始める前の状態に戻す
  public func stop(reason: FinishReason) -> Recording? {
    let recording = cut(reason: reason)
    writer?.discard()
    writer = nil
    pending = []
    ring = []
    nextChunk = 0
    earliestStartChunk = 0
    origin = nil
    detector.reset()
    publishStatus(level: AudioLevel.floor, voiced: false, force: true)
    return recording
  }

  private func handle(_ chunk: [Float]) {
    let index = nextChunk
    nextChunk += 1
    ring.append((index, chunk))
    if ring.count > ringCapacity { ring.removeFirst(ring.count - ringCapacity) }

    let level = AudioLevel.dbfs(chunk)
    let probability = (try? detector.probability(of: chunk)) ?? 0
    let voiced = probability >= settings.speechProbability && level >= settings.minDBFS

    if writer != nil { append(chunk) }
    for action in machine.feed(chunk: index, voiced: voiced) {
      apply(action)
    }
    publishStatus(level: level, voiced: voiced, force: index % statusInterval == 0)
  }

  private func apply(_ action: SessionMachine.Action) {
    switch action {
    case .start(let fromChunk):
      begin(fromChunk: max(fromChunk, earliestStartChunk))
    case .finish(let endChunk, let reason):
      if let recording = finish(endChunk: endChunk, reason: reason) {
        continuation.yield(.recorded(recording))
      }
    }
  }

  private func begin(fromChunk: Int) {
    let partial = directory.appending(path: ".partial/\(UUID().uuidString).caf")
    do {
      let writer = try RecordingWriter(partialURL: partial)
      let buffered = ring.filter { $0.index >= fromChunk }
      writerStartChunk = buffered.first?.index ?? nextChunk
      for entry in buffered { try writer.append(entry.samples) }
      self.writer = writer
    } catch {
      continuation.yield(.failed("録音を始められなかった: \(error.localizedDescription)"))
    }
  }

  private func append(_ chunk: [Float]) {
    do {
      try writer?.append(chunk)
    } catch {
      writer?.discard()
      writer = nil
      continuation.yield(.failed("録音の書き込みに失敗した: \(error.localizedDescription)"))
    }
  }

  private func finish(endChunk: Int, reason: FinishReason) -> Recording? {
    guard let writer else { return nil }
    self.writer = nil
    let startedAt = time(ofChunk: writerStartChunk)
    let endedAt = time(ofChunk: endChunk)
    let url = directory.appending(path: Self.fileName(for: startedAt))
    do {
      let frames =
        AVAudioFramePosition(endChunk - writerStartChunk)
        * AVAudioFramePosition(AudioFormat.chunkSize)
      try writer.finish(keepingFrames: frames, to: url)
      return Recording(url: url, startedAt: startedAt, endedAt: endedAt, reason: reason)
    } catch {
      writer.discard()
      continuation.yield(.failed("録音を書き出せなかった: \(error.localizedDescription)"))
      return nil
    }
  }

  private func publishStatus(level: Float, voiced: Bool, force: Bool) {
    let phase: Phase
    if case .recording(let start, let lastVoiced) = machine.phase, writer != nil {
      phase = .recording(startedAt: time(ofChunk: start), lastVoiceAt: time(ofChunk: lastVoiced))
    } else {
      phase = .idle
    }
    guard force || phase != lastPhase else { return }
    lastPhase = phase
    continuation.yield(.status(Status(phase: phase, level: level, voiced: voiced)))
  }

  private func time(ofChunk index: Int) -> Date {
    (origin ?? Date()).addingTimeInterval(Double(index) * AudioFormat.chunkSeconds)
  }

  static func fileName(for date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd'T'HH-mm-ss"
    return formatter.string(from: date) + ".m4a"
  }
}
