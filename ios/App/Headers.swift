import Foundation
import Telegraph

/// Cross-Origin Isolation headers. Without all three on EVERY response,
/// WKWebView refuses to expose SharedArrayBuffer, which CheerpX requires.
/// This is the entire crossOriginIsolated story — there is NO WKWebView flag.
///
/// require-corp (not credentialless): iOS WKWebView's COEP processing lags
/// Safari and was observed not to honor `credentialless` (crossOriginIsolated
/// stayed false on iPad). require-corp works as long as every cross-origin
/// sub-resource itself sends CORP: cross-origin (the CheerpX CDN does).
enum COIHeaders {
    static let opener = "Cross-Origin-Opener-Policy"
    static let openerValue = "same-origin"

    static let embedder = "Cross-Origin-Embedder-Policy"
    static let embedderValue = "require-corp"

    static let resource = "Cross-Origin-Resource-Policy"
    static let resourceValue = "same-origin"

    /// Apply COOP/COEP/CORP to a Telegraph response. Mutates in place.
    static func apply(to response: HTTPResponse) {
        response.headers[opener] = openerValue
        response.headers[embedder] = embedderValue
        response.headers[resource] = resourceValue
    }
}
