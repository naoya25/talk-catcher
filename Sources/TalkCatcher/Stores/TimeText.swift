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

  /// Calendar の weekday(1 = 日曜)から引く
  static let weekdayNames = ["日", "月", "火", "水", "木", "金", "土"]
  /// 設定の画面に並べる順。月曜から
  static let weekdayOrder = [2, 3, 4, 5, 6, 7, 1]

  static func weekdayName(_ weekday: Int) -> String { weekdayNames[(weekday - 1) % 7] }

  /// 今日なら時刻だけ、明日なら「明日」、その先は曜日を付ける
  static func dayClock(_ date: Date, calendar: Calendar = .current) -> String {
    if calendar.isDateInToday(date) { return clock(date) }
    if calendar.isDateInTomorrow(date) { return "明日 \(clock(date))" }
    return "\(weekdayName(calendar.component(.weekday, from: date)))曜 \(clock(date))"
  }

  static func minuteClock(_ minute: Int) -> String {
    String(format: "%d:%02d", minute / 60, minute % 60)
  }
}

extension QuietRule {
  /// 「月火水木金 22:00〜翌7:00」
  var summary: String {
    guard !weekdays.isEmpty else { return "曜日を選ぶまで効かない" }
    let days =
      weekdays.count == 7
      ? "毎日" : TimeText.weekdayOrder.filter(weekdays.contains).map(TimeText.weekdayName).joined()
    if length == QuietRule.minutesPerDay && startMinute == 0 { return "\(days) 1日中" }
    let end = crossesMidnight ? "翌\(TimeText.minuteClock(endMinute))" : TimeText.minuteClock(endMinute)
    return "\(days) \(TimeText.minuteClock(startMinute))〜\(end)"
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
    case .quiet(let until):
      until.map { "録らない時間 — \(TimeText.dayClock($0)) まで" } ?? "録らない時間 — 次の週まで続く"
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
