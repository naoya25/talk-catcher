import AVFoundation
import TalkCatcherCore
import os

enum MicrophoneError: Error {
  case unsupportedFormat
}

@MainActor
final class MicrophoneInput {
  // 入力を切り替えるときに前の接続を引きずらないよう、聞き始めるたびに作り直す
  private var engine: AVAudioEngine?
  private var continuation: AsyncStream<[Float]>.Continuation?
  private var configurationObserver: NSObjectProtocol?

  static func requestAccess() async -> Bool {
    switch AVCaptureDevice.authorizationStatus(for: .audio) {
    case .authorized: true
    case .notDetermined: await AVCaptureDevice.requestAccess(for: .audio)
    default: false
    }
  }

  func start(device: InputDevice?, onConfigurationChange: @escaping @MainActor () -> Void) throws
    -> AsyncStream<[Float]>
  {
    stop()
    let engine = AVAudioEngine()
    let input = engine.inputNode
    if let device {
      try input.auAudioUnit.setDeviceID(device.id)
    }
    let format = input.outputFormat(forBus: 0)
    guard
      format.sampleRate > 0,
      let source = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: format.sampleRate, channels: 1,
        interleaved: false),
      let target = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: AudioFormat.sampleRate, channels: 1,
        interleaved: false),
      let converter = AVAudioConverter(from: source, to: target)
    else { throw MicrophoneError.unsupportedFormat }

    let (stream, continuation) = AsyncStream.makeStream(
      of: [Float].self, bufferingPolicy: .bufferingNewest(2_000))
    input.installTap(
      onBus: 0, bufferSize: 4_096, format: format,
      block: Self.makeTap(converter: converter, target: target, continuation: continuation))
    engine.prepare()
    try engine.start()
    configurationObserver = NotificationCenter.default.addObserver(
      forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
    ) { _ in
      MainActor.assumeIsolated { onConfigurationChange() }
    }
    self.engine = engine
    self.continuation = continuation
    return stream
  }

  func stop() {
    if let configurationObserver {
      NotificationCenter.default.removeObserver(configurationObserver)
    }
    configurationObserver = nil
    engine?.inputNode.removeTap(onBus: 0)
    engine?.stop()
    engine = nil
    continuation?.finish()
    continuation = nil
  }

  // main actor の中で作った closure は main actor に縛られ、音声スレッドから呼ばれると落ちるので、外で作る
  private nonisolated static func makeTap(
    converter: AVAudioConverter,
    target: AVAudioFormat,
    continuation: AsyncStream<[Float]>.Continuation
  ) -> AVAudioNodeTapBlock {
    { buffer, _ in
      guard let channel = buffer.floatChannelData else { return }
      // 変換の入力 block は @Sendable なので、AVAudioPCMBuffer ではなく値で渡し、block の中で作り直す
      let samples = Array(UnsafeBufferPointer(start: channel[0], count: Int(buffer.frameLength)))
      let sourceRate = buffer.format.sampleRate
      let capacity = AVAudioFrameCount(Double(samples.count) * target.sampleRate / sourceRate) + 64
      guard let converted = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else {
        return
      }
      let supplied = OSAllocatedUnfairLock(initialState: false)
      var error: NSError?
      converter.convert(to: converted, error: &error) { _, status in
        let alreadySupplied = supplied.withLock { done in
          defer { done = true }
          return done
        }
        guard !alreadySupplied, let input = makeBuffer(samples, sampleRate: sourceRate) else {
          status.pointee = .noDataNow
          return nil
        }
        status.pointee = .haveData
        return input
      }
      guard error == nil, let output = converted.floatChannelData else { return }
      continuation.yield(
        Array(UnsafeBufferPointer(start: output[0], count: Int(converted.frameLength))))
    }
  }

  private nonisolated static func makeBuffer(_ samples: [Float], sampleRate: Double)
    -> AVAudioPCMBuffer?
  {
    guard
      let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false),
      let buffer = AVAudioPCMBuffer(
        pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
      let channel = buffer.floatChannelData
    else { return nil }
    for (offset, sample) in samples.enumerated() { channel[0][offset] = sample }
    buffer.frameLength = AVAudioFrameCount(samples.count)
    return buffer
  }
}
