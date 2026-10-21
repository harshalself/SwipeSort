import SwiftUI

// MARK: - RecentsView

/// The Recents tab: a lazy 3-column grid of the most recently taken photos.
///
/// Tapping a cell opens the swipe deck starting at that cell's position.
/// Supports multi-select with drag-range selection (delegated to `PhotoGridView`)
/// and bulk album-move.
///
/// The grid is index-driven: `LoadCountController` reads `assetCount()` in
/// O(1) and every cell resolves its own identifier on appear. No eager
/// identifiers-in-range fetch happens, so libraries of any size render
/// without truncation.
struct RecentsView: View {
    let library: PhotoLibraryProviding
    @Environment(AppSettings.self) private var settings
    @State private var loadCount = LoadCountController()
    @State private var filter: SwipeFilter = .unfiltered
    @State private var showingFilter = false
    @State private var swipeContext: SwipePresentationContext?
    @State private var isSelecting = false
    @State private var selectedIds: Set<AssetIdentifier> = []
    @State private var showingAlbumPicker = false
    @State private var showingBulkDeleteConfirm = false
    @State private var pendingDeleteIds: [AssetIdentifier] = []

    /// Image cache shared by all cells in this grid. Survives `LazyVGrid`
    /// cell recycling so images are restored instantly on scroll-back.
    @State private var imageCache = GridImageCache()

    var body: some View {
        NavigationStack {
            ZStack {
                PhotoGridView(
                    library: library,
                    totalCount: loadCount.totalCount,
                    generation: loadCount.generation,
                    imageCache: imageCache,
                    isSelecting: $isSelecting,
                    selectedIds: $selectedIds,
                    onTapAsset: { index, id in
                        swipeContext = SwipePresentationContext(initialIndex: index, initialAssetId: id)
                    },
                    onRequestMove: nil,
                    onRequestFavorite: { ids in
                        Task { await bulkFavorite(ids) }
                    },
                    onRequestDelete: { ids in
                        if settings.hapticsEnabled {
                            UINotificationFeedbackGenerator().notificationOccurred(.warning)
                        }
                        Task {
                            _ = await library.commitDeletions(ids)
                            isSelecting = false
                            selectedIds.removeAll()
                            await loadCount.refresh(from: library, filter: filter)
                        }
                    },
                    onContextMove: nil
                )
                .safeAreaInset(edge: .top, spacing: 0) {
                    if loadCount.authStatus == .limited {
                        LimitedAccessBanner()
                            .padding(.top, 8)
                    }
                }
                .opacity(loadCount.hasIndexed && loadCount.totalCount > 0 ? 1 : 0)

                if !loadCount.hasIndexed {
                    VStack {
                        Spacer()
                        ProgressView("Indexing library…").padding()
                        Spacer()
                    }
                } else if loadCount.totalCount == 0 {
                    VStack(spacing: 16) {
                        Spacer()
                        Image(systemName: "photo.on.rectangle.angled")
                            .font(.system(size: 52))
                            .foregroundStyle(.secondary)
                        Text("No photos found.")
                            .font(.headline)
                        Text("Try adjusting the filter, or grant library access first.")
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 32)
                        Spacer()
                    }
                    .accessibilityIdentifier("EmptyStateView")
                }
            }
            .navigationTitle(isSelecting ? "\(selectedIds.count) Selected" : "Recents")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 16) {
                        if loadCount.totalCount > 0 {
                            Button(isSelecting ? "Cancel" : "Select") {
                                isSelecting.toggle()
                                if !isSelecting {
                                    selectedIds.removeAll()
                                }
                            }
                        }
                        Button {
                            showingFilter = true
                        } label: {
                            Image(systemName: "line.3.horizontal.decrease.circle")
                        }
                        .accessibilityIdentifier("FilterButton")
                    }
                }
            }
            // Tapping any photo launches the full swipe-sort deck
            .fullScreenCover(item: $swipeContext, onDismiss: {
                Task { await loadCount.refresh(from: library, filter: filter) }
            }) { context in
                SwipeStackView(library: library, filter: filter, initialIndex: context.initialIndex, initialAssetId: context.initialAssetId)
            }
            .sheet(isPresented: $showingFilter, onDismiss: {
                Task { await loadCount.refresh(from: library, filter: filter) }
            }) {
                FilterSheet(filter: $filter, onFilterChange: {
                    Task { await loadCount.refresh(from: library, filter: filter) }
                })
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
            }
            .sheet(isPresented: $showingAlbumPicker) {
                AlbumPickerSheet(
                    library: library,
                    selectedCount: selectedIds.count,
                    sourceAlbumId: nil
                ) { targetAlbum in
                    let ids = Array(selectedIds)
                    _ = await library.moveAssets(ids, fromAlbumId: nil, toAlbumId: targetAlbum.id)
                    if settings.hapticsEnabled {
                        UINotificationFeedbackGenerator().notificationOccurred(.success)
                    }
                    isSelecting = false
                    selectedIds.removeAll()
                    await loadCount.refresh(from: library, filter: filter)
                }
            }

            .task { await loadCount.refresh(from: library, filter: filter) }
            .onPhotoLibraryChangeDebounced {
                loadCount.bumpGeneration()
                await loadCount.refresh(from: library, filter: filter)
            }
        }
    }

    private func bulkFavorite(_ ids: [AssetIdentifier]) async {
        _ = await library.toggleFavoritesConsistently(ids)
        if settings.hapticsEnabled {
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        }
        isSelecting = false
        selectedIds.removeAll()
        loadCount.bumpGeneration()
        await loadCount.refresh(from: library, filter: filter)
    }
}
