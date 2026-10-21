import SwiftUI
import PhotosUI

/// A `UIViewRepresentable` wrapper around `PHLivePhotoView` for the swipe card.
///
/// Tap-to-play fires the `.hint` preview animation. Full-clip playback is never
/// triggered automatically; doing so would leave a decoder open per visible card
/// and drain the battery during long triage sessions.
///
/// The `UITapGestureRecognizer` lives in the coordinator rather than in a SwiftUI
/// `.onTapGesture` modifier so it negotiates cleanly with the outer
/// `DragGesture` — UIKit and SwiftUI gesture recognizers cooperate via the
/// responder chain rather than competing.
///
/// PhotoKit hazard: `livePhoto(for:targetSize:)` suspends indefinitely when
/// the first callback delivers `live == nil, isDegraded == true` (iCloud download
/// in progress) and the connection then drops. The pending `Task` is cancelled
/// only when the coordinator is dismantled.
struct LivePhotoCardView: UIViewRepresentable {
    let assetId: AssetIdentifier
    let library: PhotoLibraryProviding
    let fallback: AssetThumbnail?

    final class Coordinator: NSObject {
        weak var livePhotoView: PHLivePhotoView?
        var loadedAssetId: String?
        var pendingLoad: Task<Void, Never>?

        @objc func handleTap() {
            guard let view = livePhotoView, view.livePhoto != nil else { return }
            view.stopPlayback()
            view.startPlayback(with: .hint)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> PHLivePhotoView {
        let v = PHLivePhotoView()
        v.contentMode = .scaleAspectFit
        v.clipsToBounds = true
        v.layer.cornerRadius = 24
        v.isUserInteractionEnabled = true

        context.coordinator.livePhotoView = v
        let tap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleTap)
        )
        v.addGestureRecognizer(tap)
        return v
    }

    func updateUIView(_ uiView: PHLivePhotoView, context: Context) {
        // `updateUIView` fires on every layout tick. Guard on loadedAssetId so
        // a new PHLivePhoto request is issued only when the asset changes;
        // re-requesting the same asset would cancel and restart an in-flight
        // download unnecessarily.
        if context.coordinator.loadedAssetId == assetId.rawValue { return }
        context.coordinator.loadedAssetId = assetId.rawValue
        context.coordinator.pendingLoad?.cancel()

        let bounds = uiView.bounds.size
        let target = PixelSize.from(points: CGSize(
            width: max(bounds.width, 1),
            height: max(bounds.height, 1)
        ))
        let id = assetId
        let lib = library

        context.coordinator.pendingLoad = Task { @MainActor in
            let live = await lib.livePhoto(for: id, targetSize: target)
            // A stale response arrives when the coordinator was reassigned to
            // a different asset after the fetch started (rapid swipe scenario).
            // Discard it to avoid showing the wrong Live Photo on the card.
            if context.coordinator.loadedAssetId == id.rawValue {
                uiView.livePhoto = live
            }
        }
    }

    static func dismantleUIView(_ uiView: PHLivePhotoView, coordinator: Coordinator) {
        coordinator.pendingLoad?.cancel()
        uiView.stopPlayback()
        uiView.livePhoto = nil
    }
}
