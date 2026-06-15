/// swift


import SwiftUI
import abPlayerUI

@main
struct abPlayerApp: App {
    init() {
        abPlayerBootstrap.configure()
    }

    var body: some Scene {
        WindowGroup {
            abPlayerRootContainerView()
        }
    }
}
