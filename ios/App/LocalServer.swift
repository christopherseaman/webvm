import Foundation
import os
import Telegraph

/// One Telegraph server bound to 127.0.0.1:<ephemeral>. Serves the bundled
/// WebVM build (and the disk image under /disk) over HTTP with Range/206
/// support, Last-Modified, and COOP/COEP/CORP on every response so the page
/// becomes crossOriginIsolated. 127.0.0.1 over http is a WebKit secure context,
/// so SharedArrayBuffer is available without TLS.
final class LocalServer {
    private let server = Server()
    private let root: URL
    private let log = Logger(subsystem: "app.ish.iSH", category: "server")

    init(root: URL) { self.root = root }

    /// OS-assigned port; valid only after start(). Telegraph 0.40 -> Int.
    var port: UInt16 { UInt16(server.port) }

    func start() throws {
        // Telegraph evaluates routes in registration order; these catch-alls are the only routes.
        server.route(.HEAD, regex: "^/.*$") { [weak self] req in
            self?.handleHead(req) ?? HTTPResponse(.serviceUnavailable)
        }
        server.route(.GET, regex: "^/.*$") { [weak self] req in
            self?.handleGet(req) ?? HTTPResponse(.serviceUnavailable)
        }
        try server.start(port: 0, interface: "127.0.0.1")
        log.notice("started on 127.0.0.1:\(self.port, privacy: .public) root=\(self.root.path, privacy: .public)")
    }

    func stop() { server.stop(immediately: true) }

    // MARK: - Handlers

    private func handleGet(_ request: HTTPRequest) -> HTTPResponse {
        guard let fileURL = resolve(request.uri.path) else { return notFound(request.uri.path) }
        let rangeHeader = request.headers.range
        log.notice("GET \(request.uri.path, privacy: .public) range=\(rangeHeader ?? "-", privacy: .public)")
        if let rangeStr = rangeHeader, let range = parseRange(rangeStr) {
            return rangeResponse(url: fileURL, range: range)
        }
        return fullResponse(url: fileURL)
    }

    private func handleHead(_ request: HTTPRequest) -> HTTPResponse {
        guard let fileURL = resolve(request.uri.path), let total = fileSize(fileURL) else {
            return notFound(request.uri.path)
        }
        log.notice("HEAD \(request.uri.path, privacy: .public) size=\(total, privacy: .public)")
        let resp = HTTPResponse(.ok)
        resp.headers.contentType = mime(for: fileURL)
        resp.headers.acceptRanges = "bytes"
        resp.headers["Content-Length"] = String(total)
        applyLastModified(resp, fileURL)
        COIHeaders.apply(to: resp)
        return resp
    }

    // MARK: - Path resolution + traversal guard

    private func resolve(_ uriPath: String) -> URL? {
        var rel = uriPath
        if rel.hasPrefix("/") { rel.removeFirst() }
        if let q = rel.firstIndex(of: "?") { rel = String(rel[..<q]) }
        if rel.isEmpty { rel = "index.html" }
        if rel.contains("..") { return nil }
        let url = root.appendingPathComponent(rel)
        let canonicalRoot = root.standardized.path
        let canonical = url.standardized.path
        let prefix = canonicalRoot.hasSuffix("/") ? canonicalRoot : canonicalRoot + "/"
        guard canonical == canonicalRoot || canonical.hasPrefix(prefix) else { return nil }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue else { return nil }
        return url
    }

    // MARK: - Responses

    private func fullResponse(url: URL) -> HTTPResponse {
        // mappedIfSafe avoids loading a large .ext2 fully into RAM on a non-ranged GET.
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return notFound(url.lastPathComponent) }
        let resp = HTTPResponse(.ok, body: data)
        resp.headers.contentType = mime(for: url)
        resp.headers.acceptRanges = "bytes"
        applyLastModified(resp, url)
        COIHeaders.apply(to: resp)
        return resp
    }

    private func rangeResponse(url: URL, range: ByteRange) -> HTTPResponse {
        let total = fileSize(url) ?? 0
        guard total > 0, range.start < total else {
            let r = HTTPResponse(.rangeNotSatisfiable)
            r.headers.contentRange = "bytes */\(total)"
            COIHeaders.apply(to: r)
            return r
        }
        let endInclusive = min(range.end ?? (total - 1), total - 1)
        guard endInclusive >= range.start else {
            let r = HTTPResponse(.rangeNotSatisfiable)
            r.headers.contentRange = "bytes */\(total)"
            COIHeaders.apply(to: r)
            return r
        }
        let length = Int(endInclusive - range.start + 1)
        let body: Data
        do {
            let fh = try FileHandle(forReadingFrom: url)
            defer { try? fh.close() }
            try fh.seek(toOffset: range.start)
            body = try fh.read(upToCount: length) ?? Data()
        } catch {
            return notFound(url.lastPathComponent)
        }
        let resp = HTTPResponse(.partialContent, body: body)
        resp.headers.contentType = mime(for: url)
        resp.headers.contentRange = "bytes \(range.start)-\(endInclusive)/\(total)"
        resp.headers.acceptRanges = "bytes"
        applyLastModified(resp, url)
        COIHeaders.apply(to: resp)
        return resp
    }

    private func notFound(_ path: String) -> HTTPResponse {
        log.error("404 \(path, privacy: .public)")
        let r = HTTPResponse(.notFound)
        COIHeaders.apply(to: r)
        return r
    }

    // MARK: - Helpers

    private struct ByteRange { let start: UInt64; let end: UInt64? }

    private func parseRange(_ s: String) -> ByteRange? {
        guard s.hasPrefix("bytes=") else { return nil }
        let parts = s.dropFirst("bytes=".count).split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2, let start = UInt64(parts[0]) else { return nil }
        if parts[1].isEmpty { return ByteRange(start: start, end: nil) }
        guard let end = UInt64(parts[1]) else { return nil }
        return ByteRange(start: start, end: end)
    }

    private func fileSize(_ url: URL) -> UInt64? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        return (attrs[.size] as? NSNumber)?.uint64Value
    }

    private func applyLastModified(_ resp: HTTPResponse, _ url: URL) {
        // CheerpX's HttpBytesDevice refuses to initialize without Last-Modified.
        guard let date = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date else { return }
        resp.headers["Last-Modified"] = Self.httpDate.string(from: date)
    }

    private static let httpDate: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "GMT")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        return f
    }()

    private func mime(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "html", "htm": return "text/html; charset=utf-8"
        case "js", "mjs":   return "application/javascript"
        case "css":         return "text/css; charset=utf-8"
        case "wasm":        return "application/wasm"
        case "json":        return "application/json"
        case "svg":         return "image/svg+xml"
        case "png":         return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "ico":         return "image/x-icon"
        case "txt", "md":   return "text/plain; charset=utf-8"
        case "ext2", "img": return "application/octet-stream"
        default:            return "application/octet-stream"
        }
    }
}
