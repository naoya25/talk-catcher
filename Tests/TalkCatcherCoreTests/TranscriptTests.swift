import Foundation
import Testing

@testable import TalkCatcherCore

private func frames(_ seconds: Double) -> Int { Int(seconds * AudioFormat.sampleRate) }

/// 1秒ごとに、その秒数を値に持つ音を作る。切り出した区切りがどの秒から始まるかを値で確かめられる
private func secondsMarked(from start: Int, count: Int) -> [Float] {
  (start..<(start + count)).flatMap { Array(repeating: Float($0), count: frames(1)) }
}

@Test("60秒ごとに区切り、2つ目からは前の10秒を重ねる")
func cutsWithOverlap() {
  var cutter = SegmentCutter(recordingID: "R1", segmentSeconds: 60, overlapSeconds: 10)
  let segments = cutter.feed(secondsMarked(from: 0, count: 130), voiced: true)
  #expect(segments.map(\.number) == [1, 2])
  #expect(segments[0].startSeconds == 0 && segments[0].endSeconds == 60)
  #expect(segments[1].startSeconds == 50 && segments[1].endSeconds == 120)
  #expect(segments[1].samples.count == frames(70))
  #expect(segments[1].samples.first == 50)

  let last = cutter.finish(endFrame: frames(130))
  #expect(last?.number == 3)
  #expect(last?.startSeconds == 110 && last?.endSeconds == 130)
  #expect(last?.samples.first == 110)
}

@Test("声の無い区切りは文字にしない。番号は詰めて振る")
func skipsSilentSegments() {
  var cutter = SegmentCutter(recordingID: "R1", segmentSeconds: 60, overlapSeconds: 10)
  var segments = cutter.feed(secondsMarked(from: 0, count: 60), voiced: true)
  segments += cutter.feed(secondsMarked(from: 60, count: 120), voiced: false)
  segments += cutter.feed(secondsMarked(from: 180, count: 60), voiced: true)
  // 2つ目(50〜120秒)は重ねた10秒に声があるので出す。3つ目(110〜180秒)は声が無いので出さない
  #expect(segments.map(\.startSeconds) == [0, 50, 170])
  #expect(segments.map(\.number) == [1, 2, 3])
}

@Test("録音の終わりで切った最後の区切りは、終わりの位置までにする")
func finishTruncatesToEnd() {
  var cutter = SegmentCutter(recordingID: "R1", segmentSeconds: 60, overlapSeconds: 10)
  _ = cutter.feed(secondsMarked(from: 0, count: 45), voiced: true)
  let last = cutter.finish(endFrame: frames(30))
  #expect(last?.endSeconds == 30)
  #expect(last?.samples.count == frames(30))
}

@Test("whisper の代わりのコマンドで文字を置き、区切った音声と一時フォルダを消す")
func transcriberWritesTextAndCleansUp() async throws {
  let root = FileManager.default.temporaryDirectory.appending(path: "tc-\(UUID().uuidString)")
  let chunks = root.appending(path: "chunks")
  let transcripts = root.appending(path: "transcripts")
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  // whisper-cli と同じく、-of の後ろのパスに .txt を付けて書く
  let fake = root.appending(path: "fake-whisper")
  try """
    #!/bin/sh
    while [ $# -gt 0 ]; do [ "$1" = "-of" ] && out="$2"; shift; done
    echo "見積もりは来週出します" > "$out.txt"
    """.write(to: fake, atomically: true, encoding: .utf8)
  try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)

  let outcomes = OutcomeBox()
  let transcriber = Transcriber(
    chunksDirectory: chunks, transcriptsDirectory: transcripts,
    config: .init(whisperPath: fake.path, modelPath: "unused", language: "ja"),
    report: { outcomes.append($0) })
  let segment = AudioSegment(
    recordingID: "R1", number: 2, startSeconds: 50, endSeconds: 120,
    samples: Array(repeating: 0.1, count: frames(1)))
  await transcriber.submit(segment)
  await transcriber.end(recordingID: "R1")
  await transcriber.drain()

  let text = try String(contentsOf: transcripts.appending(path: "R1/0002.txt"), encoding: .utf8)
  #expect(text == "[00:00:50-00:02:00]\n見積もりは来週出します\n")
  #expect(!FileManager.default.fileExists(atPath: chunks.appending(path: "R1").path))
  let hidden = try FileManager.default.contentsOfDirectory(atPath: transcripts.appending(path: "R1").path)
  #expect(hidden == ["0002.txt"])
  #expect(outcomes.count == 1)
}

private final class OutcomeBox: @unchecked Sendable {
  private let lock = NSLock()
  private var items: [Transcriber.Outcome] = []
  func append(_ outcome: Transcriber.Outcome) { lock.withLock { items.append(outcome) } }
  var count: Int { lock.withLock { items.count } }
}
