import SwiftUI
import TalkCatcherCore

struct SettingsPage: View {
  var body: some View {
    TabView {
      CommandTab()
        .tabItem { Label("コマンド", systemImage: "terminal") }
      ListeningTab()
        .tabItem { Label("聞き取り", systemImage: "waveform") }
      GeneralTab()
        .tabItem { Label("一般", systemImage: "gearshape") }
    }
    .frame(width: 580, height: 440)
  }
}

private enum CommandPreset: String, CaseIterable, Identifiable {
  case openAI = "文字起こし API に送る(OpenAI)"
  case whisper = "手元で文字起こし(whisper.cpp)"
  case notify = "通知だけ出す"

  var id: String { rawValue }

  var command: String {
    switch self {
    case .openAI:
      """
      curl -sf https://api.openai.com/v1/audio/transcriptions \\
        -H "Authorization: Bearer $(security find-generic-password -s openai-api-key -w)" \\
        -F model=gpt-4o-transcribe -F file=@"$TC_FILE" \\
        > "${TC_FILE%.m4a}.json"
      """
    case .whisper:
      """
      ffmpeg -loglevel error -i "$TC_FILE" -ar 16000 -ac 1 "${TC_FILE%.m4a}.wav" \\
        && whisper-cli -m ~/models/ggml-large-v3-turbo.bin -l ja -otxt -f "${TC_FILE%.m4a}.wav"
      """
    case .notify:
      """
      osascript -e "display notification \\"$TC_DURATION_SEC 秒の録音を保存した\\" with title \\"talk-catcher\\""
      """
    }
  }
}

private struct CommandTab: View {
  @Environment(SettingsStore.self) private var settings
  @Environment(CaptureStore.self) private var capture
  @State private var testOutput: String?
  @State private var isTesting = false

  var body: some View {
    Form {
      Section {
        TextEditor(text: command)
          .font(.system(.body, design: .monospaced))
          .frame(minHeight: 110)
        HStack {
          Menu("例から入れる") {
            ForEach(CommandPreset.allCases) { preset in
              Button(preset.rawValue) { command.wrappedValue = preset.command }
            }
          }
          .fixedSize()
          Spacer()
          Button(isTesting ? "実行中…" : "最後の録音で試す") { test() }
            .disabled(isTesting || command.wrappedValue.isEmpty)
        }
      } header: {
        Text("録り終えたら実行するコマンド")
      } footer: {
        Text("空なら、ファイルを保存するだけ。鍵はここに書かず、Keychain から読む")
      }
      if let testOutput {
        Section("試した結果") {
          Text(testOutput)
            .font(.system(.caption, design: .monospaced))
            .textSelection(.enabled)
        }
      }
      Section("コマンドに渡るもの") {
        LabeledContent("$1 / $TC_FILE", value: "録音ファイルの絶対パス")
        LabeledContent("$TC_STARTED_AT / $TC_ENDED_AT", value: "頭と終わりの時刻(ISO 8601)")
        LabeledContent("$TC_DURATION_SEC", value: "長さ(秒)")
        LabeledContent("$TC_REASON", value: "silence / max_length / manual / stopped / quit")
      }
    }
    .formStyle(.grouped)
  }

  private var command: Binding<String> {
    Binding(
      get: { settings.settings.command },
      set: { value in settings.update { $0.command = value } }
    )
  }

  private func test() {
    isTesting = true
    let command = settings.settings.command
    Task {
      testOutput = await capture.testCommand(command)
      isTesting = false
    }
  }
}

private struct ListeningTab: View {
  @Environment(SettingsStore.self) private var settings
  @Environment(CaptureStore.self) private var capture
  @State private var devices: [InputDevice] = []

