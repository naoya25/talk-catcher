import Foundation

public enum AudioLevel {
  public static let floor: Float = -100

  public static func dbfs(_ samples: [Float]) -> Float {
    guard !samples.isEmpty else { return floor }
    let meanSquare = samples.reduce(0) { $0 + $1 * $1 } / Float(samples.count)
    guard meanSquare > 0 else { return floor }
    return max(floor, 10 * log10(meanSquare))
  }
}
