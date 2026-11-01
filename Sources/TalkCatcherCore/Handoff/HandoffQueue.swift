import Foundation

public actor HandoffQueue {
  public enum Status: Sendable, Equatable {
    case saved
    case queued
    case running
    case succeeded
    case waitingRetry(until: Date)
    case failed
  }

  public struct Item: Sendable, Identifiable, Equatable {
    public let id: UUID
    public let recording: Recording
    public var status: Status
    public var attempts: Int
    public var lastResult: HookResult?
  }

  public nonisolated let updates: AsyncStream<Item>
  private let continuation: AsyncStream<Item>.Continuation
  private let runner: HookRunner
  private let retryDelays: [Duration]
  private let log: HookLog?

  private var command = ""
  private var items: [UUID: Item] = [:]
  private var pending: [UUID] = []
  private var isRunning = false

  public init(
    runner: HookRunner = HookRunner(), retryDelays: [Duration] = [.seconds(60), .seconds(300)],
    log: HookLog? = nil
  ) {
    self.runner = runner
    self.retryDelays = retryDelays
    self.log = log
    (updates, continuation) = AsyncStream.makeStream(of: Item.self)
  }

  public func set(command: String) {
    self.command = command
  }

  public func enqueue(_ recording: Recording) {
    let empty = command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    let item = Item(
      id: UUID(), recording: recording, status: empty ? .saved : .queued, attempts: 0,
      lastResult: nil)
    items[item.id] = item
    continuation.yield(item)
    guard !empty else { return }
    pending.append(item.id)
    pump()
  }

  /// 失敗した録音を、試した回数を数え直してもう一度渡す
  public func retry(id: UUID) {
    guard var item = items[id], item.status == .failed || item.status == .saved else { return }
    item.attempts = 0
    item.status = .queued
    items[id] = item
    continuation.yield(item)
    pending.append(id)
    pump()
  }

  private func pump() {
    guard !isRunning, !pending.isEmpty else { return }
    let id = pending.removeFirst()
    isRunning = true
    Task { await execute(id) }
  }

  private func execute(_ id: UUID) async {
    guard var item = items[id] else {
      finishRun()
      return
    }
    item.status = .running
    item.attempts += 1
    update(item)

    let result: HookResult
    do {
      result = try await runner.run(command: command, recording: item.recording)
    } catch {
      result = HookResult(
        exitCode: -1, timedOut: false, output: "コマンドを起動できなかった: \(error.localizedDescription)")
    }
    log?.append(item: item, result: result)
    item.lastResult = result

    if result.succeeded {
      item.status = .succeeded
    } else if item.attempts <= retryDelays.count {
      let delay = retryDelays[item.attempts - 1]
      item.status = .waitingRetry(until: Date().addingTimeInterval(delay.seconds))
      Task {
        try? await Task.sleep(for: delay)
        requeue(id)
      }
    } else {
      item.status = .failed
    }
    update(item)
    finishRun()
  }

  private func requeue(_ id: UUID) {
    guard let item = items[id], case .waitingRetry = item.status else { return }
    pending.append(id)
    pump()
  }

  private func update(_ item: Item) {
    items[item.id] = item
    continuation.yield(item)
  }

  private func finishRun() {
    isRunning = false
    pump()
  }
}

extension Duration {
  var seconds: TimeInterval {
    let (seconds, attoseconds) = components
    return TimeInterval(seconds) + TimeInterval(attoseconds) / 1e18
  }
}
