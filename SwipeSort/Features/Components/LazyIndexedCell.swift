import SwiftUI

// MARK: - LazyIndexedCell

/// A grid cell slot that lazily resolves its `AssetIdentifier` from the
/// `PHFetchResult` using O(1) array access.
///
/// Previously, `PhotoGridView` fetched *all* identifiers upfront via
/// `library.identifiers(in: 0..<totalCount)`, which called
/// `PHFetchResult.objects(at: IndexSet)` over the entire library — materializing
/// every asset identifier into memory before any cell appeared on screen.
/// For large libraries (50–100 K photos) this was a 100–500 ms O(n) allocation.
///
/// Apple's `PHFetchResult` documentation states:
/// > "Unlike an NSArray object, a PHFetchResult object dynamically loads its
/// > contents from the Photos library as needed."
///
/// By having each grid slot resolve its own identifier in `.task(id:)` as it
/// scrolls into the `LazyVGrid`, we fully leverage that lazy-load guarantee.
/// Only the identifier for each *visible* cell is ever fetched.
///
/// Selection state: the resolved identifier is reported back to `PhotoGridView`
/// via `onIdResolved`, populating a shared `[Int: AssetIdentifier]` dictionary
/// that drag-range selection reads synchronously (visible cells are always
/// pre-populated by the time a drag can reach them).
///
/// Threading: `@MainActor`-isolated, matching `PhotoLibraryProviding`.
@MainActor
struct LazyIndexedCell: View {
    let index: Int
    let generation: Int
    let totalCount: Int
    let library: PhotoLibraryProviding
    let imageCache: GridImageCache
    let targetSize: CGSize
    let isSelecting: Bool
    let selectedIds: Set<AssetIdentifier>
    let onIdResolved: (Int, AssetIdentifier) -> Void
    let onScrollAppear: (Int, Int) -> Void
    let onScrollDisappear: (Int, Int) -> Void
    let onTap: (AssetIdentifier) -> Void
    let onContextMove: ((AssetIdentifier) -> Void)?

    @State private var id: AssetIdentifier?

    var body: some View {
        Group {
            if let id {
                ThumbnailCell(
                    id: id,
                    generation: generation,
                    library: library,
                    cache: imageCache,
                    targetSize: targetSize,
                    isSelected: isSelecting ? selectedIds.contains(id) : nil,
                    accessibilityIndex: index,
                    onContextMove: onContextMove
                )
                .onTapGesture { onTap(id) }
            } else {
                // Placeholder shown while the identifier is resolving (O(1), typically <1ms).
                Color(.secondarySystemBackground)
                    .aspectRatio(1, contentMode: .fill)
            }
        }
        .clipped()
        .contentShape(Rectangle())
        .onAppear { onScrollAppear(index, totalCount) }
        .onDisappear { onScrollDisappear(index, totalCount) }
        // Task key encodes both `generation` and `index`. A generation bump (library
        // change) re-resolves every visible cell's identifier without fetching
        // identifiers for cells that are off-screen.
        .task(id: "\(generation)-\(index)") {
            id = nil // Reset so stale identifiers are never shown after a generation bump.
            if let resolved = await library.assetIdentifier(at: index) {
                id = resolved
                onIdResolved(index, resolved)
            }
        }
    }
}
