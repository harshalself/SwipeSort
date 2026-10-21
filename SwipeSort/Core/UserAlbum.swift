import Foundation

/// A user-created album surfaced from PhotoKit. Smart albums (Screenshots,
/// Favorites, Recently Deleted, etc.) are read-only and are surfaced with
/// `canAdd == false` so callers can filter them out of the picker.
///
/// `id` maps to `PHAssetCollection.localIdentifier`.
struct UserAlbum: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    var assetCount: Int
    let canAdd: Bool
}
