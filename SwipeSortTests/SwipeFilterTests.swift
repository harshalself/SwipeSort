import Testing
import Foundation
@testable import SwipeSort

@Suite("SwipeFilter")
struct SwipeFilterTests {

    @Test("unfiltered produces nil predicate")
    func unfilteredNoPredicate() {
        #expect(SwipeFilter.unfiltered.nsPredicate() == nil)
    }

    @Test("videosOnly builds mediaType predicate")
    func videosOnlyPredicate() {
        var f = SwipeFilter.unfiltered
        f.mediaType = .videosOnly
        let p = f.nsPredicate()
        #expect(p != nil)
        #expect(p!.predicateFormat.contains("mediaType"))
    }

    @Test("screenshotsOnly builds mediaSubtypes bitmask predicate")
    func screenshotsPredicate() {
        var f = SwipeFilter.unfiltered
        f.mediaType = .screenshotsOnly
        let p = f.nsPredicate()!
        #expect(p.predicateFormat.contains("mediaSubtypes"))
    }

    @Test("date range narrows to creationDate BETWEEN")
    func datePredicate() {
        var f = SwipeFilter.unfiltered
        let start = Date(timeIntervalSince1970: 1_500_000_000)
        let end = Date(timeIntervalSince1970: 1_600_000_000)
        f.dateRange = start...end
        let p = f.nsPredicate()!
        #expect(p.predicateFormat.contains("creationDate"))
    }

    @Test("combining filters ANDs them together")
    func combinedFilters() {
        var f = SwipeFilter.unfiltered
        f.mediaType = .videosOnly
        f.dateRange = Date.distantPast...Date.distantFuture
        let p = f.nsPredicate()!
        #expect(p.predicateFormat.contains("mediaType"))
        #expect(p.predicateFormat.contains("creationDate"))
    }


    @Test("newestFirst uses creationDate desc")
    func newestFirstSort() {
        let f = SwipeFilter.unfiltered  // defaults to newestFirst
        let sds = f.nsSortDescriptors()
        #expect(sds.first?.key == "creationDate")
        #expect(sds.first?.ascending == false)
    }

    @Test("summary describes active filters")
    func summary() {
        var f = SwipeFilter.unfiltered
        f.mediaType = .screenshotsOnly
        #expect(f.summary.contains("Screenshots"))
    }

    @Test("unfiltered summary is 'All'")
    func summaryAll() {
        #expect(SwipeFilter.unfiltered.summary == "All")
    }

    @Test("onlyFavorites builds favorite == YES predicate")
    func favoritesOnlyPredicate() {
        var f = SwipeFilter.unfiltered
        f.onlyFavorites = true
        let p = f.nsPredicate()!
        #expect(p.predicateFormat.contains("favorite == 1") || p.predicateFormat.contains("favorite == YES"))
    }

    @Test("multi select media types builds OR compound predicate")
    func multiSelectMediaTypesPredicate() {
        var f = SwipeFilter.unfiltered
        f.selectedMediaTypes = [.photos, .videos]
        let p = f.nsPredicate()!
        #expect(p.predicateFormat.contains("OR"))
        #expect(p.predicateFormat.contains("mediaType"))
    }


    @Test("summary collapses same-year range")
    func summarySameYear() {
        var f = SwipeFilter.unfiltered
        var comps = DateComponents(); comps.year = 2019; comps.month = 1; comps.day = 1
        let start = Calendar.current.date(from: comps)!
        comps.month = 12; comps.day = 31
        let end = Calendar.current.date(from: comps)!
        f.dateRange = start...end
        // Both 2019 → collapses to a single "2019", not "2019–2019".
        #expect(f.summary.contains("2019"))
        #expect(!f.summary.contains("2019–2019"))
    }
}
