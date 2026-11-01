import AppKit
import Foundation
import Observation
import TalkCatcherCore
import UserNotifications

struct CaptureState: Equatable {
  enum Phase: Equatable {
    case starting
    case noPermission
    case listening
    case recording(since: Date)
    case waitingEnd(since: Date, lastVoiceAt: Date)
    case paused(until: Date?)
    case failed(String)
  }

  var phase: Phase = .starting
  var recent: [HandoffQueue.Item] = []
  var lastError: String?

  var hasFailedHandoff: Bool { recent.contains { $0.status == .failed } }
}

@MainActor
@Observable
final class CaptureStore {
  // 声が途切れてすぐ「終わり待ち」に変えると、話の息継ぎのたびに表示がちらつく
  private static let waitingEndDelay: TimeInterval = 1.5
  private static let recentLimit = 20
  private static let silentInputLimit: TimeInterval = 5
  private static let restartInterval: TimeInterval = 2

  private(set) var state = CaptureState()
  private(set) var now = Date()
  // 音量は1秒に何回も変わる。state に入れると、それを読むメニューが開いたまま作り直され、クリックがずれる
  private(set) var level: Float = AudioLevel.floor
  private(set) var voiced = false
  private(set) var inputDeviceName: String?
  private(set) var usingFallbackInput = false

  @ObservationIgnored private let settings: SettingsStore
  @ObservationIgnored private let microphone = MicrophoneInput()
  @ObservationIgnored private let queue = HandoffQueue(log: HookLog(url: Paths.hookLog))
  @ObservationIgnored private let log = AppLog(url: Paths.appLog)
  @ObservationIgnored private var pipeline: CapturePipeline?
  @ObservationIgnored private var pipelinePhase: CapturePipeline.Phase = .idle
  @ObservationIgnored private var listenTask: Task<Void, Never>?
  @ObservationIgnored private var resumeTask: Task<Void, Never>?
  @ObservationIgnored private var backgroundTasks: [Task<Void, Never>] = []
  @ObservationIgnored private var wakeObserver: NSObjectProtocol?
  @ObservationIgnored private var lastAudioAt = Date()
  @ObservationIgnored private var lastRestartAt = Date.distantPast
  @ObservationIgnored private var activeDeviceUID: String?

  init(settings: SettingsStore) {
    self.settings = settings
  }

  func start() async {
    backgroundTasks.append(Task { [weak self] in await self?.tickClock() })
    backgroundTasks.append(Task { [weak self] in await self?.watchQueue() })
    // 通知の許可の返事を待つと、その間マイクを聞き始められない
    Task {
      _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [
        .alert, .sound,
      ])
    }
    await queue.set(command: settings.settings.command)

