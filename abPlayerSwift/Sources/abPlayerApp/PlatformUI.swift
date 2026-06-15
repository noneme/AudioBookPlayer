import SwiftUI

#if os(macOS)
import AppKit

typealias PlatformImage = NSImage

extension Image {
    init(platformImage: PlatformImage) {
        self.init(nsImage: platformImage)
    }
}

extension Color {
    static var platformWindowBackground: Color { Color(nsColor: .windowBackgroundColor) }
    static var platformControlBackground: Color { Color(nsColor: .controlBackgroundColor) }
}
#elseif os(iOS)
import UIKit

typealias PlatformImage = UIImage

extension Image {
    init(platformImage: PlatformImage) {
        self.init(uiImage: platformImage)
    }
}

extension Color {
    static var platformWindowBackground: Color { Color(uiColor: .systemBackground) }
    static var platformControlBackground: Color { Color(uiColor: .secondarySystemBackground) }
}
#endif

