import SwiftUI
import abPlayerCore
#if os(iOS)
import UIKit
#endif

struct RootView: View {
    @ObservedObject var store: AppStateStore
    @ObservedObject var playback: PlaybackController
#if os(iOS)
    @Environment(\.scenePhase) private var scenePhase
#endif

    var body: some View {
        rootLayout
            .background(Color.platformWindowBackground)
#if os(iOS)
            .onChange(of: scenePhase) { phase in
                guard phase != .active else { return }
                UIApplication.shared.sendAction(
                    #selector(UIResponder.resignFirstResponder),
                    to: nil,
                    from: nil,
                    for: nil
                )
            }
#endif
            .alert(L10n.key("alert.error.title", mode: store.appLanguage), isPresented: Binding(get: {
                store.errorMessage != nil
            }, set: { _ in
                store.errorMessage = nil
            })) {
                Button(L10n.key("common.ok", mode: store.appLanguage), role: .cancel) {}
            } message: {
                Text(store.errorMessage ?? L10n.key("error.unknown", mode: store.appLanguage))
            }
    }

    @ViewBuilder
    private var rootLayout: some View {
#if os(iOS)
        VStack(spacing: 0) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            SideMenu(store: store)
        }
#else
        HStack(spacing: 0) {
            SideMenu(store: store)
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
#endif
    }

    @ViewBuilder
    private var content: some View {
        switch store.currentPage {
        case .library:
            LibraryPage(store: store)
        case .bookPlayer:
            BookPlayerPage(store: store, playback: playback)
        case .search:
            SearchPage(store: store)
        case .downloads:
            DownloadsPage(store: store)
        case .settings:
            SettingsPage(store: store)
        }
    }
}
