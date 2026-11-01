import SwiftUI
import TalkCatcherCore

struct MenuContent: View {
  @Environment(CaptureStore.self) private var capture
  @Environment(SettingsStore.self) private var settings
  @Environment(\.openSettings) private var openSettings

  var body: some View {
    Text(
      capture.state.statusText(endSilence: settings.settings.capture.endSilenceSeconds))
    if let error = capture.state.lastError {
      Text(error)
    }

    Divider()
    Section("直近の録音") {
      if capture.state.recent.isEmpty {
        Text("まだ録音はない。話し始めると、ここに並ぶ")
      }
      ForEach(capture.state.recent.prefix(5)) { item in
        RecentItem(item: item)
      }
    }

    Divider()
    CutItem()
    PauseItems()

    Divider()
    Button("録音フォルダを開く") { NSWorkspace.shared.open(Paths.recordings) }
    Button("ログを見る") { NSWorkspace.shared.open(Paths.hookLog) }
      .disabled(!FileManager.default.fileExists(atPath: Paths.hookLog.path))
    Button("設定…") {
      NSApp.activate()
      openSettings()
    }
    .keyboardShortcut(",")

    Divider()
    Button("talk-catcher を終了") { Task { await capture.quit() } }
      .keyboardShortcut("q")
  }
}

private struct RecentItem: View {
  @Environment(CaptureStore.self) private var capture
  let item: HandoffQueue.Item

  var body: some View {
    if item.status == .failed {
      Menu(item.menuTitle) {
        Button("もう一度渡す") { capture.retry(item) }
        Button("ログを見る") { NSWorkspace.shared.open(Paths.hookLog) }
        Button("Finder で表示") {
          NSWorkspace.shared.activateFileViewerSelecting([item.recording.url])
        }
      }
    } else {
      Button(item.menuTitle) {
        NSWorkspace.shared.activateFileViewerSelecting([item.recording.url])
      }
    }
  }
}

private struct CutItem: View {
  @Environment(CaptureStore.self) private var capture

  var body: some View {
    switch capture.state.phase {
    case .recording, .waitingEnd:
      Button("いまの録音を区切る") { Task { await capture.cutNow() } }
    default:
      EmptyView()
    }
  }
}

private struct PauseItems: View {
  @Environment(CaptureStore.self) private var capture

  var body: some View {
    if case .paused = capture.state.phase {
      Button("再開する") { capture.resume() }
    } else {
      Button("15分止める") { Task { await capture.pause(minutes: 15) } }
      Button("1時間止める") { Task { await capture.pause(minutes: 60) } }
      Button("再開するまで止める") { Task { await capture.pause(minutes: nil) } }
    }
  }
}
