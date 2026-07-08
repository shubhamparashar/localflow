import Foundation

/// Pure numeric helper for mapping a mic input sample (dBFS) to a waveform bar
/// height. Extracted from `OverlayHUD` so the curve is unit-testable without
/// AppKit.
enum WaveformMapping {
    /// Maps `dbfs` into `minHeight...maxHeight`, clamping to `minDBFS...maxDBFS`
    /// first. Uses a square-root curve so quiet speech still produces visible
    /// bar movement instead of only saturating near the loud end of the range.
    static func barHeight(
        dbfs: Float,
        minDBFS: Float,
        maxDBFS: Float,
        minHeight: CGFloat,
        maxHeight: CGFloat
    ) -> CGFloat {
        guard maxDBFS > minDBFS else { return minHeight }
        let clamped: Float = min(max(dbfs, minDBFS), maxDBFS)
        let fraction: Float = sqrt((clamped - minDBFS) / (maxDBFS - minDBFS))
        return minHeight + CGFloat(fraction) * (maxHeight - minHeight)
    }
}
