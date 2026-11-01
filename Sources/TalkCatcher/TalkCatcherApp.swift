import SwiftUI

@main
struct TalkCatcherApp: App {
  // 依存の向き: settings → capture
  @State private var settings: SettingsStore
  @State private var capture: CaptureStore

  init() {
    let settings = SettingsStore()
    let capture = CaptureStore(settings: settings)
    settings.onChange = { [weak capture] in capture?.apply($0) }
    _settings = State(initialValue: settings)
    _capture = State(initialValue: capture)
    Task { await capture.start() }
  }

  var body: some Scene {
    MenuBarExtra {
      MenuContent()
        .environment(settings)
        .environment(capture)
    } label: {
      MenuBarLabel()
        .environment(capture)
    }
    .menuBarExtraStyle(.menu)

    Settings {
      SettingsPage()
        .environment(settings)
        .environment(capture)
    }
  }
}
