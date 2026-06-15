#if os(iOS)
import SwiftUI
import abPlayerCore
import WebKit
import UIKit
import UniformTypeIdentifiers

struct SettingsPage: View {
    @ObservedObject var store: AppStateStore
    @State private var appearanceMode: AppAppearanceMode = .system
    @State private var languageMode: AppLanguageMode = .system
    @State private var showBookmateOAuthSheet = false
    @State private var bookmateOAuthError = ""
    @State private var showImportPicker = false
    @State private var showExportPicker = false

    var body: some View {
        Form {
            Section {
                Text(L10n.key("settings.theme.title", mode: store.appLanguage))
                    .font(.headline)

                Picker("", selection: $appearanceMode) {
                    Text(L10n.key("settings.theme.system", mode: store.appLanguage)).tag(AppAppearanceMode.system)
                    Text(L10n.key("settings.theme.light", mode: store.appLanguage)).tag(AppAppearanceMode.light)
                    Text(L10n.key("settings.theme.dark", mode: store.appLanguage)).tag(AppAppearanceMode.dark)
                }
                .pickerStyle(.segmented)
                .onChange(of: appearanceMode) { mode in
                    Task { await store.setAppearanceMode(mode) }
                }
            }

            Section {
                Text(L10n.key("settings.language.title", mode: store.appLanguage))
                    .font(.headline)

                Picker("", selection: $languageMode) {
                    Text(L10n.key("settings.language.system", mode: store.appLanguage)).tag(AppLanguageMode.system)
                    Text(L10n.key("settings.language.ru", mode: store.appLanguage)).tag(AppLanguageMode.ru)
                    Text(L10n.key("settings.language.en", mode: store.appLanguage)).tag(AppLanguageMode.en)
                }
                .pickerStyle(.segmented)
                .onChange(of: languageMode) { mode in
                    Task { await store.setAppLanguage(mode) }
                }
            }

            Section {
                Text(L10n.key("settings.download_destination.title", mode: store.appLanguage))
                    .font(.headline)
                Text(store.downloadDirectoryPath.isEmpty
                     ? L10n.key("settings.download_destination.not_selected", mode: store.appLanguage)
                     : store.downloadDirectoryPath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            Section {
                Text(L10n.key("settings.library_state.title", mode: store.appLanguage))
                    .font(.headline)

                Button(L10n.key("settings.library_state.export", mode: store.appLanguage)) {
                    showExportPicker = true
                }
                Button(L10n.key("settings.library_state.import", mode: store.appLanguage)) {
                    showImportPicker = true
                }

                Text(L10n.key("settings.library_state.description", mode: store.appLanguage))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Text(L10n.key("settings.bookmate_auth.title", mode: store.appLanguage))
                    .font(.headline)

                Button(store.isBookmateAuthenticated()
                    ? L10n.key("settings.bookmate_auth.logout", mode: store.appLanguage)
                    : L10n.key("settings.bookmate_auth.login", mode: store.appLanguage)
                ) {
                    if store.isBookmateAuthenticated() {
                        Task { await store.clearBookmateAuthToken() }
                    } else {
                        bookmateOAuthError = ""
                        showBookmateOAuthSheet = true
                    }
                }
                .buttonStyle(.borderedProminent)

                if !bookmateOAuthError.isEmpty {
                    Text(bookmateOAuthError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                Text(L10n.key("settings.bookmate_auth.description", mode: store.appLanguage))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .task {
            await store.loadSettings()
            appearanceMode = store.appearanceMode
            languageMode = store.appLanguage
        }
        .onChange(of: store.appearanceMode) { mode in
            appearanceMode = mode
        }
        .onChange(of: store.appLanguage) { mode in
            languageMode = mode
        }
        .sheet(isPresented: $showBookmateOAuthSheet) {
            BookmateOAuthSheet(
                appLanguage: store.appLanguage,
                onToken: { token in
                    showBookmateOAuthSheet = false
                    Task { await store.setBookmateAuthToken(token) }
                },
                onCancel: {
                    showBookmateOAuthSheet = false
                },
                onError: { message in
                    bookmateOAuthError = message
                }
            )
        }
        .fileImporter(isPresented: $showImportPicker, allowedContentTypes: [.json]) { result in
            switch result {
            case let .success(url):
                Task { await store.importLibraryState(from: url) }
            case let .failure(error):
                store.errorMessage = error.localizedDescription
            }
        }
        .fileExporter(
            isPresented: $showExportPicker,
            document: JSONDocument(data: Data()),
            contentType: .json,
            defaultFilename: "abp_library_state"
        ) { result in
            switch result {
            case let .success(url):
                Task { await store.exportLibraryState(to: url) }
            case let .failure(error):
                store.errorMessage = error.localizedDescription
            }
        }
    }
}

private struct JSONDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }

    var data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

private struct BookmateOAuthSheet: View {
    private static let clientID = "0f1dbf67ec9e4de898c176178eaf1eaf"
    private static let redirectHost = "ya4483e97bad6e486e9822973109d14d05.oauth.yandex.ru"

    let appLanguage: AppLanguageMode
    let onToken: (String) -> Void
    let onCancel: () -> Void
    let onError: (String) -> Void

    private var oauthURL: URL {
        var components = URLComponents(string: "https://oauth.yandex.ru/authorize")
        components?.queryItems = [
            URLQueryItem(name: "response_type", value: "token"),
            URLQueryItem(name: "client_id", value: Self.clientID),
            URLQueryItem(name: "force_confirm", value: "yes"),
            URLQueryItem(name: "redirect_uri", value: "https://\(Self.redirectHost)/")
        ]
        return components?.url ?? URL(string: "https://oauth.yandex.ru")!
    }

    var body: some View {
        NavigationStack {
            BookmateOAuthWebView(
                authorizationURL: oauthURL,
                redirectHost: Self.redirectHost,
                appLanguage: appLanguage,
                onToken: onToken,
                onError: onError
            )
            .navigationTitle(L10n.key("settings.oauth.title", mode: appLanguage))
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(L10n.key("common.cancel", mode: appLanguage)) {
                        onCancel()
                    }
                }
            }
        }
    }
}

private struct BookmateOAuthWebView: UIViewRepresentable {
    let authorizationURL: URL
    let redirectHost: String
    let appLanguage: AppLanguageMode
    let onToken: (String) -> Void
    let onError: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(redirectHost: redirectHost, appLanguage: appLanguage, onToken: onToken, onError: onError)
    }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile"
        webView.load(URLRequest(url: authorizationURL))
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        private let redirectHost: String
        private let appLanguage: AppLanguageMode
        private let onToken: (String) -> Void
        private let onError: (String) -> Void

        init(redirectHost: String, appLanguage: AppLanguageMode, onToken: @escaping (String) -> Void, onError: @escaping (String) -> Void) {
            self.redirectHost = redirectHost
            self.appLanguage = appLanguage
            self.onToken = onToken
            self.onError = onError
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
            if let url = navigationAction.request.url {
                if let token = extractAccessToken(from: url) {
                    onToken(token)
                    decisionHandler(.cancel)
                    return
                }

                if url.host == redirectHost,
                   (url.path == "/" || url.path.isEmpty),
                   URLComponents(url: url, resolvingAgainstBaseURL: false)?.fragment == nil {
                    onError(L10n.key("settings.oauth.missing_token", mode: appLanguage))
                }
            }
            decisionHandler(.allow)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard let url = webView.url else { return }
            if let token = extractAccessToken(from: url) {
                onToken(token)
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            onError(error.localizedDescription)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            onError(error.localizedDescription)
        }

        private func extractAccessToken(from url: URL) -> String? {
            guard let fragment = URLComponents(url: url, resolvingAgainstBaseURL: false)?.fragment, !fragment.isEmpty else {
                return nil
            }

            for pair in fragment.split(separator: "&") {
                let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
                guard parts.count == 2 else { continue }
                if parts[0] == "access_token" {
                    let decoded = parts[1].removingPercentEncoding ?? parts[1]
                    if !decoded.isEmpty {
                        return decoded
                    }
                }
            }
            return nil
        }
    }
}
#endif
