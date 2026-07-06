import SwiftUI
import WebKit
import UIKit
import os

/// Full-screen WKWebView that loads the WebVM page from the loopback server.
/// Stock WKWebViewConfiguration — crossOriginIsolated and the WASM JIT come for
/// free inside WebKit; the only additions are a console->os_log bridge so the
/// boot can be observed from native logs.
struct WasmWebView: UIViewRepresentable {
    let port: UInt16
    var controlUrl: String? = nil
    var authKey: String? = nil

    func makeCoordinator() -> Coordinator { Coordinator() }

    /// Build the URL fragment network.js parses (it reads `location.hash` as
    /// URLSearchParams). Percent-encode each value down to unreserved chars so
    /// ':' '/' '&' '=' '+' in URLs/keys survive intact through the &-split.
    static func fragment(controlUrl: String?, authKey: String?) -> String {
        let unreserved = CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        func enc(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: unreserved) ?? s }
        var parts: [String] = []
        if let k = authKey { parts.append("authKey=" + enc(k)) }
        if let c = controlUrl { parts.append("controlUrl=" + enc(c)) }
        return parts.isEmpty ? "" : "#" + parts.joined(separator: "&")
    }

    func makeUIView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.userContentController.add(context.coordinator, name: "nativeLog")
        // Paste bridge: WKWebView/iOS Safari only honors navigator.clipboard.readText()
        // from a trusted system-paste gesture, not a scripted button tap — so a visible
        // "Paste" button reads UIPasteboard directly instead.
        cfg.userContentController.add(context.coordinator, name: "nativePaste")
        // Copy bridge: navigator.clipboard.writeText() likewise needs a user gesture in
        // WKWebView. The OSC 52 handler (guest `yank`) fires from terminal output, not a
        // gesture, so it writes to UIPasteboard directly through this instead.
        cfg.userContentController.add(context.coordinator, name: "nativeCopy")
        cfg.userContentController.addUserScript(
            WKUserScript(source: Coordinator.consoleBridge,
                         injectionTime: .atDocumentStart,
                         forMainFrameOnly: false))

        let webView = WKWebView(frame: .zero, configuration: cfg)
        webView.navigationDelegate = context.coordinator
        // WKWebView wraps its content in its own native UIScrollView, independent
        // of CSS overflow — its default pan/bounce drags the ENTIRE rendered
        // surface (nav header included, since that's a native scrollView offset,
        // not document-level CSS scrolling), which fights xterm.js's own
        // JS-driven terminal scroll and our touch-selection bridge. Disable it so
        // touch/drag gestures are handled exclusively by the web content's own
        // JS, matching a native-app viewport rather than a scrollable page.
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.bounces = false
        #if DEBUG
        webView.isInspectable = true
        #endif
        let frag = Self.fragment(controlUrl: controlUrl, authKey: authKey)
        let url = URL(string: "http://127.0.0.1:\(port)/index.html\(frag)")!
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        private let log = Logger(subsystem: "app.ish.iSH.KTGSS9PB3A", category: "webconsole")

        /// Injected at document start: forwards console.* + errors to native,
        /// reports the cross-origin-isolation env immediately, then ticks for
        /// ~30s sampling crossOriginIsolated and the terminal's text so a boot
        /// to a shell prompt is visible in os_log.
        static let consoleBridge = #"""
        (function () {
          function ser(a) {
            try { return (typeof a === 'object') ? JSON.stringify(a) : String(a); }
            catch (e) { return String(a); }
          }
          function send(level, parts) {
            try {
              window.webkit.messageHandlers.nativeLog.postMessage({ level: level, msg: parts.join(' ') });
            } catch (e) {}
          }
          ['log', 'info', 'warn', 'error', 'debug'].forEach(function (k) {
            var orig = console[k] ? console[k].bind(console) : function () {};
            console[k] = function () {
              send(k, Array.prototype.slice.call(arguments).map(ser));
              orig.apply(console, arguments);
            };
          });
          window.addEventListener('error', function (e) {
            send('error', ['window.onerror', e.message, '@', (e.filename || '') + ':' + (e.lineno || '')]);
          });
          window.addEventListener('unhandledrejection', function (e) {
            send('error', ['unhandledrejection', ser(e.reason)]);
          });
          function env() {
            return 'crossOriginIsolated=' + self.crossOriginIsolated +
                   ' SAB=' + (typeof SharedArrayBuffer !== 'undefined') +
                   ' WASM=' + (typeof WebAssembly !== 'undefined') +
                   ' cores=' + (navigator.hardwareConcurrency || '?');
          }
          send('log', ['[ENV]', env(),
            'hash{controlUrl:' + location.hash.includes('controlUrl') +
            ',authKey:' + location.hash.includes('authKey') + '}']);
          var ticks = 0;
          var iv = setInterval(function () {
            ticks++;
            var term = document.querySelector('.xterm-rows') ||
                       document.querySelector('.xterm') ||
                       document.querySelector('.terminal');
            var txt = term ? (term.innerText || term.textContent || '').replace(/\s+/g, ' ').trim().slice(0, 240)
                           : '(no terminal yet)';
            send('log', ['[TICK ' + ticks + ']', env(), '| term:', txt]);
            if (ticks >= 12) clearInterval(iv);
          }, 2500);
        })();
        """#

        func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
            if message.name == "nativePaste" {
                let text = UIPasteboard.general.string ?? ""
                let encoded = (try? JSONEncoder().encode(text)).flatMap { String(data: $0, encoding: .utf8) } ?? "\"\""
                message.webView?.evaluateJavaScript("window.__webvmPaste && window.__webvmPaste(\(encoded))")
                return
            }
            if message.name == "nativeCopy" {
                if let text = message.body as? String {
                    UIPasteboard.general.string = text
                }
                return
            }
            guard message.name == "nativeLog",
                  let body = message.body as? [String: Any],
                  let text = body["msg"] as? String else { return }
            let level = (body["level"] as? String) ?? "log"
            switch level {
            case "error": log.error("[web] \(text, privacy: .public)")
            case "warn":  log.warning("[web] \(text, privacy: .public)")
            default:      log.notice("[web] \(text, privacy: .public)")
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            log.notice("[nav] didFinish \(webView.url?.absoluteString ?? "?", privacy: .public)")
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            log.error("[nav] didFail \(error.localizedDescription, privacy: .public)")
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            log.error("[nav] didFailProvisional \(error.localizedDescription, privacy: .public)")
        }
    }
}
