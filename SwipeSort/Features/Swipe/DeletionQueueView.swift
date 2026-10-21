import SwiftUI
import UIKit

/// A full-screen sheet showing all assets queued for deletion.
///
/// Accessible from the trash-badge button in the swipe header. Each cell
/// shows a thumbnail with a red ✕ badge to dequeue the asset individually.
/// The "Delete All" toolbar action commits the entire queue by calling
/// `onCommit`, which invokes `SwipeSessionModel.commitDecisions()`.
struct DeletionQueueView: View {
    let model: SwipeSessionModel
    let library: PhotoLibraryProviding
    let onCommit: () async -> Void
    let onDismiss: () -> Void

    @State private var imageCache = GridImageCache()

    var body: some View {
        NavigationStack {
            Group {
                if model.pendingDeletions.isEmpty {
                    emptyState
                } else {
                    queueGrid
                }
            }
            .navigationTitle("Pending Deletions (\(model.pendingDeletions.count))")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Back") { onDismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task { await onCommit() }
                    } label: {
                        Label("Delete All (\(model.pendingDeletions.count))", systemImage: "trash.fill")
                    }
                    .tint(.red)
                    .disabled(model.pendingDeletions.isEmpty)
                }
            }
        }
    }

    // MARK: - Subviews

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "trash.slash")
                .font(.system(size: 48))
                .foregroundStyle(.green)
            Text("No deletions queued")
                .font(.title3.bold())
            Text("Swipe photos to queue deletions. Album moves happen instantly.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
    }

    private var queueGrid: some View {
        // The outer branch in `body` gates on !pendingDeletions.isEmpty, so this
        // view is only reached when the queue is non-empty. No inner guard needed.
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Queued for Deletion (\(model.pendingDeletions.count))")
                    .font(.headline)
                    .padding(.horizontal, 16)

                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 3), count: 3), spacing: 3) {
                    ForEach(model.pendingDeletions, id: \.rawValue) { id in
                        QueueThumbnailCell(id: id, library: library, cache: imageCache) {
                            model.removeFromDeletionQueue(id)
                        }
                    }
                }
            }
            .padding(.top, 4)
        }
    }
}

// MARK: - Thumbnail Cell

private struct QueueThumbnailCell: View {
    let id: AssetIdentifier
    let library: PhotoLibraryProviding
    let cache: GridImageCache
    let onRemove: () -> Void

    @State private var image: UIImage?

    var body: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    Color(.secondarySystemBackground)
                }
            }
            .clipped()
            .contentShape(Rectangle())
            .overlay(alignment: .topTrailing) {
                // ✕ dequeue badge
                Button(action: onRemove) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(.white)
                        .background(Color.red, in: Circle())
                        .shadow(radius: 2)
                }
                .padding(6)
            }
            .task(id: id) {
                if let cached = cache.image(for: id) {
                    image = cached
                    return
                }
                let ts = PixelSize.from(points: CGSize(width: 150, height: 150))
                for await thumb in library.thumbnailStream(for: id, targetSize: ts) {
                    guard !Task.isCancelled else { break }
                    image = thumb.image
                    if !thumb.isDegraded {
                        cache.store(thumb.image, for: id)
                        break
                    }
                }
            }
    }
}
