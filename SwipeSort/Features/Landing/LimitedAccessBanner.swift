import SwiftUI

/// A banner displayed when the user has granted only `.limited` photo library access.
///
/// Prompts the user to open iOS Settings to grant full access, as SwipeSort
/// requires full access to properly sort and manage the entire library.
struct LimitedAccessBanner: View {
    @Environment(\.openURL) private var openURL
    
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.yellow)
                .font(.title3)
            
            VStack(alignment: .leading, spacing: 4) {
                Text("Limited Photo Access")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                
                Text("SwipeSort works best with full access to your photo library.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                Button("Manage in Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        openURL(url)
                    }
                }
                .font(.caption)
                .fontWeight(.medium)
                .padding(.top, 4)
            }
            Spacer(minLength: 0)
        }
        .padding()
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(UIColor.secondarySystemBackground))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.yellow.opacity(0.3), lineWidth: 1)
        }
        .padding(.horizontal)
        .padding(.bottom, 8)
    }
}
