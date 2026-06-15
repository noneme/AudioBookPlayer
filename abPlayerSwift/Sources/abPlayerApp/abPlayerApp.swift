import SwiftUI
import AVFoundation
import abPlayerCore
import ffmpegkit

public enum abPlayerBootstrap {
    public static func configure() {
        FFmpegKitConfig.setLogLevel(-8)
    }
}

public struct abPlayerRootContainerView: View {
    @StateObject private var store = AppStateStore(environment: .production())
    // Owned here, above the `.id(rootIdentity)` boundary, so it survives the
    // view-tree rebuild that happens on appearance/snapshot changes (e.g. when
    // minimizing). Tying the player to a view whose `.id` changes would
    // recreate the AVPlayer and kill background playback.
    @StateObject private var playback = PlaybackController()
    @Environment(\.colorScheme) private var systemColorScheme

    public init() {}

    private var explicitColorScheme: ColorScheme? {
        switch store.appearanceMode {
        case .system:
            return nil
        case .light:
            return .light
        case .dark:
            return .dark
        }
    }

    private var rootIdentity: String {
        switch store.appearanceMode {
        case .system:
            // Force view tree refresh when returning to System mode so macOS/system theme is re-applied.
            return "system-\(systemColorScheme == .dark ? "dark" : "light")"
        case .light:
            return "light"
        case .dark:
            return "dark"
        }
    }

    public var body: some View {
        RootView(store: store, playback: playback)
            .id(rootIdentity)
            .preferredColorScheme(explicitColorScheme)
            .environment(\.locale, L10n.locale(for: store.appLanguage))
            .onAppear {
                store.startup()
            }
    }
}

public struct abPlayerMainApp: App {
    public init() {
        abPlayerBootstrap.configure()
    }

    public var body: some Scene {
        WindowGroup {
            abPlayerRootContainerView()
                .frame(minWidth: 920, minHeight: 560)
        }
#if os(macOS)
        .windowStyle(.hiddenTitleBar)
#endif
    }
}
