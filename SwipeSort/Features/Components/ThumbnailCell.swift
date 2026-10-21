import SwiftUI

// MARK: - Thumbnail Cell

/// A square grid cell with `GridImageCache`-backed image loading, progressive opportunistic delivery,
/// selection checkmark overlay, and context menu.
///
/// Before issuing a PhotoKit request the cell checks `GridImageCache` synchronously. Because the cache
/// is passed in from the parent grid's `@State`, it outlives `LazyVGrid`'s cell recycling — cells that scroll
/// back into view restore instantly without any lag or flicker.
struct ThumbnailCell: View {
    let id: AssetIdentifier
    let generation: Int
    let library: PhotoLibraryProviding
    let cache: GridImageCache
    let targetSize: CGSize
    let isSelected: Bool?
    /// 0-based index in the grid, used only to compose the VoiceOver label
    /// ("Photo 5", "Video 8, 12 seconds"). Not read from `body` — only used
    /// inside `.accessibilityLabel`.
    let accessibilityIndex: Int
    let onContextMove: ((AssetIdentifier) -> Void)?

    init(
        id: AssetIdentifier,
        generation: Int = 0,
        library: PhotoLibraryProviding,
        cache: GridImageCache,
        targetSize: CGSize,
        isSelected: Bool? = nil,
        accessibilityIndex: Int,
        onContextMove: ((AssetIdentifier) -> Void)? = nil
    ) {
        self.id = id
        self.generation = generation
        self.library = library
        self.cache = cache
        self.targetSize = targetSize
        self.isSelected = isSelected
        self.accessibilityIndex = accessibilityIndex
        self.onContextMove = onContextMove
    }

    @State private var image: UIImage?
    @State private var mediaKind: MediaKind = .photo
    @State private var isFavorite: Bool = false

    var body: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)      // anchors the square slot
            .overlay {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    // Static neutral background — avoids the spinning-then-
                    // snapping visual that a ProgressView causes.
                    Color(.secondarySystemBackground)
                }
            }
            .overlay(alignment: .bottomLeading) {
                if isFavorite {
                    Image(systemName: "heart.fill")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.6), radius: 1.5, x: 0, y: 1)
                        .padding(6)
                        .accessibilityIdentifier("FavoriteBadge")
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if case .video(let durationSeconds) = mediaKind {
                    Text(formattedDuration(durationSeconds))
                        .font(.caption2.bold().monospacedDigit())
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.6), radius: 1.5, x: 0, y: 1)
                        .padding(6)
                }
            }
            .overlay(alignment: .topTrailing) {
                if let selected = isSelected {
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(selected ? .blue : .white)
                        .background(selected ? Color.white : Color.black.opacity(0.3), in: Circle())
                        .padding(6)
                }
            }
            .clipped()
            .contentShape(Rectangle())
            .accessibilityElement(children: .ignore)
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(accessibilityLabel)
            .contextMenu {
                contextMenuItems()
            } preview: {
                PhotoPreview(id: id, library: library)
            }
            .task(id: id) {
                // Fast path: one O(1) PHFetchResult access covers mediaKind + isFavorite together,
                // replacing the two separate fetchAssets(withLocalIdentifiers:) calls that were here.
                if let metadata = await library.assetMetadata(at: accessibilityIndex, expectedId: id) {
                    mediaKind = metadata.mediaKind
                    isFavorite = metadata.isFavorite
                    cache.store(metadata.mediaKind, for: id)
                } else if let cachedKind = cache.mediaKind(for: id) {
                    mediaKind = cachedKind
                }

                // Cache hit: skip the PhotoKit image request entirely.
                if let cached = cache.image(for: id) {
                    image = cached
                    return
                }

                // thumbnailStream(for:) resolves the PHAsset synchronously before creating the
                // AsyncStream, so cancellation via onTermination is always race-free.
                for await thumb in library.thumbnailStream(for: id, targetSize: targetSize) {
                    guard !Task.isCancelled else { break }
                    image = thumb.image
                    if !thumb.isDegraded {
                        cache.store(thumb.image, for: id)
                        break
                    }
                }
            }
            .onChange(of: generation) { _, _ in
                Task {
                    if let metadata = await library.assetMetadata(at: accessibilityIndex, expectedId: id) {
                        isFavorite = metadata.isFavorite
                    }
                }
            }
    }

    @ViewBuilder
    private func contextMenuItems() -> some View {
        Button {
            let newValue = !isFavorite
            Task {
                if await library.setFavorite(id, isFavorite: newValue) {
                    isFavorite = newValue
                }
            }
        } label: {
            Label(
                isFavorite ? "Unfavorite" : "Favorite",
                systemImage: isFavorite ? "heart.slash" : "heart"
            )
        }

        if let onContextMove {
            Button {
                onContextMove(id)
            } label: {
                Label("Move to Album…", systemImage: "folder")
            }
        }

        Button(role: .destructive) {
            Task { _ = await library.commitDeletions([id]) }
        } label: {
            Label("Delete", systemImage: "trash")
        }
    }

    private var accessibilityLabel: String {
        let position = accessibilityIndex + 1
        switch mediaKind {
        case .photo:
            return "Photo \(position)"
        case .livePhoto:
            return "Live Photo \(position)"
        case .video(let seconds):
            let s = max(0, Int(seconds.rounded()))
            return "Video \(position), \(s) seconds"
        }
    }

    private func formattedDuration(_ seconds: Double) -> String {
        let totalSeconds = max(0, Int(seconds.rounded()))
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let secs = totalSeconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        } else {
            return String(format: "%d:%02d", minutes, secs)
        }
    }
}
