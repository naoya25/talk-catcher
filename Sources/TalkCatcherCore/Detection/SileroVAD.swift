import Foundation
import OnnxRuntimeBindings

public protocol VoiceDetector: AnyObject {
  func probability(of chunk: [Float]) throws -> Float
  func reset()
}

public enum VoiceDetectorError: Error {
  case wrongChunkSize(Int)
  case missingOutput
}

public final class SileroVAD: VoiceDetector {
  private static let contextSize = 64
  private static let stateSize = 2 * 1 * 128

  private let env: ORTEnv
  private let session: ORTSession
  private var state = [Float](repeating: 0, count: stateSize)
  private var context = [Float](repeating: 0, count: contextSize)

  public init(modelURL: URL) throws {
    env = try ORTEnv(loggingLevel: .warning)
    let options = try ORTSessionOptions()
    try options.setIntraOpNumThreads(1)
    session = try ORTSession(env: env, modelPath: modelURL.path, sessionOptions: options)
  }

  public func probability(of chunk: [Float]) throws -> Float {
    guard chunk.count == AudioFormat.chunkSize else {
      throw VoiceDetectorError.wrongChunkSize(chunk.count)
    }
    // 公式の OnnxWrapper と同じく、前の chunk の末尾 64 サンプルを頭に付けて渡す
    let input = context + chunk
    var sampleRate = Int64(AudioFormat.sampleRate)
    let outputs = try session.run(
      withInputs: [
        "input": try Self.floatTensor(input, shape: [1, input.count]),
        "state": try Self.floatTensor(state, shape: [2, 1, 128]),
        "sr": try ORTValue(
          tensorData: NSMutableData(bytes: &sampleRate, length: MemoryLayout<Int64>.size),
          elementType: .int64,
          shape: []
        ),
      ],
      outputNames: ["output", "stateN"],
      runOptions: nil
    )
    guard let output = outputs["output"], let nextState = outputs["stateN"] else {
      throw VoiceDetectorError.missingOutput
    }
    state = try Self.floats(nextState)
    context = Array(input.suffix(Self.contextSize))
    return try Self.floats(output).first ?? 0
  }

  public func reset() {
    state = [Float](repeating: 0, count: Self.stateSize)
    context = [Float](repeating: 0, count: Self.contextSize)
  }

  private static func floatTensor(_ values: [Float], shape: [Int]) throws -> ORTValue {
    let data = values.withUnsafeBufferPointer {
      NSMutableData(bytes: $0.baseAddress, length: $0.count * MemoryLayout<Float>.size)
    }
    return try ORTValue(
      tensorData: data, elementType: .float, shape: shape.map { NSNumber(value: $0) })
  }

  private static func floats(_ value: ORTValue) throws -> [Float] {
    let data = try value.tensorData() as Data
    return data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
  }
}
