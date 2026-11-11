import Foundation

public struct AppSettings: Codable, Equatable, Sendable {
  public var capture = CaptureSettings()
  public var command = ""
  public var inputDeviceUID: String?
  public var inputDeviceName: String?
  public var quiet = QuietSchedule()

  public init() {}

  // 項目を足しても、前の版で保存した設定(コマンドなど)が読めなくならないようにする
  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let fallback = AppSettings()
    capture = try container.decodeIfPresent(CaptureSettings.self, forKey: .capture) ?? fallback.capture
    command = try container.decodeIfPresent(String.self, forKey: .command) ?? fallback.command
    inputDeviceUID = try container.decodeIfPresent(String.self, forKey: .inputDeviceUID)
    inputDeviceName = try container.decodeIfPresent(String.self, forKey: .inputDeviceName)
    quiet = try container.decodeIfPresent(QuietSchedule.self, forKey: .quiet) ?? fallback.quiet
  }
}
