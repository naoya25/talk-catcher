import SwiftUI

struct MenuBarLabel: View {
  @Environment(CaptureStore.self) private var capture

  var body: some View {
    switch capture.state.phase {
    case .recording:
      Image(systemName: "record.circle.fill")
    case .waitingEnd:
      Image(systemName: "hourglass")
    case .paused, .noPermission:
      Image(systemName: "mic.slash")
    case .failed:
      Image(systemName: "exclamationmark.triangle")
    case .starting, .listening:
      Image(systemName: capture.state.hasFailedHandoff ? "mic.badge.xmark" : "mic")
    }
  }
}
