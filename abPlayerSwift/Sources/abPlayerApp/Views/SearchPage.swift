import SwiftUI
import abPlayerCore

struct SearchPage: View {
    @ObservedObject var store: AppStateStore

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
            HStack {
                Text(L10n.key("search.title", mode: store.appLanguage))
                    .font(.title2)
                    .bold()
                Spacer()
                if store.isSearching {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            if isCompactPhoneLayout {
                VStack(alignment: .leading, spacing: 8) {
                    TextField(L10n.key("search.placeholder", mode: store.appLanguage), text: $store.searchQuery)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: store.searchQuery) { _ in
                            Task { await store.runSearch(reset: true) }
                        }
                        .onSubmit {
                            Task { await store.runSearch(reset: true) }
                        }

                    Button(L10n.key("search.find", mode: store.appLanguage)) {
                        Task { await store.runSearch(reset: true) }
                    }
                    .buttonStyle(.borderedProminent)
                }
            } else {
                HStack {
                    TextField(L10n.key("search.placeholder", mode: store.appLanguage), text: $store.searchQuery)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: store.searchQuery) { _ in
                            Task { await store.runSearch(reset: true) }
                        }
                        .onSubmit {
                            Task { await store.runSearch(reset: true) }
                        }
                    Button(L10n.key("search.find", mode: store.appLanguage)) {
                        Task { await store.runSearch(reset: true) }
                    }
                    .buttonStyle(.borderedProminent)
                }
            }

            DriverFilterView(store: store)

            if store.searchResults.isEmpty && !store.isSearching {
                Text(L10n.key("search.empty", mode: store.appLanguage))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(store.searchResults) { book in
                        SearchResultCard(book: book, appLanguage: store.appLanguage, isCompactPhoneLayout: isCompactPhoneLayout) {
                            Task { await store.addBook(book) }
                        }
                        .onAppear {
                            Task { await store.loadMoreSearchIfNeeded(currentItem: book) }
                        }
                    }

                    if store.isSearching && !store.searchResults.isEmpty {
                        HStack {
                            Spacer()
                            ProgressView()
                                .controlSize(.small)
                            Spacer()
                        }
                        .padding(.vertical, 8)
                    }
                }
            }
        }
        .padding(16)
    }
}

private struct DriverFilterView: View {
    @ObservedObject var store: AppStateStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.key("search.sources", mode: store.appLanguage))
                .font(.caption)
                .foregroundStyle(.secondary)

            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(store.availableDrivers) { driver in
                        let selected = store.requiredDrivers.contains(driver.name)
                        Button {
                            store.toggleDriver(driver.name)
                            Task { await store.runSearch(reset: true) }
                        } label: {
                            HStack(spacing: 4) {
                                if selected { Image(systemName: "checkmark.circle.fill") }
                                Text(driver.name)
                                if driver.licensed {
                                    Text(L10n.key("search.licensed", mode: store.appLanguage))
                                        .font(.caption2)
                                }
                            }
                            .font(.caption)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(
                                RoundedRectangle(cornerRadius: 12)
                                    .fill(driver.authed ? (selected ? Color.blue.opacity(0.2) : Color.gray.opacity(0.15)) : Color.gray.opacity(0.08))
                            )
                            .foregroundStyle(driver.authed ? .primary : .secondary)
                        }
                        .buttonStyle(.plain)
                        .disabled(!driver.authed)
                    }
                }
            }
        }
    }
}

private struct SearchResultCard: View {
    let book: BookPreview
    let appLanguage: AppLanguageMode
    let isCompactPhoneLayout: Bool
    let onAdd: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            RemoteCoverView(
                urlString: book.preview,
                width: isCompactPhoneLayout ? 48 : 56,
                height: isCompactPhoneLayout ? 70 : 82,
                cornerRadius: 8
            )

            VStack(alignment: .leading, spacing: 6) {
                Text(book.name)
                    .font(.headline)
                    .lineLimit(2)
                VStack(alignment: .leading, spacing: 4) {
                    Label(book.author, systemImage: "person")
                    Label(book.reader.isEmpty ? "-" : book.reader, systemImage: "mic")
                    Label(book.duration, systemImage: "clock")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)

                VStack(alignment: .leading, spacing: 4) {
                    Label(book.displaySeries.isEmpty ? "-" : book.displaySeries, systemImage: "tag")
                    Label(book.driver, systemImage: "network")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }

            Spacer()

            Button(L10n.key("search.add", mode: appLanguage)) {
                onAdd()
            }
            .buttonStyle(.borderedProminent)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.platformControlBackground))
    }
}
