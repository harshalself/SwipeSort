import SwiftUI
import UIKit

/// The top-level swipe deck view.
///
/// Owns a `SwipeSessionModel` and maps 4-way drag gestures to
/// keep/delete/next/prev decisions according to the active `GestureMode`.
///
/// Layout (top-to-bottom):
///   - Header: close button · progress counter · pending-deletions badge
///   - Card area: peeking card + front card with drag-hint overlay (≈60% height)
///   - Horizontal album strip — tap to move the current photo immediately
///   - Control bar: Undo button
///
/// Lifecycle: `.task` applies the filter and starts the session. A `WindowedThumbnailCache`
/// slides with `currentIndex` to pre-cache nearby thumbnails. `onDisappear` drains
/// the thumbnail cache and the `VideoPlayerPool`.
struct SwipeStackView: View {

    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var model: SwipeSessionModel
    @State private var dragOffset: CGSize = .zero
    @State private var showingQueue = false
    @State private var commitResult: CommitResult?
    @State private var didAutoPresentQueue = false
    @State private var showingDebugMenu = false

    @State private var albums: [UserAlbum] = []
    @State private var impactGenerator = UIImpactFeedbackGenerator(style: .light)
    @State private var warningGenerator = UINotificationFeedbackGenerator()
    /// Flipped `true` on the first `.onChanged` of a drag so `prepare()` fires
    /// exactly once per gesture; reset in `.onEnded` for the next drag.
    @State private var hasPreparedHaptic = false

    @State private var thumbnailCache: WindowedThumbnailCache?
    @State private var slideTask: Task<Void, Never>?
    @State private var zoomingId: AssetIdentifier?
    
    private struct SwipedCard: Identifiable {
        let id = UUID()
        let thumbnail: AssetThumbnail?
        let kind: MediaKind
        let assetId: AssetIdentifier?
        var offset: CGSize
    }
    @State private var swipedCards: [SwipedCard] = []

    private let library: PhotoLibraryProviding
    private let filter: SwipeFilter
    private let albumTitle: String?
    private let horizontalThreshold: CGFloat = 100
    private let verticalThreshold: CGFloat = 120

    init(library: PhotoLibraryProviding,
         filter: SwipeFilter = .unfiltered,
         albumTitle: String? = nil,
         sourceAlbumId: String? = nil,
         initialIndex: Int = 0,
         initialAssetId: AssetIdentifier? = nil) {
        self.library = library
        self.filter = filter
        self.albumTitle = albumTitle
        // Use the trait collection's display scale (the iOS 26-compatible
        // replacement for UIScreen.main.scale). Falls back to 2.0 on the rare
        // path where the trait collection hasn't been resolved yet.
        let traitScale = UITraitCollection.current.displayScale
        let scale = traitScale > 0 ? traitScale : 2.0
        let fallbackTarget = CGSize(width: 400 * scale, height: 600 * scale)
        _model = State(initialValue: SwipeSessionModel(
            library: library,
            sourceAlbumId: sourceAlbumId,
            initialIndex: initialIndex,
            initialAssetId: initialAssetId,
            targetSize: fallbackTarget
        ))
    }

    // MARK: - Body

