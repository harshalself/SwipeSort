import SwiftUI

/// A pinch-zoom sheet for inspecting a single asset at full resolution.
///
/// Triggered by a long-press on the swipe card. Loads the largest available
/// thumbnail scaled to screen pixels via the injected library so iCloud-only
/// assets are downloaded on demand.
///
/// Zoom bounds: 1×–6×. Double-tap toggles between 1× and 2×. Panning is
/// constrained to active zoom — at 1× the offset snaps back to centre.
struct FullResViewer: View {
    let assetId: AssetIdentifier
    let library: PhotoLibraryProviding

    @State private var image: UIImage?
    @State private var scale: CGFloat = 1.0
    @State private var offset: CGSize = .zero
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color.black.ignoresSafeArea()

                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .scaleEffect(scale)
                        .offset(offset)
                        .gesture(
                            SimultaneousGesture(
                                MagnificationGesture()
                                    .onChanged { value in
                                        scale = max(1, min(6, value))
                                    },
                                DragGesture()
                                    .onChanged { value in
                                        if scale > 1 { offset = value.translation }
                                    }
                                    .onEnded { _ in
                                        if scale <= 1 {
                                            withAnimation { offset = .zero }
                                        }
                                    }
                            )
                        )
                        .onTapGesture(count: 2) {
                            withAnimation {
                                scale = scale > 1 ? 1 : 2
                                offset = .zero
                            }
                        }
                } else {
                    ProgressView().tint(.white)
                }
            }
            .task(id: assetId) {
                let target = PixelSize.from(points: proxy.size)
                image = (await library.thumbnail(for: assetId, targetSize: target))?.image
            }
        }
        .overlay(alignment: .topTrailing) {
            Button { dismiss() } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title)
            }
            .tint(.white)
            .padding()
        }
    }
}