    guard await MicrophoneInput.requestAccess() else {
      log.notice("マイクを許可されていない")
      state.phase = .noPermission
      return
    }
    guard let model = Paths.model else {
      state.phase = .failed("Silero VAD のモデルが .app の中に無い")
      return
    }
    do {
      let pipeline = try CapturePipeline(
        settings: settings.settings.capture,
        directory: Paths.recordings,
        makeDetector: { try SileroVAD(modelURL: model) }
      )
      self.pipeline = pipeline
      backgroundTasks.append(Task { [weak self] in await self?.watch(pipeline) })
    } catch {
      state.phase = .failed("声の判定を準備できなかった: \(error.localizedDescription)")
      return
    }
    wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.restartMicrophone(reason: "スリープから戻った") }
    }
    listen()
  }

  func apply(_ next: AppSettings) {
    Task {
      await pipeline?.update(settings: next.capture)
      await queue.set(command: next.command)
    }
    if next.inputDeviceUID != activeDeviceUID {
      restartMicrophone(reason: "設定でマイクを変えた")
    }
  }

  func pause(minutes: Int?) async {
    resumeTask?.cancel()
    await stopListening(reason: .stopped)
    let until = minutes.map { now.addingTimeInterval(TimeInterval($0 * 60)) }
    state.phase = .paused(until: until)
    guard let minutes else { return }
    resumeTask = Task { [weak self] in
      try? await Task.sleep(for: .seconds(minutes * 60))
      guard !Task.isCancelled else { return }
      self?.resume()
    }
  }

  func resume() {
    resumeTask?.cancel()
    resumeTask = nil
    listen()
  }

  func cutNow() async {
    guard let recording = await pipeline?.cut(reason: .manual) else { return }
    await queue.enqueue(recording)
  }

  func retry(_ item: HandoffQueue.Item) {
    Task { await queue.retry(id: item.id) }
  }

  func quit() async {
    await stopListening(reason: .quit)
    // 渡したコマンドが起動するまで少し待つ。起動した子プロセスはアプリが終わっても動き続ける
    try? await Task.sleep(for: .seconds(1))
    NSApp.terminate(nil)
  }

  func testCommand(_ command: String) async -> String {
    guard let recording = state.recent.first?.recording else {
      return "まだ録音がない。1本録れてから試せる"
    }
    do {
      let result = try await HookRunner().run(command: command, recording: recording)
      let summary = result.timedOut ? "時間切れで止めた" : "exit \(result.exitCode)"
      return [result.output.trimmingCharacters(in: .newlines), summary].filter { !$0.isEmpty }
        .joined(separator: "\n")
    } catch {
      return "コマンドを起動できなかった: \(error.localizedDescription)"
    }
  }

  private func listen() {
    guard let pipeline else { return }
    let wanted = settings.settings.inputDeviceUID
    let device = wanted.flatMap { uid in InputDevices.all().first { $0.uid == uid } }
    do {
      let samples = try microphone.start(device: device) { [weak self] in
        self?.restartMicrophone(reason: "入力の構成が変わった")
      }
      listenTask = Task {
        for await chunk in samples { await pipeline.process(chunk) }
      }
      activeDeviceUID = wanted
      usingFallbackInput = wanted != nil && device == nil
      inputDeviceName = (device ?? InputDevices.systemDefault())?.name
      lastAudioAt = Date()
      if !isListeningPhase { state.phase = .listening }
      log.notice(
        "聞き始めた: \(inputDeviceName ?? "不明なマイク")\(usingFallbackInput ? "(選んだマイクがつながっていないのでデフォルト)" : "")"
      )
    } catch {
      log.error("マイクを開けなかった: \(error.localizedDescription)")
      state.phase = .failed("マイクを開けなかった: \(error.localizedDescription)")
    }
  }

  private var isListeningPhase: Bool {
    switch state.phase {
    case .listening, .recording, .waitingEnd: true
    default: false
    }
  }

  private func restartMicrophone(reason: String) {
    guard isListeningPhase, Date().timeIntervalSince(lastRestartAt) > Self.restartInterval else {
      return
    }
    lastRestartAt = Date()
    log.notice("マイクを開き直す: \(reason)")
    microphone.stop()
    listenTask?.cancel()
    listenTask = nil
    listen()
  }

  private func stopListening(reason: FinishReason) async {
    microphone.stop()
    listenTask?.cancel()
    listenTask = nil
    guard let pipeline else { return }
    if let recording = await pipeline.stop(reason: reason) {
      await queue.enqueue(recording)
    }
  }

  private func watch(_ pipeline: CapturePipeline) async {
    for await event in pipeline.events {
      switch event {
      case .status(let status):
        level = status.level
        lastAudioAt = Date()
        voiced = status.voiced
        pipelinePhase = status.phase
        refreshPhase()
      case .recorded(let recording):
        log.notice("録音を書き出した: \(recording.url.lastPathComponent)")
        await queue.enqueue(recording)
      case .failed(let message):
        log.error(message)
        state.lastError = message
      }
    }
  }

  private func watchQueue() async {
    for await item in queue.updates {
      if let index = state.recent.firstIndex(where: { $0.id == item.id }) {
        state.recent[index] = item
      } else {
        state.recent.insert(item, at: 0)
        state.recent = Array(state.recent.prefix(Self.recentLimit))
      }
      if item.status == .failed { notifyFailure(item) }
    }
  }

  private func tickClock() async {
    while !Task.isCancelled {
      try? await Task.sleep(for: .seconds(1))
      now = Date()
      refreshPhase()
      if isListeningPhase, now.timeIntervalSince(lastAudioAt) > Self.silentInputLimit {
        restartMicrophone(reason: "\(Int(Self.silentInputLimit))秒間マイクから音が来ない")
      }
    }
  }

  private func refreshPhase() {
    switch state.phase {
    case .listening, .recording, .waitingEnd: break
    default: return
    }
    let next: CaptureState.Phase
    switch pipelinePhase {
    case .idle:
      next = .listening
    case .recording(let since, let lastVoiceAt):
      next =
        now.timeIntervalSince(lastVoiceAt) > Self.waitingEndDelay
        ? .waitingEnd(since: since, lastVoiceAt: lastVoiceAt) : .recording(since: since)
    }
    if next != state.phase { state.phase = next }
  }

  private func notifyFailure(_ item: HandoffQueue.Item) {
    let content = UNMutableNotificationContent()
    content.title = "コマンドに渡せなかった"
    content.body =
      "\(TimeText.clock(item.recording.startedAt)) からの録音(\(TimeText.duration(item.recording.duration)))。\(item.attempts)回とも失敗した。ファイルは残してある"
    let request = UNNotificationRequest(
      identifier: item.id.uuidString, content: content, trigger: nil)
    UNUserNotificationCenter.current().add(request)
  }
}
