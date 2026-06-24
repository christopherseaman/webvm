import SwiftUI

@main
struct WebVMApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView(assetRoot: Self.assetRoot)
        }
    }

    /// The staged WebVM build is bundled as a folder reference named "webroot"
    /// (preserves sub-paths for JS dynamic imports and /disk/*.ext2).
    static var assetRoot: URL {
        guard let url = Bundle.main.url(forResource: "webroot", withExtension: nil) else {
            fatalError("webroot folder reference missing from app bundle")
        }
        return url
    }
}
