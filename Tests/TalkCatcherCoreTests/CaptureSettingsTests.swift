import Foundation
import Testing

@testable import TalkCatcherCore

@Test("前の版で保存した設定は、足した項目を既定値にして読める")
func decodesOldSettings() throws {
  let json =
    #"{"speechProbability":0.5,"minDBFS":-45,"prerollSeconds":3,"endSilenceSeconds":300,"tailSeconds":5,"maxLengthSeconds":3600}"#
  let settings = try JSONDecoder().decode(CaptureSettings.self, from: Data(json.utf8))
  #expect(settings.minDBFS == -45)
  #expect(settings.startSpeechSeconds == 1)
}
