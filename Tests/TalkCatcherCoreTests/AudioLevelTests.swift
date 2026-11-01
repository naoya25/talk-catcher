import Foundation
import Testing

@testable import TalkCatcherCore

@Test("振幅 1 の正弦波は約 -3 dBFS")
func fullScaleSine() {
  let samples = (0..<16_000).map { Float(sin(2 * Double.pi * 440 * Double($0) / 16_000)) }
  #expect(abs(AudioLevel.dbfs(samples) - (-3.01)) < 0.05)
}

@Test("無音は下限の値になる")
func silenceIsFloor() {
  #expect(AudioLevel.dbfs([Float](repeating: 0, count: 512)) == AudioLevel.floor)
  #expect(AudioLevel.dbfs([]) == AudioLevel.floor)
}
