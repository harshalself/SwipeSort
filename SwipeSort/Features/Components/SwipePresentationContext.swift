import Foundation

/// Carries enough context to re-open the swipe deck at the tapped cell's position.
struct SwipePresentationContext: Identifiable {
    let id = UUID()
    let initialIndex: Int
    let initialAssetId: AssetIdentifier?
}
