import Foundation
import Photos

/// A load-time filter that narrows the set of assets presented in a swipe session.
///
/// Changing the filter while a session is active ends the session with a
/// confirmation prompt rather than attempting to reconcile the cursor mid-flight.
/// `Hashable` so `.task(id: filter)` restarts automatically when the value changes.
///
/// Every combination of filter options compiles to a single `NSPredicate` on
/// `PHFetchOptions`.
/// Why: post-fetch filtering would materialise every asset in the lazy
/// `PHFetchResult`, defeating its incremental-load design and causing
/// significant memory pressure on large libraries.
struct SwipeFilter: Sendable, Hashable {

    /// Exclusive media-type constraint used internally to build the `NSPredicate`.
    enum MediaTypeFilter: Sendable, Hashable {
        case any
        case photosOnly
        case videosOnly
        case screenshotsOnly
    }

    /// User-visible media-type toggle options.
    enum MediaTypeOption: String, Sendable, Hashable, CaseIterable {
        case favorites = "Favorites"
        case photos = "Photos"
        case videos = "Videos"
        case screenshots = "Screenshots"
    }

    /// The order in which assets are fetched from PhotoKit.
    enum SortOrder: Sendable, Hashable, CaseIterable {
        case newestFirst
        case oldestFirst
    }

    var selectedMediaTypes: Set<MediaTypeOption> = []
    var dateRange: ClosedRange<Date>? = nil
    var sortOrder: SortOrder = .newestFirst

    var onlyFavorites: Bool {
        get { selectedMediaTypes.contains(.favorites) }
        set {
            if newValue {
                selectedMediaTypes.insert(.favorites)
            } else {
                selectedMediaTypes.remove(.favorites)
            }
        }
    }

    var mediaType: MediaTypeFilter {
        get {
            let mediaOnly = selectedMediaTypes.subtracting([.favorites])
            if mediaOnly.count == 1, let first = mediaOnly.first {
                switch first {
                case .photos: return .photosOnly
                case .videos: return .videosOnly
                case .screenshots: return .screenshotsOnly
                case .favorites: return .any
                }
            }
            return .any
        }
        set {
            let fav = selectedMediaTypes.contains(.favorites)
            selectedMediaTypes.removeAll()
            if fav { selectedMediaTypes.insert(.favorites) }
            switch newValue {
            case .any:
                break
            case .photosOnly:
                selectedMediaTypes.insert(.photos)
            case .videosOnly:
                selectedMediaTypes.insert(.videos)
            case .screenshotsOnly:
                selectedMediaTypes.insert(.screenshots)
            }
        }
    }

    /// A filter that includes all assets in creation-date descending order.
    static let unfiltered = SwipeFilter()

    /// Builds the `NSPredicate` for this filter, or `nil` for an unfiltered fetch.
    func nsPredicate() -> NSPredicate? {
        var parts: [NSPredicate] = []

        if onlyFavorites {
            parts.append(NSPredicate(format: "favorite == YES"))
        }

        if !selectedMediaTypes.isEmpty {
            var mediaParts: [NSPredicate] = []
            if selectedMediaTypes.contains(.photos) {
                mediaParts.append(NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue))
            }
            if selectedMediaTypes.contains(.videos) {
                mediaParts.append(NSPredicate(format: "mediaType == %d", PHAssetMediaType.video.rawValue))
            }
            if selectedMediaTypes.contains(.screenshots) {
                mediaParts.append(NSPredicate(format: "(mediaSubtypes & %d) != 0", PHAssetMediaSubtype.photoScreenshot.rawValue))
            }
            if mediaParts.count == 1 {
                parts.append(mediaParts[0])
            } else if mediaParts.count > 1 {
                parts.append(NSCompoundPredicate(orPredicateWithSubpredicates: mediaParts))
            }
        }

        if let range = dateRange {
            parts.append(NSPredicate(
                format: "creationDate >= %@ AND creationDate <= %@",
                range.lowerBound as NSDate,
                range.upperBound as NSDate
            ))
        }

        guard !parts.isEmpty else { return nil }
        if parts.count == 1 {
            return parts[0]
        }
        return NSCompoundPredicate(andPredicateWithSubpredicates: parts)
    }

    /// Returns `NSSortDescriptor`s for the chosen sort order.
    func nsSortDescriptors() -> [NSSortDescriptor] {
        switch sortOrder {
        case .newestFirst:
            return [
                NSSortDescriptor(key: "creationDate", ascending: false),
                NSSortDescriptor(key: "modificationDate", ascending: false),
            ]
        case .oldestFirst:
            return [
                NSSortDescriptor(key: "creationDate", ascending: true),
                NSSortDescriptor(key: "modificationDate", ascending: true),
            ]
        }
    }

    /// A short human-readable description of the active filter, shown in the UI header.
    var summary: String {
        var parts: [String] = []
        if !selectedMediaTypes.isEmpty {
            let names = MediaTypeOption.allCases.filter { selectedMediaTypes.contains($0) }.map(\.rawValue)
            parts.append(names.joined(separator: ", "))
        }
        if let range = dateRange {
            let f = DateFormatter()
            f.dateFormat = "yyyy"
            let lo = f.string(from: range.lowerBound)
            let hi = f.string(from: range.upperBound)
            parts.append(lo == hi ? lo : "\(lo)–\(hi)")
        }
        return parts.isEmpty ? "All" : parts.joined(separator: " · ")
    }
}
