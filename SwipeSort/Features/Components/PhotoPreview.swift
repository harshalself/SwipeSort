import SwiftUI

/// A larger, single-photo view used as the preview inside `.contextMenu`.
///
/// Fetches a ~1200-point square thumbnail via `thumbnail(for:targetSize:)` — a
/// deliberately different `targetSize` than the grid cell's ~400pt request so
/// PhotoKit returns a sharper image than what's already cached for the cell.
/// The preview view is short-lived (dismissed with the menu), so no
/// `GridImageCache` write path is needed.
///
/// While loading, shows a neutral placeholder. Photos.app-style: no spinner.
struct PhotoPreview: View {
    let id: AssetIdentifier
    let library: PhotoLibraryProviding

    @State private var image: UIImage?

    private var targetSize: CGSize {
        PixelSize.from(points: CGSize(width: 1200, height: 1200))
    }

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                Color(.secondarySystemBackground)
                    .aspectRatio(1, contentMode: .fit)
            }
        }
        .frame(width: 320, height: 320)
        .task(id: id) {
            image = nil
            let thumb = await library.thumbnail(for: id, targetSize: targetSize)
            image = thumb?.image
        }
    }
}
