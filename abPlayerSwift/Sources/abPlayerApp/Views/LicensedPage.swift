import SwiftUI
import abPlayerCore

struct LicensedPage: View {
    @ObservedObject var store: AppStateStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.key("licensed.title", mode: store.appLanguage))
                .font(.title2)
                .bold()

            Text(L10n.key("licensed.description", mode: store.appLanguage))
                .foregroundStyle(.secondary)
                .font(.subheadline)

            Spacer()
        }
        .padding(16)
    }
}
