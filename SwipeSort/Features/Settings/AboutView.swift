import SwiftUI

/// The About screen, showing build version, bundle ID, and privacy information.
struct AboutView: View {
    private var version: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "\(short) (\(build))"
    }

    var body: some View {
        Form {
            Section {
                LabeledContent("Version", value: version)
                LabeledContent("Bundle ID", value: Bundle.main.bundleIdentifier ?? "?")
            }

            Section("Acknowledgments") {
                Text("SwipeSort is built entirely on Apple frameworks — PhotoKit, SwiftUI, SwiftData, AVKit. No third-party dependencies.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Privacy") {
                Text("On-device only. No cloud processing, no analytics, no accounts.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("About")
        .navigationBarTitleDisplayMode(.inline)
    }
}
