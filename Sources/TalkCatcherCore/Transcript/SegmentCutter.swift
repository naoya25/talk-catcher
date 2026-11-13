import Foundation

/// 録音中の音声から切り出した、文字にする1区切り
public struct AudioSegment: Sendable {
  /// 録音1本の ID。録音の m4a のファイル名から拡張子を除いたもの
  public let recordingID: String
  /// 1 から始まる通し番号。声の無い区切りは飛ばすので、番号は詰めて振る
  public let number: Int
  /// 録音の頭から数えた、この区切りの始まりと終わり(秒)
  public let startSeconds: Double
  public let endSeconds: Double
  public let samples: [Float]
}

/// 録音中の音声を、決めた長さごとに前の区切りと少し重ねて切り出す
///
/// 区切りの境目で言葉が切れても、重ねた分の中には丸ごと入るようにするため、
/// 2つ目からは前の区切りの終わり `overlapFrames` 分を頭に足す
struct SegmentCutter {
  let recordingID: String
  private let segmentFrames: Int
  private let overlapFrames: Int

  /// `bufferOrigin` フレーム目からの音
  private var buffer: [Float] = []
  private var bufferOrigin = 0
  /// 次の区切りが始まるフレーム(重ねる分を足す前)
  private var segmentStart = 0
  private var totalFrames = 0
  /// 声だったフレームの範囲。区切りに声が入っているかを見るのに使う
  private var voicedRanges: [Range<Int>] = []
  private var emitted = 0

  init(recordingID: String, segmentSeconds: Double, overlapSeconds: Double) {
    self.recordingID = recordingID
    segmentFrames = max(1, Int(segmentSeconds * AudioFormat.sampleRate))
    overlapFrames = max(0, min(Int(overlapSeconds * AudioFormat.sampleRate), segmentFrames - 1))
  }

  mutating func feed(_ samples: [Float], voiced: Bool) -> [AudioSegment] {
    if voiced { voicedRanges.append(totalFrames..<(totalFrames + samples.count)) }
    buffer += samples
    totalFrames += samples.count
    var segments: [AudioSegment] = []
    while totalFrames >= segmentStart + segmentFrames {
      if let segment = cut(until: segmentStart + segmentFrames) { segments.append(segment) }
      segmentStart += segmentFrames
      trim()
    }
    return segments
  }

  /// 録音が切れたとき、最後の区切りを `endFrame` までで切り出す
  mutating func finish(endFrame: Int) -> AudioSegment? {
    let end = min(endFrame, totalFrames)
    guard end > segmentStart else { return nil }
    return cut(until: end)
  }

  private mutating func cut(until end: Int) -> AudioSegment? {
    let start = max(0, segmentStart - (segmentStart == 0 ? 0 : overlapFrames))
    guard voicedRanges.contains(where: { $0.overlaps(start..<end) }) else { return nil }
    emitted += 1
    let samples = Array(buffer[(start - bufferOrigin)..<(end - bufferOrigin)])
    return AudioSegment(
      recordingID: recordingID, number: emitted,
      startSeconds: Double(start) / AudioFormat.sampleRate,
      endSeconds: Double(end) / AudioFormat.sampleRate, samples: samples)
  }

  /// 次の区切りの頭(重ねる分を含む)より前の音は、もう要らないので捨てる
  private mutating func trim() {
    let keepFrom = max(bufferOrigin, segmentStart - overlapFrames)
    buffer.removeFirst(keepFrom - bufferOrigin)
    bufferOrigin = keepFrom
    voicedRanges.removeAll { $0.upperBound <= keepFrom }
  }
}
