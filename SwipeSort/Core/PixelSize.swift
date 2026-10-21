import UIKit

/// Converts a point-based `CGSize` into pixel dimensions for PhotoKit requests.
///
/// PhotoKit's `targetSize` parameter is defined in pixels. Passing a points-
/// based size produces thumbnails that are 2–3× too small on retina displays,
/// resulting in blurry cards. All `PHImageManager` requests should use this
/// helper rather than passing point sizes directly.
///
/// Why: `@MainActor` isolation is required because `UITraitCollection.current`
/// is only valid on the main thread; calling this from a background context
/// would read a stale or incorrect display scale.
enum PixelSize {
    @MainActor
    static func from(points: CGSize, scale: CGFloat = UITraitCollection.current.displayScale) -> CGSize {
        CGSize(width: points.width * scale, height: points.height * scale)
    }
}
