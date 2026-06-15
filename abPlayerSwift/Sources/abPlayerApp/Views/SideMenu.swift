import SwiftUI
import abPlayerCore

struct SideMenu: View {
    @ObservedObject var store: AppStateStore

    private var topLevelPages: [AppPage] {
        [.library, .search, .downloads, .settings]
    }

    var body: some View {
#if os(iOS)
        HStack(spacing: 0) {
            ForEach(topLevelPages, id: \.self) { page in
                bottomTabButton(page)
            }
        }
        .padding(.horizontal, 8)
        .padding(.top, 8)
        .padding(.bottom, 10)
        .background(Color.platformControlBackground)
#else
        VStack(alignment: .leading, spacing: 12) {
            Text("abPlayer")
                .font(.headline)
                .padding(.bottom, 8)

            menuButton(L10n.key("menu.library", mode: store.appLanguage), page: .library)
            menuButton(L10n.key("menu.search", mode: store.appLanguage), page: .search)
            menuButton(L10n.key("menu.downloads", mode: store.appLanguage), page: .downloads)
            menuButton(L10n.key("menu.settings", mode: store.appLanguage), page: .settings)

            Spacer()
        }
        .padding(16)
        .frame(width: 190, alignment: .topLeading)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(Color.platformControlBackground)
#endif
    }

    private func menuButton(_ title: String, page: AppPage) -> some View {
        Button {
            store.open(page: page)
        } label: {
            HStack {
                Text(title)
                Spacer()
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(store.currentPage == page ? Color.accentColor.opacity(0.2) : Color.clear)
            )
        }
        .buttonStyle(.plain)
    }

    private func bottomTabButton(_ page: AppPage) -> some View {
        Button {
            store.open(page: page)
        } label: {
            VStack(spacing: 4) {
                Image(systemName: iconName(for: page))
                    .font(.system(size: 16, weight: .semibold))
                Text(title(for: page))
                    .font(.caption2)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .foregroundStyle(store.currentPage == page ? Color.accentColor : Color.primary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func title(for page: AppPage) -> String {
        switch page {
        case .library:
            return L10n.key("menu.library", mode: store.appLanguage)
        case .search:
            return L10n.key("menu.search", mode: store.appLanguage)
        case .downloads:
            return L10n.key("menu.downloads", mode: store.appLanguage)
        case .settings:
            return L10n.key("menu.settings", mode: store.appLanguage)
        case .bookPlayer:
            return L10n.key("menu.library", mode: store.appLanguage)
        }
    }

    private func iconName(for page: AppPage) -> String {
        switch page {
        case .library:
            return "books.vertical"
        case .search:
            return "magnifyingglass"
        case .downloads:
            return "arrow.down.circle"
        case .settings:
            return "gearshape"
        case .bookPlayer:
            return "play.circle"
        }
    }
}
