import SwiftUI
import os

struct ContentView: View {
    let assetRoot: URL
    @State private var port: UInt16 = 0
    @State private var started = false
    private let server: LocalServer
    private let log = Logger(subsystem: "app.ish.iSH", category: "app")

    init(assetRoot: URL) {
        self.assetRoot = assetRoot
        self.server = LocalServer(root: assetRoot)
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if port != 0 {
                WasmWebView(port: port).ignoresSafeArea()
            } else {
                ProgressView("Starting…").tint(.white)
            }
        }
        .onAppear {
            guard !started else { return }
            started = true
            do {
                try server.start()
                port = server.port
                log.notice("[app] assetRoot=\(assetRoot.path, privacy: .public) port=\(port, privacy: .public)")
                verifyHeaders(port: port)
            } catch {
                log.error("[app] server start failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Self-diagnostic: confirm COOP/COEP/CORP are actually on the wire,
    /// independent of WebKit — so a crossOriginIsolated=false result can be
    /// traced to headers-on-wire vs. WebView behavior.
    private func verifyHeaders(port: UInt16) {
        guard let url = URL(string: "http://127.0.0.1:\(port)/index.html") else { return }
        URLSession.shared.dataTask(with: url) { _, response, error in
            if let error = error {
                self.log.error("[diag] loopback GET failed: \(error.localizedDescription, privacy: .public)")
                return
            }
            guard let http = response as? HTTPURLResponse else { return }
            let coop = http.value(forHTTPHeaderField: "Cross-Origin-Opener-Policy") ?? "MISSING"
            let coep = http.value(forHTTPHeaderField: "Cross-Origin-Embedder-Policy") ?? "MISSING"
            let corp = http.value(forHTTPHeaderField: "Cross-Origin-Resource-Policy") ?? "MISSING"
            self.log.notice("[diag] status=\(http.statusCode, privacy: .public) COOP=\(coop, privacy: .public) COEP=\(coep, privacy: .public) CORP=\(corp, privacy: .public)")
        }.resume()
    }
}
