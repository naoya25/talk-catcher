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
    /// 録音中に区切った音声。文字にするのは受け取った側
    case segment(AudioSegment)
    /// この録音の区切りはもう来ない
    case segmentsEnded(recordingID: String)
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
  /// chunk の番号を時刻に直す基準。音が来ない間(スリープ・マイクの開き直し)があると、
  /// 受け取った音の長さだけでは実際の時刻に追いつかないので、そのたびに基準を足す
  private var anchors: [(chunk: Int, date: Date)] = []
  private let clock: @Sendable () -> Date
  /// 音の時刻が実際の時刻よりこれ以上遅れていたら、音が途切れたとみなす
  static let gapTolerance: TimeInterval = 2
  private var writer: RecordingWriter?
  private var writerStartChunk = 0
  private var cutter: SegmentCutter?
  private var earliestStartChunk = 0
  private var lastPhase: Phase = .idle

  public init(
    settings: CaptureSettings,
    directory: URL,
    clock: @escaping @Sendable () -> Date = Date.init,
    makeDetector: @Sendable () throws -> any VoiceDetector
  ) throws {
    self.settings = settings
    self.directory = directory
    self.clock = clock
    machine = SessionMachine(config: .init(settings: settings))
    detector = try makeDetector()
    (events, continuation) = AsyncStream.makeStream(of: Event.self)
  }

  public func update(settings: CaptureSettings) {
    self.settings = settings
    machine.config = .init(settings: settings)
  }

  public func process(_ samples: [Float]) {
    anchorIfBehind(arriving: samples.count)
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
    endSegments()
    pending = []
    ring = []
    nextChunk = 0
    earliestStartChunk = 0
    anchors = []
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

    if writer != nil { append(chunk, voiced: voiced) }
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
      var cutter = SegmentCutter(
        recordingID: String(Self.fileName(for: time(ofChunk: writerStartChunk)).dropLast(4)),
        segmentSeconds: settings.segmentSeconds, overlapSeconds: settings.overlapSeconds)
      for entry in buffered {
        try writer.append(entry.samples)
        // 録音の頭(preroll)は、声を検知して録音を始めた直前の音なので声として数える
        _ = cutter.feed(entry.samples, voiced: true)
      }
      self.writer = writer
      self.cutter = cutter
    } catch {
      continuation.yield(.failed("録音を始められなかった: \(error.localizedDescription)"))
    }
  }

  private func append(_ chunk: [Float], voiced: Bool) {
    do {
      try writer?.append(chunk)
      for segment in cutter?.feed(chunk, voiced: voiced) ?? [] {
        continuation.yield(.segment(segment))
      }
    } catch {
      writer?.discard()
      writer = nil
      endSegments()
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
      if let last = cutter?.finish(endFrame: Int(frames)) {
        continuation.yield(.segment(last))
      }
      endSegments()
      return Recording(url: url, startedAt: startedAt, endedAt: endedAt, reason: reason)
    } catch {
      writer.discard()
      endSegments()
      continuation.yield(.failed("録音を書き出せなかった: \(error.localizedDescription)"))
      return nil
    }
  }

  private func endSegments() {
    guard let cutter else { return }
    self.cutter = nil
    continuation.yield(.segmentsEnded(recordingID: cutter.recordingID))
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

  /// 届いた音の終わりは「今」のはず。数えた時刻がそれより遅れていたら、次の chunk から今に合わせる
  private func anchorIfBehind(arriving count: Int) {
    let now = clock()
    let buffered = Double(pending.count + count) / AudioFormat.sampleRate
    let startOfNext = now.addingTimeInterval(-buffered)
    guard !anchors.isEmpty else {
      anchors = [(nextChunk, startOfNext)]
      return
    }
    if startOfNext.timeIntervalSince(time(ofChunk: nextChunk)) > Self.gapTolerance {
      anchors.append((nextChunk, startOfNext))
    }
  }

  func time(ofChunk index: Int) -> Date {
    guard let anchor = anchors.last(where: { $0.chunk <= index }) ?? anchors.first else {
      return clock()
    }
    return anchor.date.addingTimeInterval(Double(index - anchor.chunk) * AudioFormat.chunkSeconds)
  }

  static func fileName(for date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd'T'HH-mm-ss"
    return formatter.string(from: date) + ".m4a"
  }
}
