import SwiftUI

/// A sheet for toggling the visibility of individual albums.
///
/// Changes write to `AppSettings.hiddenAlbumIds` and take effect immediately in
/// `AlbumsView` and the swipe-session album strip.
struct AlbumFilterSheet: View {
    let albums: [UserAlbum]
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(albums) { album in
                        let isVisible = Binding<Bool>(
                            get: { !settings.hiddenAlbumIds.contains(album.id) },
                            set: { newValue in
                                if newValue {
                                    settings.hiddenAlbumIds.remove(album.id)
                                } else {
                                    settings.hiddenAlbumIds.insert(album.id)
                                }
                            }
                        )

                        Toggle(isOn: isVisible) {
                            HStack {
                                Image(systemName: "photo.stack.fill")
                                    .foregroundStyle(.tint)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(album.title)
                                        .font(.body)
                                    Text("\(album.assetCount) item\(album.assetCount == 1 ? "" : "s")")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                } header: {
                    Text("Visible Albums (\(albums.count - settings.hiddenAlbumIds.count)/\(albums.count))")
                } footer: {
                    Text("Hidden albums will not appear in the Albums tab or the Move to Album picker.")
                }
            }
            .navigationTitle("Filter Albums")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Show All") {
                        settings.hiddenAlbumIds.removeAll()
                    }
                    .disabled(settings.hiddenAlbumIds.isEmpty)
                }
            }
        }
    }
}
