import Foundation
import Testing

@testable import TalkCatcherCore

private let tokyo: Calendar = {
  var calendar = Calendar(identifier: .gregorian)
  calendar.timeZone = TimeZone(identifier: "Asia/Tokyo")!
  return calendar
}()

/// 2026-11-09 は月曜。day は 9(月)〜15(日)、16 は次の月曜
private func at(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
  tokyo.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))!
}

private let weekdays: Set<Int> = [2, 3, 4, 5, 6]
private let weekend: Set<Int> = [7, 1]

@Test("始まりと終わりが同じ日なら、その曜日のその間だけ録らない")
func sameDayRule() {
  let schedule = QuietSchedule(rules: [
    QuietRule(weekdays: [2], startMinute: 9 * 60, endMinute: 17 * 60)
  ])
  #expect(tokyo.component(.weekday, from: at(9, 0)) == 2)
  #expect(!schedule.contains(at(9, 8, 59), calendar: tokyo))
  #expect(schedule.contains(at(9, 9), calendar: tokyo))
  #expect(schedule.contains(at(9, 16, 59), calendar: tokyo))
  #expect(!schedule.contains(at(9, 17), calendar: tokyo))
  #expect(!schedule.contains(at(10, 10), calendar: tokyo))
}

@Test("終わりが始まりより前なら、次の日の終わりの時刻まで続く")
func overnightRule() {
  let schedule = QuietSchedule(rules: [
    QuietRule(weekdays: weekdays, startMinute: 22 * 60, endMinute: 7 * 60)
  ])
  #expect(!schedule.contains(at(9, 6), calendar: tokyo))  // 月の朝。前の日曜は入っていない
  #expect(schedule.contains(at(9, 23), calendar: tokyo))
  #expect(schedule.contains(at(10, 6, 59), calendar: tokyo))
  #expect(!schedule.contains(at(10, 7), calendar: tokyo))
  #expect(schedule.contains(at(14, 6), calendar: tokyo))  // 土の朝は、金の夜からの続き
  #expect(!schedule.contains(at(14, 23), calendar: tokyo))
}

@Test("始まりと終わりが同じなら24時間。0:00〜0:00 はその曜日の1日中")
func wholeDayRule() {
  let schedule = QuietSchedule(rules: [
    QuietRule(weekdays: weekend, startMinute: 0, endMinute: 0)
  ])
  #expect(!schedule.contains(at(13, 23, 59), calendar: tokyo))
  #expect(schedule.contains(at(14, 0), calendar: tokyo))
  #expect(schedule.contains(at(15, 23, 59), calendar: tokyo))
  #expect(!schedule.contains(at(16, 0), calendar: tokyo))
}

@Test("録らない時間の終わりは、その行の終わりの時刻")
func endOfOvernight() {
  let schedule = QuietSchedule(rules: [
    QuietRule(weekdays: weekdays, startMinute: 22 * 60, endMinute: 7 * 60)
  ])
  #expect(schedule.end(ofQuietAt: at(9, 23), calendar: tokyo) == at(10, 7))
  #expect(schedule.end(ofQuietAt: at(10, 6, 30), calendar: tokyo) == at(10, 7))
  #expect(schedule.end(ofQuietAt: at(10, 12), calendar: tokyo) == nil)
}

@Test("続けて並ぶ行は1つの録らない時間として、最後の終わりまで延びる")
func endAcrossJoinedRules() {
  let schedule = QuietSchedule(rules: [
    QuietRule(weekdays: weekdays, startMinute: 20 * 60, endMinute: 8 * 60),
    QuietRule(weekdays: weekend, startMinute: 0, endMinute: 0),
  ])
  // 金の夜 → 土日 → 月の 0:00 で抜ける。月の 20:00 まではまた録る
  #expect(schedule.end(ofQuietAt: at(13, 21), calendar: tokyo) == at(16, 0))
}

@Test("毎日1日中なら、終わりは無い")
func endlessQuiet() {
  let schedule = QuietSchedule(rules: [
    QuietRule(weekdays: Set(1...7), startMinute: 0, endMinute: 0)
  ])
  #expect(schedule.contains(at(11, 12), calendar: tokyo))
  #expect(schedule.end(ofQuietAt: at(11, 12), calendar: tokyo) == nil)
}

@Test("曜日を1つも選んでいない行は効かない")
func emptyWeekdays() {
  let schedule = QuietSchedule(rules: [QuietRule(weekdays: [], startMinute: 0, endMinute: 0)])
  #expect(!schedule.contains(at(11, 12), calendar: tokyo))
}

@Test("録らない時間が無い前の版の設定も、コマンドを残したまま読める")
func decodesSettingsWithoutQuiet() throws {
  let json =
    #"{"capture":{"speechProbability":0.5,"minDBFS":-40,"prerollSeconds":3,"endSilenceSeconds":300,"tailSeconds":5,"maxLengthSeconds":3600},"command":"echo hi","inputDeviceUID":"mic-1"}"#
  let settings = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
  #expect(settings.command == "echo hi")
  #expect(settings.inputDeviceUID == "mic-1")
  #expect(settings.capture.minDBFS == -40)
  #expect(settings.quiet.rules.isEmpty)
}

@Test("録らない時間は保存して読み直しても同じ")
func roundTripsQuiet() throws {
  var settings = AppSettings()
  settings.command = "echo hi"
  settings.quiet.rules = [QuietRule(weekdays: weekend, startMinute: 0, endMinute: 0)]
  let data = try JSONEncoder().encode(settings)
  #expect(try JSONDecoder().decode(AppSettings.self, from: data) == settings)
}
