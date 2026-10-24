import Foundation
import CoreGraphics

enum RuntimeCompatibility {
    #if LOCALLINK_LEGACY
    static let legacyAPIs = true
    #else
    static let legacyAPIs = false
    #endif
}

enum PicturePreset: String, CaseIterable {
    case retina = "Retina", sharp = "Studio", smooth = "Balanced", travel = "Travel"
    var subtitle: String {
        switch self {
        case .retina: return "Up to 4K · 70 Mbps · crisp text and detail"
        case .sharp: return "Up to 5K · 120 Mbps · maximum detail"
        case .smooth: return "Up to 2560 × 1600 · 35 Mbps · everyday use"
        case .travel: return "Up to 1080p · 12 Mbps · lighter connections"
        }
    }
    var symbol: String { switch self { case .retina: return "display"; case .sharp: return "sparkles"; case .smooth: return "water.waves"; case .travel: return "airplane" } }
    func request(hevc: Bool, audio: Bool) -> StreamRequest {
        switch self {
        case .retina: return StreamRequest(width: 3840, height: 2160, fps: 60, mbps: 70, hevc: hevc, audio: audio)
        case .sharp: return StreamRequest(width: 5120, height: 3200, fps: 60, mbps: 120, hevc: hevc, audio: audio)
        case .smooth: return StreamRequest(width: 2560, height: 1600, fps: 60, mbps: 35, hevc: hevc, audio: audio)
        case .travel: return StreamRequest(width: 1920, height: 1080, fps: 60, mbps: 12, hevc: hevc, audio: audio)
        }
    }
}

enum DesktopScale: String, CaseIterable { case fit = "Fit", fill = "Fill", actual = "Actual pixels" }

enum DisplayGeometry {
    static func capture(source: CGSize, maximum: CGSize) -> CGSize {
        guard source.width > 0, source.height > 0, maximum.width >= 16, maximum.height >= 16 else { return .zero }
        let factor = min(1, maximum.width / source.width, maximum.height / source.height)
        return CGSize(width: max(16, floor(source.width * factor / 2) * 2), height: max(16, floor(source.height * factor / 2) * 2))
    }
    static func viewport(source: CGSize, bounds: CGRect, scale: DesktopScale, backing: CGFloat) -> CGRect {
        guard source.width > 0, source.height > 0, bounds.width > 0, bounds.height > 0 else { return .zero }
        let factor: CGFloat
        switch scale {
        case .fit: factor = min(bounds.width / source.width, bounds.height / source.height)
        case .fill: factor = max(bounds.width / source.width, bounds.height / source.height)
        case .actual: factor = 1 / max(1, backing)
        }
        let size = CGSize(width: source.width * factor, height: source.height * factor)
        return CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2, width: size.width, height: size.height)
    }
}

/// Monotonic heartbeats determine health; unchanged desktop frames never expire a session.
struct SessionHealth {
    static let heartbeatInterval: TimeInterval = 3
    static let timeout: TimeInterval = 18
    static func timedOut(now: TimeInterval, lastResponse: TimeInterval) -> Bool { now - lastResponse > timeout }
    static func retryDelay(attempt: Int) -> TimeInterval { min(15, pow(2, Double(max(0, min(attempt - 1, 4))))) }
}
