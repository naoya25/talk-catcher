import AVFoundation
import Foundation
import Testing

@testable import TalkCatcherCore

/// 音量だけで声かどうかを決める、VAD の代わり
private final class LoudIsVoice: VoiceDetector {
  func probability(of chunk: [Float]) throws -> Float { AudioLevel.dbfs(chunk) > -30 ? 1 : 0 }
  func reset() {}
}

private func tone(seconds: Double, amplitude: Float) -> [Float] {
  (0..<Int(seconds * AudioFormat.sampleRate)).map {
    amplitude * Float(sin(2 * Double.pi * 220 * Double($0) / AudioFormat.sampleRate))
  }
}

private func temporaryDirectory() throws -> URL {
  let url = FileManager.default.temporaryDirectory.appending(
    path: "talk-catcher-tests-\(UUID().uuidString)")
  try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  return url
}

private var shortSettings: CaptureSettings {
  var settings = CaptureSettings()
  settings.prerollSeconds = 1
  settings.endSilenceSeconds = 2
  settings.tailSeconds = 0.5
  return settings
}

@Test("声→黙る で1本の m4a ができ、長さは preroll+声+tail になる")
func recordsOneFile() async throws {
  let directory = try temporaryDirectory()
  let pipeline = try CapturePipeline(settings: shortSettings, directory: directory) {
    LoudIsVoice()
  }

  await pipeline.process(tone(seconds: 3, amplitude: 0.001))
  await pipeline.process(tone(seconds: 2, amplitude: 0.3))
  await pipeline.process(tone(seconds: 3, amplitude: 0.001))
  let recording = try #require(await firstRecording(pipeline))

  let file = try AVAudioFile(forReading: recording.url)
  let seconds = Double(file.length) / file.fileFormat.sampleRate
  #expect(abs(seconds - 3.5) < 0.2)
  #expect(recording.reason == .silence)
  #expect(abs(recording.duration - 3.5) < 0.1)
  let leftovers =
    (try? FileManager.default.contentsOfDirectory(
      atPath: directory.appending(path: ".partial").path)) ?? []
  #expect(leftovers.isEmpty)
}

@Test("録音中に止めると、その時点までを書き出して返す")
func stopReturnsCurrentRecording() async throws {
  let directory = try temporaryDirectory()
  let pipeline = try CapturePipeline(settings: shortSettings, directory: directory) {
    LoudIsVoice()
  }
  await pipeline.process(tone(seconds: 2, amplitude: 0.3))
  let recording = try #require(await pipeline.stop(reason: .stopped))
  #expect(recording.reason == .stopped)
  #expect(FileManager.default.fileExists(atPath: recording.url.path))
}

@Test("小さい音だけなら何も残らない")
func quietLeavesNothing() async throws {
  let directory = try temporaryDirectory()
  let pipeline = try CapturePipeline(settings: shortSettings, directory: directory) {
    LoudIsVoice()
  }
  await pipeline.process(tone(seconds: 5, amplitude: 0.001))
  #expect(await pipeline.stop(reason: .stopped) == nil)
  #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
}

private func firstRecording(_ pipeline: CapturePipeline) async -> Recording? {
  for await event in pipeline.events {
    if case .recorded(let recording) = event { return recording }
  }
  return nil
}

@Test("区切ったあとも聞き続け、次の1本は区切った所より前にさかのぼらない")
func cutKeepsListeningWithoutOverlap() async throws {
  let directory = try temporaryDirectory()
  let pipeline = try CapturePipeline(settings: shortSettings, directory: directory) {
    LoudIsVoice()
  }
  await pipeline.process(tone(seconds: 2, amplitude: 0.3))
  let first = try #require(await pipeline.cut(reason: .manual))
  #expect(first.reason == .manual)

  await pipeline.process(tone(seconds: 2, amplitude: 0.3))
  await pipeline.process(tone(seconds: 3, amplitude: 0.001))
  let second = try #require(await firstRecording(pipeline))
  #expect(second.startedAt >= first.endedAt)
}

@Test("録音中に区切りを出し、録音が切れたら区切りの終わりを知らせてから録音を返す")
func emitsSegmentsWhileRecording() async throws {
  let directory = try temporaryDirectory()
  var settings = shortSettings
  settings.segmentSeconds = 2
  settings.overlapSeconds = 0.5
  let pipeline = try CapturePipeline(settings: settings, directory: directory) {
    LoudIsVoice()
  }
  await pipeline.process(tone(seconds: 3, amplitude: 0.001))
  await pipeline.process(tone(seconds: 5, amplitude: 0.3))
  await pipeline.process(tone(seconds: 3, amplitude: 0.001))

  var segments: [AudioSegment] = []
  var ended: String?
  for await event in pipeline.events {
    switch event {
    case .segment(let segment): segments.append(segment)
    case .segmentsEnded(let id): ended = id
    case .recorded(let recording):
      #expect(ended == recording.url.deletingPathExtension().lastPathComponent)
      #expect(segments.allSatisfy { $0.recordingID == ended })
      // 声は録音の 1〜6秒。2秒ごとに0.5秒重ねて区切ると、声を含む区切りは4つ。
      // 4つ目(5.5〜8秒)は黙っている間に切れるので、録音の終わり(6.5秒)より後の無音も入る
      #expect(segments.map(\.number) == [1, 2, 3, 4])
      #expect(segments.map(\.startSeconds) == [0, 1.5, 3.5, 5.5])
      #expect((segments.last?.endSeconds ?? 0) >= 6.5)
      return
    default: continue
    }
  }
  Issue.record("録音が返ってこなかった")
}

/// テストから進められる時計
private final class StepClock: @unchecked Sendable {
  var date = Date(timeIntervalSince1970: 1_000_000)
}

@Test("音が途切れた後の時刻は、受け取った音の長さでなく実際の時刻に合う")
func timeFollowsWallClockAfterGap() async throws {
  let clock = StepClock()
  let pipeline = try CapturePipeline(
    settings: shortSettings, directory: try temporaryDirectory(), clock: { clock.date }
  ) { LoudIsVoice() }
  let start = clock.date

  clock.date = start.addingTimeInterval(1)
  await pipeline.process(tone(seconds: 1, amplitude: 0.001))
  // スリープで40分音が来なかった
  clock.date = start.addingTimeInterval(1 + 2400 + 1)
  await pipeline.process(tone(seconds: 1, amplitude: 0.001))

  let lastChunk = AudioFormat.chunks(forSeconds: 2) - 1
  let time = await pipeline.time(ofChunk: lastChunk)
  #expect(abs(time.timeIntervalSince(clock.date)) < 0.2)
  // 途切れる前の音の時刻は動かない
  let first = await pipeline.time(ofChunk: 0)
  #expect(abs(first.timeIntervalSince(start)) < 0.1)
}
