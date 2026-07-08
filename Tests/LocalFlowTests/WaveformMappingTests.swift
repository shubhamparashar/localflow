import Foundation
import Testing
@testable import LocalFlow

@Suite
final class WaveformMappingTests {

    @Test func floorClampsToMinHeight() {
        let height = WaveformMapping.barHeight(dbfs: -80, minDBFS: -50, maxDBFS: -18, minHeight: 3, maxHeight: 22)
        #expect(height == 3)
    }

    @Test func ceilingClampsToMaxHeight() {
        let height = WaveformMapping.barHeight(dbfs: 0, minDBFS: -50, maxDBFS: -18, minHeight: 3, maxHeight: 22)
        #expect(height == 22)
    }

    @Test func midpointSitsAboveLinearMidpointDueToSqrtCurve() {
        let mid = WaveformMapping.barHeight(dbfs: -34, minDBFS: -50, maxDBFS: -18, minHeight: 3, maxHeight: 22)
        #expect(mid > 3 + (22 - 3) * 0.5)
    }

    @Test func increasesMonotonicallyWithLevel() {
        let low = WaveformMapping.barHeight(dbfs: -45, minDBFS: -50, maxDBFS: -18, minHeight: 3, maxHeight: 22)
        let high = WaveformMapping.barHeight(dbfs: -25, minDBFS: -50, maxDBFS: -18, minHeight: 3, maxHeight: 22)
        #expect(low < high)
    }

    @Test func degenerateRangeReturnsMinHeight() {
        let height = WaveformMapping.barHeight(dbfs: -30, minDBFS: -20, maxDBFS: -20, minHeight: 3, maxHeight: 22)
        #expect(height == 3)
    }
}
