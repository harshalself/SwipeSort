import SwiftUI

/// A single swipe card. Pure presentation — all gesture handling lives in `SwipeStackView`.
///
/// Dispatches on `MediaKind`:
///  - `.photo` — still image from `AssetThumbnail`
///  - `.livePhoto` — `LivePhotoCardView`; tap plays the `.hint` preview
///  - `.video` — `VideoCardView`; autoplays muted when the `autoplayVideos` setting is on
struct SwipeCardView: View {
    let thumbnail: AssetThumbnail?
    let kind: MediaKind
    let assetId: AssetIdentifier?
    let library: PhotoLibraryProviding

    @Environment(AppSettings.self) private var settings

    var body: some View {
        RoundedRectangle(cornerRadius: 24, style: .continuous)
            .fill(Color(uiColor: .secondarySystemBackground))
            .overlay {
                switch kind {
                case .photo:
                    photoBody

                case .livePhoto:
                    if let id = assetId {
                        LivePhotoCardView(assetId: id, library: library, fallback: thumbnail)
                            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                            .overlay(alignment: .topLeading) {
                                Label("LIVE", systemImage: "livephoto")
                                    .font(.caption.bold())
                                    .padding(6)
                                    .background(.thinMaterial, in: Capsule())
                                    .padding(12)
                            }
                    } else {
                        photoBody
                    }

                case .video(let duration):
                    if let id = assetId {
                        let autoplay = Self.shouldAutoplay(settings: settings)
                        VideoCardView(assetId: id, library: library, thumbnail: thumbnail, autoplay: autoplay)
                            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                    } else {
                        photoBody.overlay(alignment: .bottom) {
                            Label(durationLabel(duration), systemImage: "play.circle.fill")
                                .font(.caption.bold())
                                .padding(8)
                                .background(.thinMaterial, in: Capsule())
                                .padding(12)
                        }
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
    }

    @ViewBuilder
    private var photoBody: some View {
        if let thumbnail {
            Image(uiImage: thumbnail.image)
                .resizable()
                .scaledToFit()
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                .overlay(alignment: .topTrailing) {
                    if thumbnail.isDegraded {
                        ProgressView()
                            .padding(8)
                            .background(.thinMaterial, in: Circle())
                            .padding(12)
                    }
                }

        } else {
            ProgressView()
        }
    }

    /// Returns whether video autoplay should be active given the current setting.
    ///
    /// Static so tests can call it without a hosting SwiftUI view.
    static func shouldAutoplay(settings: AppSettings) -> Bool {
        settings.autoplayVideos
    }

    private func durationLabel(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        if s < 60 { return "\(s)s video" }
        let m = s / 60, r = s % 60
        return String(format: "%d:%02d video", m, r)
    }
}
