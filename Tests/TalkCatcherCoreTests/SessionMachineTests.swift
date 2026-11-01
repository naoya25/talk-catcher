import Testing

@testable import TalkCatcherCore

private func makeMachine(
  start: Int = 3, startGap: Int = 0, preroll: Int = 10, endSilence: Int = 20, tail: Int = 5,
  maxLength: Int = 1_000
) -> SessionMachine {
  var config = SessionMachine.Config(settings: CaptureSettings())
  config.startChunks = start
  config.startGapChunks = startGap
  config.prerollChunks = preroll
  config.endSilenceChunks = endSilence
  config.tailChunks = tail
  config.maxLengthChunks = maxLength
  return SessionMachine(config: config)
}

/// voiced の並びを chunk 0 から順に流し、出た Action を chunk 番号つきで返す
private func run(_ machine: inout SessionMachine, _ voiced: [Bool], from start: Int = 0) -> [(
  Int, SessionMachine.Action
)] {
  voiced.enumerated().flatMap { offset, isVoiced in
    machine.feed(chunk: start + offset, voiced: isVoiced).map { (start + offset, $0) }
  }
}

@Test("声が3 chunk 続いたら、最初の声から preroll 分さかのぼって録り始める")
func startsAfterThreeVoicedChunksWithPreroll() {
  var machine = makeMachine()
  let actions = run(&machine, Array(repeating: false, count: 30) + [true, true, true])
  #expect(actions.count == 1)
  #expect(actions.first?.0 == 32)
  #expect(actions.first?.1 == .start(fromChunk: 20))
}

@Test("声が2 chunk で途切れたら録り始めない")
func shortVoiceDoesNotStart() {
  var machine = makeMachine()
  let actions = run(&machine, [true, true, false, true, true, false])
  #expect(actions.isEmpty)
  #expect(machine.phase == .idle)
}

@Test("録り始めは 0 より前にさかのぼらない")
func prerollIsClampedAtZero() {
  var machine = makeMachine()
  let actions = run(&machine, [true, true, true])
  #expect(actions.first?.1 == .start(fromChunk: 0))
}

@Test("最後の声から endSilence 分黙ったら、最後の声+tail で区切る")
func finishesAfterSilenceWithTail() {
  var machine = makeMachine(endSilence: 20, tail: 5)
  let actions = run(
    &machine, Array(repeating: true, count: 10) + Array(repeating: false, count: 25))
  #expect(actions.map(\.1) == [.start(fromChunk: 0), .finish(endChunk: 15, reason: .silence)])
  #expect(actions.last?.0 == 29)
  #expect(machine.phase == .idle)
}

@Test("黙っている途中でまた声が出たら、同じ1本を続ける")
func voiceDuringSilenceContinues() {
  var machine = makeMachine(endSilence: 20)
  let voiced =
    Array(repeating: true, count: 5) + Array(repeating: false, count: 15)
    + Array(repeating: true, count: 5)
  let actions = run(&machine, voiced)
  #expect(actions.map(\.1) == [.start(fromChunk: 0)])
  #expect(machine.phase == .recording(startChunk: 0, lastVoicedChunk: 24))
}

@Test("上限の長さに達したら区切り、続けて次の1本を始める")
func splitsAtMaxLength() {
  var machine = makeMachine(maxLength: 50)
  let actions = run(&machine, Array(repeating: true, count: 60))
  #expect(
    actions.map(\.1) == [
      .start(fromChunk: 0), .finish(endChunk: 50, reason: .maxLength), .start(fromChunk: 50),
    ])
}

@Test("録音中に止めたら、最後の声+tail か今のどちらか早い方で区切る")
func stopFinishesAtEarlierOfTailAndNow() {
  var machine = makeMachine(tail: 5)
  _ = run(&machine, Array(repeating: true, count: 10) + [false, false])
  #expect(machine.stop(at: 11, reason: .stopped) == .finish(endChunk: 12, reason: .stopped))

  var later = makeMachine(tail: 5)
  _ = run(&later, Array(repeating: true, count: 10) + Array(repeating: false, count: 10))
  #expect(later.stop(at: 19, reason: .quit) == .finish(endChunk: 15, reason: .quit))
}

@Test("録音していないときに止めても何も起きない")
func stopWhileIdleDoesNothing() {
  var machine = makeMachine()
  #expect(machine.stop(at: 5, reason: .stopped) == nil)
}

@Test("声が設定の長さに届かない短い音では録り始めない")
func shortBurstDoesNotStart() {
  var machine = makeMachine(start: 31, startGap: 9)
  let burst = Array(repeating: true, count: 20) + Array(repeating: false, count: 15)
  let actions = run(&machine, burst + burst)
  #expect(actions.isEmpty)
  #expect(machine.phase == .idle)
}

@Test("息継ぎの短い切れ目は挟んでも、声の長さを足して録り始める")
func shortGapsKeepCounting() {
  var machine = makeMachine(start: 31, startGap: 9, preroll: 10)
  let phrase = Array(repeating: true, count: 12) + Array(repeating: false, count: 5)
  let silence = Array(repeating: false, count: 30)
  let actions = run(&machine, silence + phrase + phrase + phrase)
  #expect(actions.count == 1)
  #expect(actions.first?.1 == .start(fromChunk: 20))
}

@Test("録り始めは、最初の声から preroll 分さかのぼる")
func prerollCountsFromFirstVoice() {
  var machine = makeMachine(start: 31, startGap: 0, preroll: 10)
  let actions = run(
    &machine, Array(repeating: false, count: 50) + Array(repeating: true, count: 31))
  #expect(actions.first?.1 == .start(fromChunk: 40))
}
