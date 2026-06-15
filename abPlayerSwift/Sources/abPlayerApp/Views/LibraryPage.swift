import SwiftUI
import abPlayerCore

struct LibraryPage: View {
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
            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.key("library.title", mode: store.appLanguage))
                    .font(.title2)
                    .bold()

                Picker("", selection: $store.selectedLibrarySection) {
                    Text(L10n.key("library.section.all", mode: store.appLanguage)).tag(LibrarySection.all)
                    Text(L10n.key("library.section.favorites", mode: store.appLanguage)).tag(LibrarySection.favorites)
                    Text(L10n.key("library.section.downloaded", mode: store.appLanguage)).tag(LibrarySection.downloaded)
                    Text(L10n.key("library.section.new", mode: store.appLanguage)).tag(LibrarySection.new)
                    Text(L10n.key("library.section.started", mode: store.appLanguage)).tag(LibrarySection.started)
                    Text(L10n.key("library.section.finished", mode: store.appLanguage)).tag(LibrarySection.finished)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: isCompactPhoneLayout ? .infinity : 620)
            }

            TextField(L10n.key("library.search.placeholder", mode: store.appLanguage), text: $store.libraryQuery)
                .textFieldStyle(.roundedBorder)

            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(store.filteredBooks()) { book in
                        let canDownload = store.canDownload(book: book)
                        let downloadHelp = (book.driver == "Bookmate" && !canDownload)
                            ? L10n.key("bookmate.login_required_download", mode: store.appLanguage)
                            : L10n.key("library.download.help", mode: store.appLanguage)

                        BookCard(book: book, appLanguage: store.appLanguage, onFavorite: {
                            Task { await store.toggleFavorite(bookID: book.id) }
                        }, onDelete: {
                            Task { await store.deleteBookFromLibrary(bookID: book.id) }
                        }, onOpen: {
                            store.openBookPlayer(bookID: book.id)
                        }, onDownload: {
                            Task { await store.queueDownload(book: book) }
                        }, canDownload: canDownload, downloadHelp: downloadHelp, isCompactPhoneLayout: isCompactPhoneLayout)
                    }
                }
            }
        }
        .padding(16)
    }
}

private struct BookCard: View {
    let book: Book
    let appLanguage: AppLanguageMode
    let onFavorite: () -> Void
    let onDelete: () -> Void
    let onOpen: () -> Void
    let onDownload: () -> Void
    let canDownload: Bool
    let downloadHelp: String
    let isCompactPhoneLayout: Bool
    @State private var isDescriptionExpanded = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            RemoteCoverView(
                urlString: book.preview,
                width: isCompactPhoneLayout ? 48 : 56,
                height: isCompactPhoneLayout ? 70 : 82,
                cornerRadius: 8
            )

            VStack(alignment: .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(book.name)
                        .font(.headline)
                        .lineLimit(2)
                    Text("\(book.listeningProgress) \(L10n.key("common.listened", mode: appLanguage)) • \(L10n.key("library.added_prefix", mode: appLanguage)) \(Formatters.addingDate(book.addingDate))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                HStack(spacing: 8) {
                    Button(action: onFavorite) {
                        Image(systemName: book.favorite ? "star.fill" : "star")
                    }
                    .buttonStyle(.borderless)
                    .help(book.favorite ? L10n.key("library.favorite.remove", mode: appLanguage) : L10n.key("library.favorite.add", mode: appLanguage))
                    .accessibilityLabel(book.favorite ? L10n.key("library.favorite.remove", mode: appLanguage) : L10n.key("library.favorite.add", mode: appLanguage))

                    Button(action: onDelete) {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .help(L10n.key("library.delete", mode: appLanguage))
                    .accessibilityLabel(L10n.key("library.delete", mode: appLanguage))

                    Spacer()

                    if book.downloaded {
                        Text(L10n.key("library.downloaded", mode: appLanguage))
                            .font(.caption)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(.green.opacity(0.2), in: Capsule())
                    } else {
                        if isCompactPhoneLayout {
                            Button(action: onDownload) {
                                Image(systemName: "arrow.down.circle")
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(!canDownload)
                            .help(downloadHelp)
                            .accessibilityLabel(L10n.key("library.download", mode: appLanguage))
                        } else {
                            Button(action: onDownload) {
                                Label(L10n.key("library.download", mode: appLanguage), systemImage: "arrow.down.circle")
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(!canDownload)
                            .help(downloadHelp)
                            .accessibilityLabel(L10n.key("library.download", mode: appLanguage))
                        }
                    }
                }

                Text(book.description)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(isDescriptionExpanded ? nil : 2)

                if !book.description.isEmpty {
                    Button(isDescriptionExpanded ? L10n.key("common.hide", mode: appLanguage) : L10n.key("common.more", mode: appLanguage)) {
                        isDescriptionExpanded.toggle()
                    }
                    .font(.caption)
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Label(book.author, systemImage: "person")
                    Label(book.reader.isEmpty ? "-" : book.reader, systemImage: "mic")
                    Label(book.duration, systemImage: "clock")
                    Label(book.displaySeries.isEmpty ? "-" : book.displaySeries, systemImage: "tag")
                    Label(book.driver, systemImage: "network")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.platformControlBackground))
        .contentShape(Rectangle())
        .onTapGesture {
            guard book.downloaded else { return }
            onOpen()
        }
    }
}
