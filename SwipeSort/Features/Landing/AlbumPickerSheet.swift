import SwiftUI

/// A sheet for selecting or creating a destination album for a bulk move.
///
/// Filters out the source album (to prevent self-moves) and any album that
/// does not accept content (`canAdd == false`). Presents a "New Album…" row
/// at the top so the user can create an album inline without leaving the sheet.
struct AlbumPickerSheet: View {
    let library: PhotoLibraryProviding
    let selectedCount: Int
    let sourceAlbumId: String?
    let onMove: (UserAlbum) async -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var albums: [UserAlbum] = []
    @State private var isLoading = true

    // New album prompt state
    @State private var showingNewAlbumAlert = false
    @State private var newAlbumTitle = ""

    // Confirmation state
    @State private var targetAlbum: UserAlbum?
    @State private var showingConfirmation = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        newAlbumTitle = ""
                        showingNewAlbumAlert = true
                    } label: {
                        HStack(spacing: 14) {
                            Image(systemName: "plus.circle.fill")
                                .font(.system(size: 24))
                                .foregroundStyle(.blue)
                            Text("New Album...")
                                .font(.body.weight(.medium))
                                .foregroundStyle(.primary)
                        }
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("CreateNewAlbumRow")
                }

                Section("Existing Albums") {
                    if isLoading {
                        HStack {
                            Spacer()
                            ProgressView()
                            Spacer()
                        }
                        .padding(.vertical, 12)
                    } else if availableAlbums.isEmpty {
                        Text("No other albums found.")
                            .foregroundStyle(.secondary)
                            .font(.subheadline)
                    } else {
                        ForEach(availableAlbums) { album in
                            Button {
                                targetAlbum = album
                                showingConfirmation = true
                            } label: {
                                HStack {
                                    Image(systemName: "rectangle.stack")
                                        .foregroundStyle(.blue)
                                        .frame(width: 28)

                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(album.title)
                                            .font(.body.weight(.medium))
                                            .foregroundStyle(.primary)
                                        Text("\(album.assetCount) photos")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }

                                    Spacer()

                                    Image(systemName: "chevron.right")
                                        .font(.caption.weight(.bold))
                                        .foregroundStyle(.tertiary)
                                }
                                .padding(.vertical, 4)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("AlbumRow-\(album.id)")
                        }
                    }
                }
            }
            .navigationTitle("Move \(selectedCount) \(selectedCount == 1 ? "Photo" : "Photos")")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
            .task {
                await loadAlbums()
            }
            .alert("New Album", isPresented: $showingNewAlbumAlert) {
                TextField("Album Title", text: $newAlbumTitle)
                Button("Cancel", role: .cancel) { }
                Button("Create & Move") {
                    let title = newAlbumTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !title.isEmpty else { return }
                    Task {
                        if let created = await library.createUserAlbum(title: title) {
                            await onMove(created)
                            dismiss()
                        }
                    }
                }
            } message: {
                Text("Enter a name for this album.")
            }
            .alert(
                "Move to \(targetAlbum?.title ?? "Album")?",
                isPresented: $showingConfirmation,
                presenting: targetAlbum
            ) { album in
                Button("Cancel", role: .cancel) { }
                Button("Move") {
                    Task {
                        await onMove(album)
                        dismiss()
                    }
                }
            } message: { album in
                Text("Move \(selectedCount) \(selectedCount == 1 ? "item" : "items") into '\(album.title)'?")
            }
        }
    }

    private var availableAlbums: [UserAlbum] {
        albums.filter { album in
            album.canAdd && album.id != sourceAlbumId
        }
    }

    private func loadAlbums() async {
        isLoading = true
        albums = await library.userAlbums()
        isLoading = false
    }
}
