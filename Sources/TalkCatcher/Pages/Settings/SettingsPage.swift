import SwiftUI
import TalkCatcherCore

struct SettingsPage: View {
  var body: some View {
    TabView {
      CommandTab()
        .tabItem { Label("コマンド", systemImage: "terminal") }
      ListeningTab()
        .tabItem { Label("聞き取り", systemImage: "waveform") }
      QuietTab()
        .tabItem { Label("録らない時間", systemImage: "moon.zzz") }
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
      Section {
        Toggle("録音中に文字にする", isOn: transcribe)
        Picker("区切る長さ", selection: capture(\.segmentSeconds)) {
          ForEach([30.0, 60, 120, 300], id: \.self) { Text("\($0.formatted())秒ごと").tag($0) }
        }
        Picker("前と重ねる長さ", selection: capture(\.overlapSeconds)) {
          ForEach([0.0, 5, 10, 20], id: \.self) { Text("\(Int($0))秒").tag($0) }
        }
        Text("文字は \(Paths.transcripts.path)/<録音>/0001.txt に置く。区切った音声は文字にしたら消える")
          .font(.caption).foregroundStyle(.secondary)
      } header: {
        Text("リアルタイムの文字起こし(whisper.cpp)")
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

  private var transcribe: Binding<Bool> {
    Binding(
      get: { settings.settings.transcribe },
      set: { value in settings.update { $0.transcribe = value } }
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

private struct QuietTab: View {
  @Environment(SettingsStore.self) private var settings
  @Environment(CaptureStore.self) private var capture

  var body: some View {
    Form {
      Section {
        if case .quiet = capture.state.phase {
          Text(capture.state.statusText(endSilence: settings.settings.capture.endSilenceSeconds))
        }
        Button("時間帯を足す") { add() }
      } header: {
        Text("この時間は録らない")
      } footer: {
        Text("この間はマイクを閉じる。録音中なら、そこまでを書き出してコマンドに渡す。終わりが始まりより前なら、次の日のその時刻まで続く")
      }
      ForEach(settings.settings.quiet.rules) { rule in
        Section {
          QuietRuleRows(rule: binding(for: rule.id)) { remove(rule.id) }
        } header: {
          Text(rule.summary)
        }
      }
    }
    .formStyle(.grouped)
  }

  private func add() {
    settings.update {
      $0.quiet.rules.append(
        QuietRule(weekdays: Set(1...7), startMinute: 20 * 60, endMinute: 8 * 60))
    }
  }

  private func remove(_ id: UUID) {
    settings.update { $0.quiet.rules.removeAll { $0.id == id } }
  }

  private func binding(for id: UUID) -> Binding<QuietRule> {
    Binding(
      get: {
        settings.settings.quiet.rules.first { $0.id == id }
          ?? QuietRule(id: id, weekdays: [], startMinute: 0, endMinute: 0)
      },
      set: { value in
        settings.update { next in
          guard let index = next.quiet.rules.firstIndex(where: { $0.id == id }) else { return }
          next.quiet.rules[index] = value
        }
      }
    )
  }
}

private struct QuietRuleRows: View {
  @Binding var rule: QuietRule
  let onRemove: () -> Void

  var body: some View {
    HStack(spacing: 4) {
      ForEach(TimeText.weekdayOrder, id: \.self) { weekday in
        Toggle(TimeText.weekdayName(weekday), isOn: day(weekday))
          .toggleStyle(.button)
      }
      Spacer()
      Button(role: .destructive, action: onRemove) {
        Image(systemName: "trash")
      }
      .buttonStyle(.borderless)
      .help("この時間帯を消す")
    }
    DatePicker("始まり", selection: time(\.startMinute), displayedComponents: .hourAndMinute)
    DatePicker("終わり", selection: time(\.endMinute), displayedComponents: .hourAndMinute)
  }

  private func day(_ weekday: Int) -> Binding<Bool> {
    Binding(
      get: { rule.weekdays.contains(weekday) },
      set: { on in
        if on { rule.weekdays.insert(weekday) } else { rule.weekdays.remove(weekday) }
      }
    )
  }

  // DatePicker は Date しか扱えない。今日のその時刻に置き換えて渡し、時と分だけ戻す
  private func time(_ keyPath: WritableKeyPath<QuietRule, Int>) -> Binding<Date> {
    Binding(
      get: {
        let minute = rule[keyPath: keyPath]
        return Calendar.current.date(
          bySettingHour: minute / 60, minute: minute % 60, second: 0, of: Date()) ?? Date()
      },
      set: { date in
        let components = Calendar.current.dateComponents([.hour, .minute], from: date)
        rule[keyPath: keyPath] = (components.hour ?? 0) * 60 + (components.minute ?? 0)
      }
    )
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
        LabeledContent("文字", value: Paths.transcripts.path)
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
