import Foundation
import Observation
import ServiceManagement
import TalkCatcherCore

@MainActor
@Observable
final class SettingsStore {
  private static let key = "settings"

  private(set) var settings: AppSettings
  private(set) var launchAtLogin = SMAppService.mainApp.status == .enabled
  private(set) var launchAtLoginError: String?
  @ObservationIgnored var onChange: ((AppSettings) -> Void)?
  @ObservationIgnored private let defaults: UserDefaults

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    settings =
      defaults.data(forKey: Self.key).flatMap {
        try? JSONDecoder().decode(AppSettings.self, from: $0)
      }
      ?? AppSettings()
  }

  func update(_ change: (inout AppSettings) -> Void) {
    var next = settings
    change(&next)
    guard next != settings else { return }
    settings = next
    if let data = try? JSONEncoder().encode(next) {
      defaults.set(data, forKey: Self.key)
    }
    onChange?(next)
  }

  func setLaunchAtLogin(_ enabled: Bool) {
    do {
      if enabled {
        try SMAppService.mainApp.register()
      } else {
        try SMAppService.mainApp.unregister()
      }
      launchAtLoginError = nil
    } catch {
      launchAtLoginError = error.localizedDescription
    }
    launchAtLogin = SMAppService.mainApp.status == .enabled
  }
}
