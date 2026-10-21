import SwiftUI

/// The Albums tab: a list of every user-created album in the Photos library.
///
/// Tapping an album opens `AlbumGridView`, which scopes the swipe session to
/// that album's assets. Albums hidden via `AppSettings.hiddenAlbumIds` are
/// filtered out from the visible list.
struct AlbumsView: View {
    let library: PhotoLibraryProviding

    @Environment(AppSettings.self) private var settings
    @State private var albums: [UserAlbum] = []
    @State private var isLoading = true
    @State private var showingAlbumFilter = false
    @State private var authStatus: PhotoLibraryAuthorization = .notDetermined

    private var visibleAlbums: [UserAlbum] {
        albums.filter { !settings.hiddenAlbumIds.contains($0.id) }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if authStatus == .limited {
                    LimitedAccessBanner()
                        .padding(.top, 8)
                }
                Group {
                if isLoading {
                    VStack(spacing: 16) {
                        Spacer()
                        ProgressView("Loading albums…")
                        Spacer()
                    }
                } else if albums.isEmpty {
                    VStack(spacing: 16) {
                        Spacer()
                        Image(systemName: "photo.stack")
                            .font(.system(size: 52))
                            .foregroundStyle(.secondary)
                        Text("No albums found.")
                            .font(.headline)
                        Text("Create albums in your Photos app and they'll appear here.")
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 32)
                        Spacer()
                    }
                } else if visibleAlbums.isEmpty {
                    VStack(spacing: 16) {
                        Spacer()
                        Image(systemName: "eye.slash")
                            .font(.system(size: 52))
                            .foregroundStyle(.secondary)
                        Text("All albums are hidden")
                            .font(.headline)
                        Text("Use the filter button at the top right to turn albums back on.")
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 32)
                        Button("Show All Albums") {
                            settings.hiddenAlbumIds.removeAll()
                        }
                        .buttonStyle(.borderedProminent)
                        Spacer()
                    }
                } else {
                    List(visibleAlbums) { album in
                        NavigationLink {
                            AlbumGridView(album: album, library: library)
                        } label: {
                            HStack {
                                Image(systemName: "photo.stack.fill")
                                    .foregroundStyle(.tint)
                                    .frame(width: 32)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(album.title)
                                        .font(.body)
                                        .foregroundStyle(.primary)
                                    Text("\(album.assetCount) item\(album.assetCount == 1 ? "" : "s")")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    }
                }
            }
            .navigationTitle("Albums")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingAlbumFilter = true
                    } label: {
                        Image(systemName: "line.3.horizontal.decrease.circle")
                    }
                    .disabled(albums.isEmpty)
                }
            }
            .sheet(isPresented: $showingAlbumFilter) {
                AlbumFilterSheet(albums: albums)
                    .presentationDetents([.medium, .large])
            }
            .refreshable { await loadAlbums() }
            .task { await loadAlbums() }
            // Precise: fires only when the album list itself moved (add /
            // remove / rename / reorder). Asset-only edits never wake this.
            .onReceive(NotificationCenter.default.publisher(for: PhotoLibraryChangePublisher.albumsDidChangeNotification)) { _ in
                Task { await loadAlbums() }
            }
        }
    }

    private func loadAlbums() async {
        if albums.isEmpty {
            isLoading = true
        }
        var currentAuth = await library.currentAuthorization()
        if currentAuth == .notDetermined {
            currentAuth = await library.requestAuthorization()
        }
        authStatus = currentAuth
        // Wire up change notifications for users who browse only the album list
        // and never open a swipe session. No-op if already registered.
        PhotoLibraryChangePublisher.shared.registerIfAuthorized()
        albums = await library.userAlbums()
        isLoading = false
    }
}

// MARK: - Album Grid View

/// A lazy 3-column grid of photos inside a specific album.
///
/// Mirrors the `RecentsView` grid experience. Tapping a cell opens the swipe
/// deck scoped to this album. Grid rendering is delegated to `PhotoGridView`.
/// Supports multi-select and bulk album-move.
struct AlbumGridView: View {
    let album: UserAlbum
    let library: PhotoLibraryProviding

    @Environment(AppSettings.self) private var settings

    @State private var loadCount = LoadCountController()
    @State private var filter: SwipeFilter = .unfiltered
    @State private var showingFilter = false
    @State private var swipeContext: SwipePresentationContext?
    @State private var imageCache = GridImageCache()
    @State private var scopedLibrary: PhotoLibraryProviding?
    @State private var isSelecting = false
    @State private var selectedIds: Set<AssetIdentifier> = []
    @State private var showingAlbumPicker = false
    @State private var showingBulkDeleteConfirm = false
    @State private var pendingDeleteIds: [AssetIdentifier] = []

    var body: some View {
        ZStack {
            PhotoGridView(
                library: scopedLibrary ?? library,
                totalCount: loadCount.totalCount,
                generation: loadCount.generation,
                imageCache: imageCache,
                isSelecting: $isSelecting,
                selectedIds: $selectedIds,
                onTapAsset: { index, id in
                    swipeContext = SwipePresentationContext(initialIndex: index, initialAssetId: id)
                },
                onRequestMove: { _ in
                    showingAlbumPicker = true
                },
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
                        await refreshScopedCount()
                    }
                },
                onContextMove: { id in
                    selectedIds = [id]
                    showingAlbumPicker = true
                }
            )
            .opacity(loadCount.hasIndexed && loadCount.totalCount > 0 ? 1 : 0)

            if !loadCount.hasIndexed {
                VStack {
                    Spacer()
                    ProgressView("Loading photos…").padding()
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
                    Text("Try adjusting the filter or add photos to this album.")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 32)
                    Spacer()
                }
            }
        }
        .navigationTitle(isSelecting ? "\(selectedIds.count) Selected" : album.title)
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
                }
            }
        }
        .fullScreenCover(item: $swipeContext, onDismiss: {
            Task { await refreshScopedCount() }
        }) { context in
            SwipeStackView(
                library: scopedLibrary ?? library,
                filter: filter,
                albumTitle: album.title,
                sourceAlbumId: album.id,
                initialIndex: context.initialIndex,
                initialAssetId: context.initialAssetId
            )
        }
        .sheet(isPresented: $showingFilter, onDismiss: {
            Task { await refreshScopedCount() }
        }) {
            FilterSheet(filter: $filter, onFilterChange: {
                Task { await refreshScopedCount() }
            })
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showingAlbumPicker) {
            AlbumPickerSheet(
                library: library,
                selectedCount: selectedIds.count,
                sourceAlbumId: album.id
            ) { targetAlbum in
                let ids = Array(selectedIds)
                _ = await library.moveAssets(ids, fromAlbumId: album.id, toAlbumId: targetAlbum.id)
                if settings.hapticsEnabled {
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                }
                isSelecting = false
                selectedIds.removeAll()
                await refreshScopedCount()
            }
        }

        .task(id: album.id) {
            scopedLibrary = library.scoped(toAlbumId: album.id)
            await refreshScopedCount()
        }
        .onPhotoLibraryChangeDebounced {
            loadCount.bumpGeneration()
            await refreshScopedCount()
        }
    }

    private func refreshScopedCount() async {
        let s = scopedLibrary ?? library
        await loadCount.refresh(from: s, filter: filter)
    }

    private func bulkFavorite(_ ids: [AssetIdentifier]) async {
        let lib = scopedLibrary ?? library
        _ = await lib.toggleFavoritesConsistently(ids)
        if settings.hapticsEnabled {
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        }
        isSelecting = false
        selectedIds.removeAll()
        loadCount.bumpGeneration()
        await refreshScopedCount()
    }
}
