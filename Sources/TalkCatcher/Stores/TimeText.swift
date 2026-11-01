import Foundation
import TalkCatcherCore

enum TimeText {
  static func clock(_ date: Date) -> String {
    date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
  }

  static func duration(_ interval: TimeInterval) -> String {
    let seconds = max(0, Int(interval.rounded()))
    return seconds >= 60
      ? "\(seconds / 60)分\(String(format: "%02d", seconds % 60))秒" : "\(seconds)秒"
  }

}

extension CaptureState {
  func statusText(endSilence: TimeInterval) -> String {
    switch phase {
    case .starting: "準備中"
    case .noPermission: "マイクを使えない — システム設定で許可して"
    case .listening: "待機中 — 声を待ってる"
    case .recording(let since):
      "録音中 — \(TimeText.clock(since)) から"
    case .waitingEnd(_, let lastVoiceAt):
      "終わり待ち — \(TimeText.clock(lastVoiceAt.addingTimeInterval(endSilence))) まで黙っていたら区切る"
    case .paused(let until): until.map { "一時停止中 — \(TimeText.clock($0)) まで" } ?? "一時停止中 — 再開するまで"
    case .failed(let message): message
    }
  }
}

extension HandoffQueue.Item {
  var menuTitle: String {
    let range = "\(TimeText.clock(recording.startedAt))〜\(TimeText.clock(recording.endedAt))"
    return "\(range)  \(TimeText.duration(recording.duration))・\(statusText)"
  }

  var statusText: String {
    switch status {
    case .saved: "保存だけ"
    case .queued: "待ち"
    case .running: "渡してる…"
    case .succeeded: "渡した"
    case .waitingRetry(let until): "\(TimeText.clock(until)) にもう一度"
    case .failed: "失敗(\(attempts)回)"
    }
  }
}
