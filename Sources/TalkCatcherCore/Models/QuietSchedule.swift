import Foundation

/// 録らない時間帯の1行。曜日と、始まり・終わりの時刻で決める
public struct QuietRule: Codable, Sendable, Equatable, Identifiable {
  public static let minutesPerDay = 24 * 60

  public var id: UUID
  /// Calendar の weekday(1 = 日曜 … 7 = 土曜)。始まりの時刻が来る曜日を持つ
  public var weekdays: Set<Int>
  /// 0:00 からの分
  public var startMinute: Int
  /// 始まり以前なら次の日のこの時刻まで続く(22:00〜7:00)。始まりと同じなら24時間
  public var endMinute: Int

  public init(id: UUID = UUID(), weekdays: Set<Int>, startMinute: Int, endMinute: Int) {
    self.id = id
    self.weekdays = weekdays
    self.startMinute = startMinute
    self.endMinute = endMinute
  }

  /// 始まりから終わりまでの分。1〜1440
  public var length: Int {
    let length = (endMinute - startMinute + Self.minutesPerDay) % Self.minutesPerDay
    return length == 0 ? Self.minutesPerDay : length
  }

  /// 終わりが次の日に回るか
  public var crossesMidnight: Bool { startMinute + length > Self.minutesPerDay }

  func contains(weekday: Int, minute: Int) -> Bool {
    if weekdays.contains(weekday), minute >= startMinute, minute < startMinute + length {
      return true
    }
    // 前の日に始まって、日をまたいで続いている分
    let previous = weekday == 1 ? 7 : weekday - 1
    return weekdays.contains(previous) && minute + Self.minutesPerDay < startMinute + length
  }
}

/// 録らない時間帯の全体。どれか1行に入っていれば録らない
public struct QuietSchedule: Codable, Sendable, Equatable {
  // 時間帯を足し続けても、終わりを探すのは次の週まで。それより続くなら「終わりなし」とする
  private static let searchDays = 8

  public var rules: [QuietRule]

  public init(rules: [QuietRule] = []) {
    self.rules = rules
  }

  public func contains(_ date: Date, calendar: Calendar = .current) -> Bool {
    let components = calendar.dateComponents([.weekday, .hour, .minute], from: date)
    guard let weekday = components.weekday, let hour = components.hour,
      let minute = components.minute
    else { return false }
    return rules.contains { $0.contains(weekday: weekday, minute: hour * 60 + minute) }
  }

  /// date が録らない時間なら、それが終わる時刻。録らない時間でないか、次の週まで終わらないなら nil
  public func end(ofQuietAt date: Date, calendar: Calendar = .current) -> Date? {
    guard contains(date, calendar: calendar) else { return nil }
    // 録らない時間が終わるのは、どれかの行の終わりの時刻だけ。行が続けて並ぶときは、その先の終わりまで延びる
    let today = calendar.startOfDay(for: date)
    let candidates = (0...Self.searchDays).flatMap { offset -> [Date] in
      guard let day = calendar.date(byAdding: .day, value: offset, to: today) else { return [] }
      return rules.compactMap { rule in
        calendar.date(
          bySettingHour: rule.endMinute / 60, minute: rule.endMinute % 60, second: 0, of: day)
      }
    }
    return candidates.filter { $0 > date }.sorted().first { !contains($0, calendar: calendar) }
  }
}