    var body: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                VStack(spacing: 0) {
                    header
                        .padding(.horizontal, 20)
                        .padding(.top, 12)
                        .padding(.bottom, 8)

                    cardArea(in: geo)

                    Spacer(minLength: 12)

                    if model.phase != .finished {
                        controlBar
                    }

                    Spacer(minLength: 12)

                    if model.phase == .ready && !albums.isEmpty {
                        albumGrid
                            .frame(height: 96)
                            .padding(.bottom, 16)
                    } else {
                        Spacer().frame(height: 16)
                    }
                }
            }
        }
        .statusBarHidden(true)
        .task {
            let accurateTarget = PixelSize.from(points: CGSize(width: 400, height: 600))
            model.configure(targetSize: accurateTarget)
            if thumbnailCache == nil {
                thumbnailCache = WindowedThumbnailCache(library: library, targetSize: accurateTarget)
            }
            await library.applyFilter(filter)
            guard !Task.isCancelled else { return }

            await model.start()
            guard !Task.isCancelled else { return }

            albums = await library.userAlbums()
            guard !Task.isCancelled else { return }

            if model.phase == .ready {
                await thumbnailCache?.slide(to: model.currentIndex, total: model.totalCount)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: PhotoLibraryChangePublisher.albumsDidChangeNotification)) { _ in
            Task {
                let updatedAlbums = await library.userAlbums()
                withAnimation(.snappy) {
                    albums = updatedAlbums
                }
            }
        }
        .onPhotoLibraryChangeDebounced {
            Task {
                await model.refreshLibraryState()
                await thumbnailCache?.slide(to: model.currentIndex, total: model.totalCount)
            }
        }
        .onChange(of: model.phase) { _, newPhase in
            if newPhase == .ready {
                Task { albums = await library.userAlbums() }
            }
            if newPhase == .finished {
                // Cover dismissal routes that bypass `onDisappear` (e.g. navigating
                // away while `FullResViewer` is open) — the pool can otherwise retain
                // AVPlayer instances until the next full teardown.
                VideoPlayerPool.shared.drain()
                if UIAccessibility.isVoiceOverRunning {
                    let msg = "All photos reviewed. \(model.favoritedCount) favorited, \(model.movedToAlbumCount) moved to albums, \(model.pendingDeletions.count) pending deletion."
                    UIAccessibility.post(notification: .screenChanged, argument: msg)
                }
            }
        }
        .onChange(of: model.currentIndex) { _, newIndex in
            slideTask = Task { await thumbnailCache?.slide(to: newIndex, total: model.totalCount) }
        }
        .onChange(of: model.pendingDeletions.count) { oldCount, newCount in
            guard newCount > oldCount, UIAccessibility.isVoiceOverRunning else { return }
            // Suppress the increment announcement when this same tick also finishes
            // the session — the finished-summary screenChanged announcement above
            // conveys the pending count, and iOS coalesces consecutive .announcement
            // posts, dropping the earlier one silently.
            guard model.phase != .finished else { return }
            let noun = newCount == 1 ? "photo" : "photos"
            let msg = "Queued for deletion. \(newCount) \(noun) pending."
            UIAccessibility.post(notification: .announcement, argument: msg)
        }
        .onDisappear {
            // Cancel any queued slide before stopAll() so a late-scheduled slide
            // can't restart caching against a reset window on a gone view.
            slideTask?.cancel()
            slideTask = nil
            thumbnailCache?.stopAll()
            VideoPlayerPool.shared.drain()
        }
        .sheet(item: $zoomingId) { id in
            FullResViewer(assetId: id, library: library)
        }
        .sheet(isPresented: $showingQueue) {
            DeletionQueueView(
                model: model,
                library: library,
                onCommit: {
                    let result = await model.commitDecisions()
                    commitResult = result
                    showingQueue = false
                },
                onDismiss: { showingQueue = false }
            )
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            // Close
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("Close")
            .accessibilityIdentifier("CloseDeckButton")

            Spacer()

            // Centred title + counter
            // Long-press for 1.5 s opens the hidden developer debug menu.
            // The gesture is on the VStack rather than the Text so the hit area
            // includes the counter subtitle. 1.5 s minimum duration prevents
            // accidental activation during normal use.
            VStack(spacing: 1) {
                Text(albumTitle ?? "SwipeSort")
                    .font(.headline)
                if model.phase == .ready {
                    Text("\(model.currentIndex + 1) of \(model.totalCount)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("ProgressCounter")
                }
            }
            .multilineTextAlignment(.center)
            .onLongPressGesture(minimumDuration: 1.5) {
                showingDebugMenu = true
            }
            .sheet(isPresented: $showingDebugMenu) {
                DebugMenuView()
                    .presentationDetents([.medium])
                    .presentationDragIndicator(.visible)
            }

            Spacer()

            // Pending deletions badge button (hidden when session is finished)
            if model.phase != .finished {
                Button { showingQueue = true } label: {
                    ZStack(alignment: .topTrailing) {
                        Image(systemName: "trash")
                            .font(.system(size: 19, weight: .semibold))
                            .foregroundStyle(model.pendingDeletions.isEmpty ? Color(.systemGray) : Color.red)
                            .frame(width: 44, height: 44)

                        if !model.pendingDeletions.isEmpty {
                            Text("\(model.pendingDeletions.count)")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 2)
                                .background(Color.red, in: Capsule())
                                .offset(x: 6, y: -4)
                        }
                    }
                }
                .accessibilityLabel("View pending deletions (\(model.pendingDeletions.count) items)")
                .accessibilityIdentifier("PendingDeletionsButton")
            } else {
                Color.clear.frame(width: 44, height: 44)
            }
        }
    }

    // MARK: - Card Area

    @ViewBuilder
    private func cardArea(in geo: GeometryProxy) -> some View {
        let cardHeight = geo.size.height * 0.63

        ZStack {
            switch model.phase {
            case .idle, .loading, .requestingAuthorization:
                ProgressView("Loading library…")

            case .denied:
                permissionDenied

            case .ready:
                ZStack {
                    peekingCard
                    
                    // Render any cards that are currently flying off-screen
                    ForEach(swipedCards) { card in
                        SwipeCardView(
                            thumbnail: card.thumbnail,
                            kind: card.kind,
                            assetId: card.assetId,
                            library: library
                        )
                        .overlay { dragHintOverlay(for: card.offset).accessibilityHidden(true) }
                        .overlay { existingDecisionOverlay(for: card.offset, assetId: card.assetId).accessibilityHidden(true) }
                        .offset(card.offset)
                        .rotationEffect(.degrees(reduceMotion ? 0 : Double(card.offset.width / 20)))
                        .accessibilityHidden(true)
                    }
                    
                    Group {
                        SwipeCardView(
                            thumbnail: model.currentThumbnail,
                            kind: model.currentKind,
                            assetId: model.currentThumbnail?.identifier,
                            library: library
                        )
                        .id(model.currentThumbnail?.identifier)
                        .transition(.asymmetric(insertion: .scale(scale: 0.95), removal: .identity))
                    }
                    .accessibilityIdentifier("SwipeCard")
                    .accessibilityLabel(cardAccessibilityLabel)
                    .accessibilityValue(cardAccessibilityValue)
                    .accessibilityAction(named: "Delete") { Task { await model.swipeDelete() } }
                    .accessibilityAction(named: "Favorite") { Task { await model.swipeFavorite() } }
                    .accessibilityAction(named: "Next photo") { Task { await model.swipeNext() } }
                    .accessibilityAction(named: "Previous photo") { Task { await model.swipePrev() } }
                    .overlay { dragHintOverlay(for: dragOffset).accessibilityHidden(true) }
                    .overlay { existingDecisionOverlay(for: dragOffset, assetId: model.currentThumbnail?.identifier).accessibilityHidden(true) }
                    .offset(dragOffset)
                    .rotationEffect(.degrees(reduceMotion ? 0 : Double(dragOffset.width / 20)))
                    .highPriorityGesture(swipeGesture)
                    .onLongPressGesture(minimumDuration: 0.5) {
                        zoomingId = model.currentThumbnail?.identifier
                    }
                }
                .animation(.spring(response: 0.35, dampingFraction: 0.8), value: model.currentThumbnail?.identifier)

            case .committing:
                ProgressView("Committing…")

            case .finished:
                finishedSummary
                    .task {
                        guard !model.pendingDeletions.isEmpty, commitResult == nil else { return }
                        if !didAutoPresentQueue && !showingQueue {
                            didAutoPresentQueue = true
                            showingQueue = true
                        }
                    }
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: cardHeight)
        .padding(.horizontal, 20)
    }

    // MARK: - Peeking Underneath Card

    private func isPrevDirection(dx: CGFloat, dy: CGFloat) -> Bool {
        let isVertical = abs(dy) > abs(dx)
        return !isVertical && dx > 0
    }

    private func isNextDirection(dx: CGFloat, dy: CGFloat) -> Bool {
        let isVertical = abs(dy) > abs(dx)
        return !isVertical && dx < 0
    }

    /// Returns `true` if the drag is attempting to navigate past the deck boundaries
    /// (i.e. prev on the first photo, or next on the last photo).
    private func isBoundaryDrag(dx: CGFloat, dy: CGFloat) -> Bool {
        let isPrev = isPrevDirection(dx: dx, dy: dy)
        let isNext = isNextDirection(dx: dx, dy: dy)
        let isAtFirst = model.currentIndex == 0
        let isAtLast = model.currentIndex >= max(0, model.totalCount - 1)
        return (isPrev && isAtFirst) || (isNext && isAtLast)
    }

    @ViewBuilder
    private var peekingCard: some View {
        let isPrev = isPrevDirection(dx: dragOffset.width, dy: dragOffset.height)
        let thumb = isPrev ? model.previousThumbnail : model.nextThumbnail
        
        // Dynamically scale and fade the peeking card based on how far the front card is dragged
        let magnitude = max(abs(dragOffset.width), abs(dragOffset.height))
        let progress = min(magnitude / 150.0, 1.0)
        let scale = 0.95 + (0.05 * progress)
        let opacity = 0.8 + (0.2 * progress)
        
        if let thumb = thumb {
            SwipeCardView(
                thumbnail: thumb,
                kind: .photo, // Render strictly as static photo while underneath to avoid double-audio or playback
                assetId: nil,
                library: library
            )
            .scaleEffect(scale)
            .opacity(opacity)
            .accessibilityHidden(true)
        }
    }

    // MARK: - Drag Hint Overlay

    @ViewBuilder
    private func dragHintOverlay(for offset: CGSize) -> some View {
        let dx = offset.width
        let dy = offset.height
        let threshold: CGFloat = 30
        let isVertical = abs(dy) > abs(dx)
        let magnitude: CGFloat = abs(isVertical ? dy : dx)

        if magnitude > threshold {
            let direction: SwipeDirection = isVertical
                ? (dy < 0 ? .up : .down)
                : (dx > 0 ? .right : .left)
            let hint = hintForDirection(direction)
            let progress = min(magnitude / CGFloat(horizontalThreshold), 1.0)
            VStack(spacing: 6) {
                Image(systemName: hint.icon)
                    .font(.title2.weight(.bold))
                Text(hint.text)
                    .font(.title3.weight(.heavy))
                    .tracking(1.5)
                    .dynamicTypeSize(...DynamicTypeSize.accessibility2)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .background(hint.color.opacity(0.88), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .opacity(Double(progress))
        }
    }

    private func hintForDirection(_ direction: SwipeDirection) -> (text: String, icon: String, color: Color) {
        let isPrev = (direction == .right)
        let isNext = (direction == .left)
        if isPrev && model.currentIndex == 0 {
            // Index-based boundary check so the hint matches the gesture gate
            // (Finding 1 fix: previousThumbnail can be nil mid-deck after W9).
            return ("FIRST PHOTO", "exclamationmark.circle.fill", .orange)
        }
        if isNext && model.currentIndex >= max(0, model.totalCount - 1) {
            return ("LAST PHOTO", "exclamationmark.circle.fill", .orange)
        }

        switch direction {
        case .up:    return ("DELETE",   "trash.fill",        .red)
        case .down:  return ("FAVORITE", "heart.fill",        .pink)
        case .left:  return ("NEXT",     "forward.end.fill",  .blue)
        case .right: return ("PREV",     "backward.end.fill", Color(.systemGray))
        }
    }

    // MARK: - Existing Decision Overlay

    @ViewBuilder
    private func existingDecisionOverlay(for offset: CGSize, assetId: AssetIdentifier?) -> some View {
        let dx = offset.width
        let dy = offset.height
        let magnitude = max(abs(dx), abs(dy))
        let threshold: CGFloat = 30
        let progress = min(magnitude / CGFloat(horizontalThreshold), 1.0)
        let opacity = magnitude > threshold ? Double(1.0 - progress) : 1.0

        if let id = assetId,
           let decision = model.decision(for: id),
           opacity > 0.01 {
            let badge = badgeForDecision(decision)
            VStack(spacing: 6) {
                Image(systemName: badge.icon)
                    .font(.title2.weight(.bold))
                Text(badge.text)
                    .font(.title3.weight(.heavy))
                    .tracking(1.5)
                    .dynamicTypeSize(...DynamicTypeSize.accessibility2)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .background(badge.color.opacity(0.88), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .opacity(opacity)
        }
    }

    private func badgeForDecision(_ decision: SwipeDecision) -> (text: String, icon: String, color: Color) {
        switch decision {
        case .moveToAlbum(_, _, let toAlbumId):
            let albumTitle = albums.first(where: { $0.id == toAlbumId })?.title ?? "ALBUM"
            return ("MOVED TO \(albumTitle.uppercased())", "folder.fill", .orange)
        case .delete:
            return ("STAGED FOR DELETE", "trash.fill", .red)
        case .keep(let id):
            if model.queue.favoritedIds.contains(id) {
                return ("FAVORITED", "heart.fill", .pink)
            } else {
                return ("KEPT", "checkmark.circle.fill", .blue)
            }
        }
    }

    // MARK: - Album Grid (2 rows)

    private var albumGrid: some View {
        let rows = [GridItem(.fixed(44)), GridItem(.fixed(44))]
        return ScrollView(.horizontal, showsIndicators: false) {
            LazyHGrid(rows: rows, spacing: 8) {
                ForEach(albums.filter { $0.canAdd && !settings.hiddenAlbumIds.contains($0.id) && $0.id != model.sourceAlbumId }) { album in
                    Button {
                        triggerHaptic()
                        flyAway(offset: CGSize(width: 0, height: -800)) {
                            // Optimistic update for instant UI feedback without DB blocking
                            if let idx = albums.firstIndex(where: { $0.id == album.id }) {
                                withAnimation(.snappy) {
                                    albums[idx].assetCount += 1
                                }
                            }
                            await model.swipeUp(intoAlbumId: album.id)
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "folder.fill")
                                .font(.caption)
                            Text(album.title)
                                .lineLimit(1)
                                .font(.subheadline.weight(.medium))
                                .truncationMode(.tail)
                            Spacer(minLength: 0)
                            Text("\(album.assetCount)")
                                .contentTransition(.numericText())
                                .foregroundStyle(.secondary)
                                .font(.caption)
                        }
                        .padding(.horizontal, 12)
                        .frame(width: 170, height: 44)
                        .background(Color(.tertiarySystemBackground), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Move to \(album.title)")
                    .accessibilityHint("Moves the current photo to this album and advances the deck.")
                    .accessibilityValue("\(album.assetCount) items")
                }
            }
            .padding(.horizontal, 20)
        }
    }

    // MARK: - Control Bar

    private var controlBar: some View {
        Button {
            Task {
                triggerHaptic()
                let decision = await model.undo()
                // Optimistically revert count if we undid an album move
                if case .moveToAlbum(_, _, let toAlbumId) = decision {
                    if let idx = albums.firstIndex(where: { $0.id == toAlbumId }) {
                        withAnimation(.snappy) {
                            albums[idx].assetCount = max(0, albums[idx].assetCount - 1)
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "arrow.uturn.backward")
                    .font(.system(size: 18, weight: .bold))
                Text("Undo")
                    .font(.system(size: 17, weight: .semibold))
            }
            .foregroundStyle(model.queue.decisions.isEmpty ? Color(.systemGray3) : Color(.label))
            .padding(.horizontal, 32)
            .padding(.vertical, 14)
            .background(
                Capsule()
                    .fill(Color(.secondarySystemBackground))
                    .shadow(color: .black.opacity(0.08), radius: 6, y: 3)
            )
        }
        .disabled(model.queue.decisions.isEmpty)
        .accessibilityLabel("Undo last action")
        .accessibilityIdentifier("UndoButton")
    }

    // MARK: - Static States

    private var permissionDenied: some View {
        VStack(spacing: 12) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("Photo library access is required.")
                .font(.headline)
            Text("Grant full access in Settings → SwipeSort → Photos.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .accessibilityIdentifier("PermissionDeniedView")
    }

    private var finishedSummary: some View {
        VStack(spacing: 20) {
            VStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .font(.system(size: 52))
                    .foregroundStyle(.yellow)
                    .accessibilityHidden(true)
                Text("Clean Gallery, Clear Mind")
                    .font(.title2.bold())
                Text("“Simplicity is making room for what matters.”")
                    .font(.subheadline.italic())
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            VStack(spacing: 12) {
                // Finding 2 fix: use favoritedCount (only swipeFavorite swipes) rather
                // than keepCount (which includes plain-keep swipes after W7 decoupling).
                statRow(icon: "heart.fill", color: .pink, title: "Favorited", count: model.favoritedCount)
                Divider()
                statRow(icon: "folder.fill", color: .blue, title: "Moved to Album", count: model.movedToAlbumCount)
                Divider()
                if case .success(let n) = commitResult {
                    statRow(icon: "trash.fill", color: .red, title: "Deleted", count: n)
                } else if !model.pendingDeletions.isEmpty {
                    statRow(icon: "trash.fill", color: .orange, title: "Pending Deletions", count: model.pendingDeletions.count)
                } else {
                    statRow(icon: "trash.fill", color: .secondary, title: "Deleted", count: 0)
                }
            }
            .padding(16)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))

            if let commitResult {
                switch commitResult {
                case .success:
                    EmptyView()
                case .cancelledByUser:
                    Label("Deletion cancelled.", systemImage: "info.circle.fill")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.orange)
                case .failed(let reason):
                    Label("Failed: \(reason)", systemImage: "exclamationmark.triangle.fill")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.red)
                }
            }

            VStack(spacing: 10) {
                if !model.pendingDeletions.isEmpty && commitResult == nil && !showingQueue {
                    Button {
                        showingQueue = true
                    } label: {
                        Text("Review Deletions (\(model.pendingDeletions.count))")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("ReviewDeletionsButton")
                    .accessibilityHint("Presents the deletion review list before submitting.")

                    Button {
                        Task { commitResult = await model.commitDecisions() }
                    } label: {
                        Text("Delete Now (\(model.pendingDeletions.count))")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .accessibilityIdentifier("DeleteNowButton")
                    .accessibilityHint("Immediately deletes the \(model.pendingDeletions.count) pending photos from your library.")
                }

                if model.pendingDeletions.isEmpty || commitResult != nil {
                    Button { dismiss() } label: { goBackLabel }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("GoBackButton")
                } else {
                    Button { dismiss() } label: { goBackLabel }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("GoBackButton")
                }
            }
        }
        .padding(.horizontal, 24)
        .accessibilityIdentifier("FinishedSummaryView")
    }

    @ViewBuilder
    private var goBackLabel: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.backward")
            Text("Go Back")
        }
        .font(.subheadline.weight(.semibold))
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }

    private func statRow(icon: String, color: Color, title: String, count: Int) -> some View {
        HStack {
            Image(systemName: icon)
                .foregroundStyle(color)
                .font(.headline)
                .frame(width: 24)
            Text(title)
                .font(.subheadline.weight(.medium))
            Spacer()
            Text("\(count)")
                .font(.subheadline.bold())
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Accessibility

    private var cardAccessibilityLabel: String {
        guard model.phase == .ready else { return "Swipe card" }
        let kindWord: String
        switch model.currentKind {
        case .photo: kindWord = "Photo"
        case .video: kindWord = "Video"
        case .livePhoto: kindWord = "Live Photo"
        }
        return "\(kindWord) \(model.currentIndex + 1) of \(model.totalCount)"
    }

    private var cardAccessibilityValue: String {
        ""
    }

    // MARK: - Gesture

    private var swipeGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                if settings.hapticsEnabled, !hasPreparedHaptic {
                    impactGenerator.prepare()
                    hasPreparedHaptic = true
                }
                let dx = value.translation.width
                let dy = value.translation.height

                if isBoundaryDrag(dx: dx, dy: dy) {
                    // Rubber-band resistance at the start/end boundary (Finding 1 fix:
                    // use index-based check so W9's unconditional swipePrev is not
                    // blocked by a nil peek thumbnail on decided assets).
                    dragOffset = CGSize(width: dx * 0.25, height: dy * 0.25)
                } else {
                    dragOffset = value.translation
                }
            }
            .onEnded { value in
                hasPreparedHaptic = false
                let dx = value.translation.width
                let dy = value.translation.height

                if isBoundaryDrag(dx: dx, dy: dy) {
                    // Index-based boundary guard (Finding 1 fix: mirrors onChanged).
                    snapBack()
                    triggerWarningHaptic()
                    return
                }

                if abs(dy) > abs(dx) {
                    if dy < -verticalThreshold {
                        triggerHaptic()
                        flyAway(offset: CGSize(width: 0, height: -800)) { await model.swipe(.up) }
                    } else if dy > verticalThreshold {
                        triggerHaptic()
                        flyAway(offset: CGSize(width: 0, height: 800)) { await model.swipe(.down) }
                    } else {
                        snapBack()
                    }
                } else {
                    if dx > horizontalThreshold {
                        triggerHaptic()
                        flyAway(offset: CGSize(width: 600, height: 0)) { await model.swipe(.right) }
                    } else if dx < -horizontalThreshold {
                        triggerHaptic()
                        flyAway(offset: CGSize(width: -600, height: 0)) { await model.swipe(.left) }
                    } else {
                        snapBack()
                    }
                }
            }
    }

    private func flyAway(offset: CGSize, action: @escaping () async -> Void) {
        let card = SwipedCard(
            thumbnail: model.currentThumbnail,
            kind: model.currentKind,
            assetId: model.currentThumbnail?.identifier,
            offset: dragOffset
        )
        let id = card.id
        swipedCards.append(card)
        
        // Reset the main deck's offset instantly so the new card appears in the center
        dragOffset = .zero
        
        // Animate the swiped card to its final destination
        if reduceMotion {
            swipedCards.removeAll { $0.id == id }
        } else {
            withAnimation(.easeOut(duration: 0.2)) {
                if let idx = swipedCards.firstIndex(where: { $0.id == id }) {
                    swipedCards[idx].offset = offset
                }
            }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 200_000_000)
                swipedCards.removeAll { $0.id == id }
            }
        }
        
        Task { await action() }
    }

    private func animate(offset: CGSize) {
        if reduceMotion {
            var tx = Transaction(); tx.disablesAnimations = true
            withTransaction(tx) { dragOffset = offset }
        } else {
            withAnimation(.easeOut(duration: 0.2)) { dragOffset = offset }
        }
    }

    private func snapBack() {
        if reduceMotion {
            var tx = Transaction(); tx.disablesAnimations = true
            withTransaction(tx) { dragOffset = .zero }
        } else {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) { dragOffset = .zero }
        }
    }

    private func triggerHaptic() {
        guard settings.hapticsEnabled else { return }
        impactGenerator.impactOccurred()
        impactGenerator.prepare()
    }

    private func triggerWarningHaptic() {
        guard settings.hapticsEnabled else { return }
        warningGenerator.notificationOccurred(.warning)
        warningGenerator.prepare()
    }
}

// MARK: - Debug Menu (hidden; long-press on swipe title bar)

/// Developer-only debug panel accessible via a 1.5-second long-press on the
/// swipe-screen title bar.
///
/// Not linked from any user-facing navigation. The toggle writes directly to
/// `UserDefaults` via `DryRunMode.setEnabled(_:)` so the value
/// persists across app launches and is picked up by `PhotoKitLibrary` and
/// `SwipeSessionModel` on the next session start.
///
/// Intentionally plain-looking (no custom styling) so it is clearly not part
/// of the user-facing product UI.
private struct DebugMenuView: View {
    @AppStorage(DryRunMode.defaultsKey) private var isDryRun: Bool = true

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Dry-run mode", isOn: $isDryRun)
                } header: {
                    Text("Developer Settings")
                } footer: {
                    Text(isDryRun
                         ? "Destructive PhotoKit calls are logged only. No actual library changes."
                         : "⚠️ ARMED — real deletion and album moves will execute. Restart session to apply.")
                        .foregroundStyle(isDryRun ? Color.secondary : Color.red)
                }
            }
            .navigationTitle("Debug Menu")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