  var body: some View {
    Form {
      Section {
        Picker("マイク", selection: inputDevice) {
          Text("システムのデフォルト").tag(String?.none)
          ForEach(devices) { device in
            Text(device.name).tag(String?.some(device.uid))
          }
          if let uid = settings.settings.inputDeviceUID, !devices.contains(where: { $0.uid == uid })
          {
            Text("\(settings.settings.inputDeviceName ?? uid)(つながっていない)").tag(String?.some(uid))
          }
        }
      } footer: {
        if capture.usingFallbackInput {
          Text("選んだマイクがつながっていないので、いまは \(capture.inputDeviceName ?? "デフォルト") で聞いている")
        } else if let name = capture.inputDeviceName {
          Text("いま \(name) で聞いている")
        }
      }
      Section {
        Slider(value: minDBFS, in: -60...(-10), step: 1) {
          Text("音量のしきい値")
        } minimumValueLabel: {
          Text("-60")
        } maximumValueLabel: {
          Text("-10")
        }
        LevelBar(
          level: capture.level, threshold: settings.settings.capture.minDBFS,
          voiced: capture.voiced)
      } header: {
        Text("音量のしきい値 \(Int(settings.settings.capture.minDBFS)) dBFS")
      } footer: {
        Text("いまの音 \(Int(capture.level)) dBFS。声のときに線より右なら flag が立つ。遠くの会話が線の左に収まる位置にする")
      }
      Section {
        Picker("録り始める長さ", selection: capture(\.startSpeechSeconds)) {
          ForEach([0.5, 1, 2, 3], id: \.self) { Text("声が\($0.formatted())秒続いたら").tag($0) }
        }
        Picker("遡る長さ", selection: capture(\.prerollSeconds)) {
          ForEach([1.0, 3, 5, 10], id: \.self) { Text("\(Int($0))秒").tag($0) }
        }
        Picker("終わりの判定", selection: capture(\.endSilenceSeconds)) {
          ForEach([60.0, 180, 300, 600], id: \.self) { Text("\(Int($0) / 60)分黙ったら").tag($0) }
        }
        Picker("1本の上限", selection: capture(\.maxLengthSeconds)) {
          ForEach([1800.0, 3600, 7200], id: \.self) { Text("\(Int($0) / 60)分").tag($0) }
        }
      }
    }
    .formStyle(.grouped)
    .task { devices = InputDevices.all() }
  }

  private var inputDevice: Binding<String?> {
    Binding(
      get: { settings.settings.inputDeviceUID },
      set: { uid in
        settings.update {
          $0.inputDeviceUID = uid
          $0.inputDeviceName = devices.first { $0.uid == uid }?.name
        }
      }
    )
  }

  private var minDBFS: Binding<Double> {
    Binding(
      get: { Double(settings.settings.capture.minDBFS) },
      set: { value in settings.update { $0.capture.minDBFS = Float(value) } }
    )
  }

  private func capture(_ keyPath: WritableKeyPath<CaptureSettings, Double>) -> Binding<Double> {
    Binding(
      get: { settings.settings.capture[keyPath: keyPath] },
      set: { value in settings.update { $0.capture[keyPath: keyPath] = value } }
    )
  }
}

private struct LevelBar: View {
  let level: Float
  let threshold: Float
  let voiced: Bool

  var body: some View {
    GeometryReader { proxy in
      let width = proxy.size.width
      ZStack(alignment: .leading) {
        Capsule().fill(.quaternary)
        Capsule()
          .fill(voiced && level >= threshold ? Color.green : Color.secondary)
          .frame(width: width * Self.fraction(level))
        Rectangle()
          .fill(.primary)
          .frame(width: 2, height: 16)
          .offset(x: width * Self.fraction(threshold) - 1)
      }
    }
    .frame(height: 10)
    .animation(.linear(duration: 0.1), value: level)
  }

  private static func fraction(_ dbfs: Float) -> CGFloat {
    CGFloat(min(max((dbfs + 60) / 60, 0), 1))
  }
}

private struct GeneralTab: View {
  @Environment(SettingsStore.self) private var settings

  var body: some View {
    Form {
      Section {
        Toggle("ログイン時に起動する", isOn: launchAtLogin)
        if let error = settings.launchAtLoginError {
          Text(error).foregroundStyle(.red)
        }
      }
      Section("保存先") {
        LabeledContent("録音", value: Paths.recordings.path)
        LabeledContent("ログ", value: Paths.hookLog.path)
        Button("録音フォルダを開く") { NSWorkspace.shared.open(Paths.recordings) }
      }
    }
    .formStyle(.grouped)
  }

  private var launchAtLogin: Binding<Bool> {
    Binding(get: { settings.launchAtLogin }, set: { settings.setLaunchAtLogin($0) })
  }
}
