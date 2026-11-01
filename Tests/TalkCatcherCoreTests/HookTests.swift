import Foundation
import Testing

@testable import TalkCatcherCore

private let recording = Recording(
  url: URL(filePath: "/tmp/talk catcher/2026-10-29T17-21-05.m4a"),
  startedAt: Date(timeIntervalSince1970: 1_793_262_065),
  endedAt: Date(timeIntervalSince1970: 1_793_262_377),
  reason: .silence
)

@Test("コマンドには第1引数と TC_* の環境変数で録音の情報が渡る")
func passesFileAndEnvironment() async throws {
  let result = try await HookRunner().run(
    command: #"printf '%s|%s|%s|%s' "$1" "$TC_FILE" "$TC_DURATION_SEC" "$TC_REASON""#,
    recording: recording
  )
  #expect(result.succeeded)
  #expect(result.output == "\(recording.url.path)|\(recording.url.path)|312|silence")
}

@Test("0 以外の終了コードは失敗として返す")
func nonZeroExitFails() async throws {
  let result = try await HookRunner().run(command: "echo nope >&2; exit 22", recording: recording)
  #expect(result.exitCode == 22)
  #expect(!result.succeeded)
  #expect(result.output == "nope\n")
}

@Test("時間を超えたコマンドは止めて、時間切れとして返す")
func timesOut() async throws {
  let result = try await HookRunner(timeout: .milliseconds(300)).run(
    command: "exec sleep 5", recording: recording)
  #expect(result.timedOut)
  #expect(!result.succeeded)
}

private func waitFor(_ queue: HandoffQueue, _ done: (HandoffQueue.Item) -> Bool) async
  -> [HandoffQueue.Item]
{
  var seen: [HandoffQueue.Item] = []
  for await item in queue.updates {
    seen.append(item)
    if done(item) { break }
  }
  return seen
}

@Test("コマンドが空なら保存だけで終わる")
func emptyCommandOnlySaves() async {
  let queue = HandoffQueue()
  await queue.enqueue(recording)
  let seen = await waitFor(queue) { _ in true }
  #expect(seen.map(\.status) == [.saved])
}

@Test("失敗したら間をあけて再実行し、全部失敗したら failed になる")
func retriesThenFails() async {
  let queue = HandoffQueue(retryDelays: [.milliseconds(10), .milliseconds(10)])
  await queue.set(command: "exit 1")
  await queue.enqueue(recording)
  let seen = await waitFor(queue) { $0.status == .failed }
  #expect(seen.last?.attempts == 3)
  #expect(seen.filter { $0.status == .running }.count == 3)
}

@Test("成功したら succeeded になり、再実行しない")
func succeedsOnce() async {
  let queue = HandoffQueue(retryDelays: [.milliseconds(10)])
  await queue.set(command: "true")
  await queue.enqueue(recording)
  let seen = await waitFor(queue) { $0.status == .succeeded }
  #expect(seen.last?.attempts == 1)
}
