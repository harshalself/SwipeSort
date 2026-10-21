import SwiftUI

/// A reusable 3-column photo grid with zero-lag ProMotion 120 FPS scrolling.
///
/// The grid is index-driven: `LazyVGrid` iterates `0..<totalCount` and each
/// `LazyIndexedCell` resolves its own `AssetIdentifier` on appear via one
/// O(1) `PHFetchResult` lookup. No upfront identifier batch-fetch occurs — the
/// `PHFetchResult` lazy-loading guarantee is fully leveraged.
///
/// Visible index tracking (`GridScrollTracker`) drives `WindowedThumbnailCache`,
/// which pre-heats `PHCachingImageManager` for upcoming swipe cards.
struct PhotoGridView: View {
    @Environment(AppSettings.self) private var settings
    let library: PhotoLibraryProviding
    let totalCount: Int
    let generation: Int
    let imageCache: GridImageCache
    @Binding var isSelecting: Bool
    @Binding var selectedIds: Set<AssetIdentifier>
    let onTapAsset: (Int, AssetIdentifier) -> Void
    /// Called when the user taps "Move" in the selection toolbar. The parent
    /// view is responsible for presenting `AlbumPickerSheet` with these IDs.
    let onRequestMove: (([AssetIdentifier]) -> Void)?
    /// Called when the user taps the batch Favorite button in the selection
    /// toolbar. The parent decides the target state (favourite if any are not
    /// yet favourited, unfavourite otherwise) and issues the library call.
    let onRequestFavorite: ([AssetIdentifier]) -> Void
    /// Called when the user taps the batch Delete button in the selection
    /// toolbar. The parent shows a confirmation and then issues the library
    /// call — iOS's own system prompt still appears once at commit time.
    let onRequestDelete: ([AssetIdentifier]) -> Void
    /// Called when the user picks "Move to Album…" from a cell's context menu.
    /// The single-item move flow reuses `AlbumPickerSheet` with a one-element
    /// selection; the parent sets its selection state and presents the sheet.
    let onContextMove: ((AssetIdentifier) -> Void)?

    /// Lazily-populated map from grid index → resolved `AssetIdentifier`.
    /// Each `LazyIndexedCell` writes to this on appear.
    @State private var resolvedIds: [Int: AssetIdentifier] = [:]
    @State private var thumbnailCache: WindowedThumbnailCache?
    @State private var scrollTracker: GridScrollTracker?
    /// Width of the grid container, captured once for arithmetic cell size computation.
    @State private var gridWidth: CGFloat = 0

    private static let columnCount = 3
    private static let spacing: CGFloat = 2

    private let columns = Array(
        repeating: GridItem(.flexible(), spacing: PhotoGridView.spacing),
        count: PhotoGridView.columnCount
    )

    /// Computed so `UITraitCollection.current.displayScale` is read from `body`
    /// where environment values are available, rather than inside a `Task`.
    private var thumbnailPixelSize: CGSize {
        let displayScale = UITraitCollection.current.displayScale
        let points = cellSize
        return CGSize(width: points * displayScale, height: points * displayScale)
    }

    /// Computes the cell size from the current grid width.
    private var cellSize: CGFloat {
        guard gridWidth > 0 else { return 115 }
        let cols = CGFloat(Self.columnCount)
        return (gridWidth - (cols - 1) * Self.spacing) / cols
    }

    @State private var selectionFeedback = UISelectionFeedbackGenerator()

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: Self.spacing) {
                 ForEach(0..<totalCount, id: \.self) { index in
                    gridCell(at: index)
                        .id(index)
                 }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if isSelecting {
                GridSelectionBottomBar(
                    selectedIds: $selectedIds,
                    onFavoriteTapped: { onRequestFavorite(Array(selectedIds)) },
                    onDeleteTapped: { onRequestDelete(Array(selectedIds)) },
                    onMoveTapped: onRequestMove != nil ? { onRequestMove?(Array(selectedIds)) } : nil
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .background {
            GeometryReader { geo in
                Color.clear.onAppear {
                    gridWidth = geo.size.width
                }
                .onChange(of: geo.size.width) { _, newWidth in
                    gridWidth = newWidth
                }
            }
        }
        .task(id: "\(generation)-\(totalCount)") {
            // Reset resolved IDs so each cell re-resolves its identifier after a
            // library change. Off-screen cells do not re-resolve until they appear.
            resolvedIds = [:]
            if thumbnailCache == nil {
                let cache = WindowedThumbnailCache(
                    library: library,
                    targetSize: thumbnailPixelSize
                )
                thumbnailCache = cache
                scrollTracker = GridScrollTracker(cache: cache)
            }
        }
        .onDisappear {
            thumbnailCache?.stopAll()
        }
    }

    // MARK: - Grid Cell

    @ViewBuilder
    private func gridCell(at index: Int) -> some View {
        LazyIndexedCell(
            index: index,
            generation: generation,
            totalCount: totalCount,
            library: library,
            imageCache: imageCache,
            targetSize: thumbnailPixelSize,
            isSelecting: isSelecting,
            selectedIds: selectedIds,
            onIdResolved: { idx, id in resolvedIds[idx] = id },
            onScrollAppear: { scrollTracker?.onAppear(index: $0, total: $1) },
            onScrollDisappear: { scrollTracker?.onDisappear(index: $0, total: $1) },
            onTap: { id in
                if isSelecting {
                    if settings.hapticsEnabled {
                        selectionFeedback.selectionChanged()
                    }
                    applySelection(!selectedIds.contains(id), to: id)
                } else {
                    onTapAsset(index, id)
                }
            },
            onContextMove: onContextMove
        )
        .accessibilityIdentifier("ThumbnailCell-\(index)")
    }

    // MARK: - Selection

    private func applySelection(_ shouldSelect: Bool, to id: AssetIdentifier) {
        if shouldSelect { selectedIds.insert(id) } else { selectedIds.remove(id) }
    }
}

/// The bottom toolbar shown while multi-select is active in a grid view.
///
/// Provides batch Favorite / Delete icon actions and a "Move (n)" primary
/// action. In the index-driven grid, actions operate on `selectedIds` — the
/// set of identifiers explicitly tapped or drag-selected by the user.
struct GridSelectionBottomBar: View {
    @Binding var selectedIds: Set<AssetIdentifier>
    let onFavoriteTapped: () -> Void
    let onDeleteTapped: () -> Void
    let onMoveTapped: (() -> Void)?

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onFavoriteTapped) {
                Image(systemName: "heart")
                    .font(.title3)
            }
            .disabled(selectedIds.isEmpty)
            .accessibilityLabel("Favorite \(selectedIds.count) selected")

            Button(role: .destructive, action: onDeleteTapped) {
                Image(systemName: "trash")
                    .font(.title3)
            }
            .disabled(selectedIds.isEmpty)
            .accessibilityLabel("Delete \(selectedIds.count) selected")

            Spacer()

            if let onMoveTapped {
                Button(action: onMoveTapped) {
                    Label("Move (\(selectedIds.count))", systemImage: "folder.fill.badge.plus")
                        .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.borderedProminent)
                .disabled(selectedIds.isEmpty)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.bar)
    }
}


