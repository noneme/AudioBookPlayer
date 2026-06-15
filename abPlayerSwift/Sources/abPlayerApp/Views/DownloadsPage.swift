import SwiftUI
import abPlayerCore

struct DownloadsPage: View {
    @ObservedObject var store: AppStateStore
    @State private var ticker: Task<Void, Never>?

#if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
#endif

    private var isCompactPhoneLayout: Bool {
#if os(iOS)
        horizontalSizeClass == .compact
#else
        false
#endif
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.key("downloads.title", mode: store.appLanguage))
                .font(.title2)
                .bold()

            if store.downloads.isEmpty {
                Text(L10n.key("downloads.empty", mode: store.appLanguage))
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(store.downloads) { item in
                            DownloadCard(item: item, appLanguage: store.appLanguage, isCompactPhoneLayout: isCompactPhoneLayout) {
                                Task {
                                    if item.status == .finished {
                                        await store.removeDownloaded(bid: item.bid)
                                    } else {
                                        await store.terminateDownload(bid: item.bid)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            Spacer()
        }
        .padding(16)
        .task {
            await store.loadDownloads()
            ticker?.cancel()
            ticker = Task {
                while !Task.isCancelled {
                    await store.loadDownloads()
                    try? await Task.sleep(nanoseconds: 300_000_000)
                }
            }
        }
        .onDisappear {
            ticker?.cancel()
            ticker = nil
        }
    }
}

private struct DownloadCard: View {
    let item: DownloadEntry
    let appLanguage: AppLanguageMode
    let isCompactPhoneLayout: Bool
    let onTerminate: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if isCompactPhoneLayout {
                VStack(alignment: .leading, spacing: 8) {
                    Text(item.title)
                        .font(.headline)
                        .lineLimit(2)

                    Button {
                        onTerminate()
                    } label: {
                        Text(item.status == .finished ? L10n.key("downloads.delete", mode: appLanguage) : L10n.key("downloads.cancel", mode: appLanguage))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
            } else {
                HStack {
                    Text(item.title)
                        .font(.headline)
                    Spacer()
                    Button {
                        onTerminate()
                    } label: {
                        Text(item.status == .finished ? L10n.key("downloads.delete", mode: appLanguage) : L10n.key("downloads.cancel", mode: appLanguage))
                    }
                }
            }
            Text(L10n.status(item.status, mode: appLanguage))
                .font(.caption)
                .foregroundStyle(.secondary)

            if !item.stage.isEmpty {
                Text(item.stage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if !item.errorMessage.isEmpty {
                Text(item.errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }

            ProgressView(value: item.progressPercent, total: 100)
            Text("\(item.doneSize) / \(item.totalSize)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.platformControlBackground))
    }
}
