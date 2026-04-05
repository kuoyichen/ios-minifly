import Foundation
import CoreMotion
import Combine

/// Manages accelerometer data for rudder (yaw) control via device tilt.
final class MotionManager: ObservableObject {
    private let motionManager = CMMotionManager()
    private var baseRoll: Double = 0.0
    var isUnlocked: Bool = false

    /// Current rudder value (1000–2000, center = 1500)
    @Published var rudderValue: Int = 1500

    init() {
        startAccelerometer()
    }

    deinit {
        motionManager.stopAccelerometerUpdates()
    }

    private func startAccelerometer() {
        guard motionManager.isAccelerometerAvailable else { return }
        motionManager.accelerometerUpdateInterval = 1.0 / 60.0 // ~game speed

        motionManager.startAccelerometerUpdates(to: .main) { [weak self] data, _ in
            guard let self = self, let data = data else { return }

            let rawX = data.acceleration.x * 9.81
            let clamped = max(-1.0, min(1.0, rawX / 9.81))
            let tiltDeg = asin(clamped) * 180.0 / .pi

            if self.isUnlocked {
                let delta = tiltDeg - self.baseRoll
                // Deadzone: ±5 degrees
                let adjusted: Double
                if abs(delta) < 5.0 {
                    adjusted = 0.0
                } else {
                    adjusted = delta > 0 ? delta - 5.0 : delta + 5.0
                }
                // Map ±35 degrees to ±500
                let mapped = max(-500.0, min(500.0, adjusted / 35.0 * 500.0))
                self.rudderValue = max(1000, min(2000, Int(1500.0 - mapped)))
            } else {
                self.rudderValue = 1500
            }
        }
    }

    func captureBase() {
        if let data = motionManager.accelerometerData {
            let rawX = data.acceleration.x * 9.81
            let clamped = max(-1.0, min(1.0, rawX / 9.81))
            baseRoll = asin(clamped) * 180.0 / .pi
        }
        isUnlocked = true
    }

    func lock() {
        isUnlocked = false
        rudderValue = 1500
    }
}
