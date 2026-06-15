import Foundation
import SwiftUI

@MainActor
private final class CoverImageLoader: ObservableObject {
    private static let imageCache = NSCache<NSString, PlatformImage>()

    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.requestCachePolicy = .returnCacheDataElseLoad
        config.urlCache = URLCache(
            memoryCapacity: 80 * 1024 * 1024,
            diskCapacity: 300 * 1024 * 1024,
            diskPath: "abp_cover_cache"
        )
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 40
        return URLSession(configuration: config)
    }()

    @Published var image: PlatformImage?

    private var task: Task<Void, Never>?
    private var currentURLString: String?

    func load(url: URL?) {
        let urlString = url?.absoluteString
        if currentURLString == urlString {
            return
        }

        task?.cancel()
        currentURLString = urlString

        guard let url else {
            image = nil
            return
        }

        let key = url.absoluteString as NSString
        if let cached = Self.imageCache.object(forKey: key) {
            image = cached
            return
        }

        image = nil

        task = Task {
            var request = URLRequest(url: url)
            request.cachePolicy = .returnCacheDataElseLoad

            do {
                let (data, response) = try await Self.session.data(for: request)
                guard !Task.isCancelled else { return }
                guard let http = response as? HTTPURLResponse,
                      (200 ... 299).contains(http.statusCode),
                      let image = PlatformImage(data: data)
                else {
                    return
                }

                Self.imageCache.setObject(image, forKey: key)
                guard !Task.isCancelled, self.currentURLString == url.absoluteString else { return }
                self.image = image
            } catch {
                return
            }
        }
    }

    deinit {
        task?.cancel()
    }
}

struct RemoteCoverView: View {
    let urlString: String
    let width: CGFloat
    let height: CGFloat
    let cornerRadius: CGFloat

    @StateObject private var loader = CoverImageLoader()

    var body: some View {
        Group {
            if let image = loader.image {
                Image(platformImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: width, height: height)
                    .clipped()
            } else {
                placeholder
            }
        }
        .animation(.easeOut(duration: 0.2), value: loader.image != nil)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        .task(id: urlString) {
            loader.load(url: normalizedURL(from: urlString))
        }
    }

    private var placeholder: some View {
        RoundedRectangle(cornerRadius: cornerRadius)
            .fill(Color.gray.opacity(0.2))
            .frame(width: width, height: height)
            .overlay(
                Image(systemName: "book.closed")
                    .foregroundStyle(.secondary)
            )
    }

    private func normalizedURL(from value: String) -> URL? {
        guard !value.isEmpty else { return nil }
        if value.hasPrefix("//") {
            return URL(string: "https:" + value)
        }
        if let direct = URL(string: value) {
            return direct
        }
        if let encoded = value.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed) {
            return URL(string: encoded)
        }
        return nil
    }
}
