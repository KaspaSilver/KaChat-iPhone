import SwiftUI

/// Diagonal shimmer swept across a fee bubble while a fee estimate is loading - shared by the 1:1
/// and group compose bars so both fee bubbles look and animate identically.
///
/// Driven by a clock, not by `withAnimation(.repeatForever)` on a parent's state. A repeating
/// animation started from the chat screen's own state runs that whole screen's update inside the
/// repeating transaction, so the message list picked it up and slid up and down on a loop.
struct FeeShimmerOverlay: View {
    private static let sweepSeconds: TimeInterval = 1.2

    var body: some View {
        TimelineView(.animation) { context in
            let elapsed = context.date.timeIntervalSinceReferenceDate
                .truncatingRemainder(dividingBy: Self.sweepSeconds)
            let phase = CGFloat(elapsed / Self.sweepSeconds) * 2 - 1
            GeometryReader { geo in
                Rectangle()
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.0),
                                Color.white.opacity(0.22),
                                Color.white.opacity(0.0)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .rotationEffect(.degrees(20))
                    .offset(x: phase * geo.size.width * 1.5)
            }
        }
    }
}
