import SwiftUI

/// Attaches a debounced observer to `PhotoLibraryChangePublisher.didChangeNotification`.
///
/// PhotoKit fires `didChangeNotification` in bursts during batch operations
/// (user favourites 30 photos in Photos.app → 30 back-to-back notifications).
/// This modifier coalesces the burst to a single trailing-edge refresh by
/// cancelling any prior in-flight task before starting a new one.
private struct PhotoLibraryChangeDebouncer: ViewModifier {
    let debounce: Duration
    let action: () async -> Void

    @State private var task: Task<Void, Never>?

    func body(content: Content) -> some View {
        content.onReceive(
            NotificationCenter.default.publisher(for: PhotoLibraryChangePublisher.didChangeNotification)
        ) { _ in
            task?.cancel()
            task = Task {
                try? await Task.sleep(for: debounce)
                guard !Task.isCancelled else { return }
                await action()
            }
        }
    }
}

extension View {
    /// Debounces `PhotoLibraryChangePublisher.didChangeNotification` bursts to a
    /// single trailing-edge callback. See `PhotoLibraryChangeDebouncer`.
    func onPhotoLibraryChangeDebounced(
        _ debounce: Duration = .milliseconds(500),
        perform action: @escaping () async -> Void
    ) -> some View {
        modifier(PhotoLibraryChangeDebouncer(debounce: debounce, action: action))
    }
}
