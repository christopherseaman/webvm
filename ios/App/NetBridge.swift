import Foundation
import os
import Network
import Telegraph

// Raw-socket-over-WebSocket relay: the in-WebView CheerpX VM tunnels guest TCP
// connections (via a DirectSockets-shaped networkInterface) over a loopback
// WebSocket; this native side dials each out through the device's own network
// using NWConnection. Ported from w-shell (device-verified on iOS).
//
// Wire frame: op(1) | conn_id(4 LE) | length(4 LE) | payload. One WS binary
// message = one frame. Codec is byte-identical to src/lib/net/frame-codec.js.

private let netLog = Logger(subsystem: "app.ish.iSH.KTGSS9PB3A", category: "net")

// MARK: - Frame codec

enum FrameOp: UInt8 {
    case connect = 0x01, data = 0x02, close = 0x03
    case connectOK = 0x04, connectErr = 0x05
    case listen = 0x06, listenOK = 0x07, accept = 0x08, resolve = 0x09, resolveOK = 0x0A
    case udpOpen = 0x10, udpData = 0x11, udpClose = 0x12
}

/// A UDP datagram with its remote endpoint (UDP_DATA frame body, both directions).
/// Layout: family(1) | addr_len(2 LE) | addr(N) | port(2 LE) | data(...).
struct UdpDatagram { let host: String; let port: UInt16; let data: Data }

struct ConnectPayload {
    enum Family: UInt8 { case ipv4 = 4, ipv6 = 6 }
    enum Proto: UInt8 { case tcp = 6, udp = 17 }
    let family: Family
    let proto: Proto
    let host: String
    let port: UInt16
}

struct Frame {
    let op: FrameOp
    let connID: UInt32
    let payload: Data
}

enum FrameCodecError: Error { case shortHeader, truncated, unknownOp(UInt8), badConnect, badUTF8 }

enum FrameCodec {
    static let headerSize = 9

    static func encode(_ f: Frame) -> Data {
        var out = Data()
        out.reserveCapacity(headerSize + f.payload.count)
        out.append(f.op.rawValue)
        appendU32LE(&out, f.connID)
        appendU32LE(&out, UInt32(f.payload.count))
        out.append(f.payload)
        return out
    }

    static func decode(_ data: Data) throws -> Frame {
        let a = [UInt8](data)
        guard a.count >= headerSize else { throw FrameCodecError.shortHeader }
        guard let op = FrameOp(rawValue: a[0]) else { throw FrameCodecError.unknownOp(a[0]) }
        let connID = u32le(a, 1)
        let length = Int(u32le(a, 5))
        guard a.count == headerSize + length else { throw FrameCodecError.truncated }
        return Frame(op: op, connID: connID, payload: Data(a[headerSize ..< headerSize + length]))
    }

    static func encodeConnect(_ p: ConnectPayload) -> Data {
        let host = Array(p.host.utf8)
        var out = Data()
        out.reserveCapacity(6 + host.count)
        out.append(p.family.rawValue)
        out.append(p.proto.rawValue)
        appendU16LE(&out, UInt16(host.count))
        out.append(contentsOf: host)
        appendU16LE(&out, p.port)
        return out
    }

    static func decodeConnect(_ data: Data) throws -> ConnectPayload {
        let a = [UInt8](data)
        guard a.count >= 4 else { throw FrameCodecError.badConnect }
        guard let family = ConnectPayload.Family(rawValue: a[0]),
              let proto = ConnectPayload.Proto(rawValue: a[1]) else { throw FrameCodecError.badConnect }
        let hostLen = Int(u16le(a, 2))
        let portStart = 4 + hostLen
        guard a.count == portStart + 2 else { throw FrameCodecError.badConnect }
        guard let host = String(bytes: a[4 ..< 4 + hostLen], encoding: .utf8) else { throw FrameCodecError.badUTF8 }
        return ConnectPayload(family: family, proto: proto, host: host, port: u16le(a, portStart))
    }

    static func encodeUdp(_ dg: UdpDatagram) -> Data {
        let host = Array(dg.host.utf8)
        var out = Data()
        out.append(1)  // family marker (unused on receive)
        appendU16LE(&out, UInt16(host.count))
        out.append(contentsOf: host)
        appendU16LE(&out, dg.port)
        out.append(dg.data)
        return out
    }

    static func decodeUdp(_ data: Data) throws -> UdpDatagram {
        let a = [UInt8](data)
        guard a.count >= 5 else { throw FrameCodecError.badConnect }
        let hostLen = Int(u16le(a, 1))
        let portStart = 3 + hostLen
        guard a.count >= portStart + 2 else { throw FrameCodecError.badConnect }
        guard let host = String(bytes: a[3 ..< 3 + hostLen], encoding: .utf8) else { throw FrameCodecError.badUTF8 }
        let port = u16le(a, portStart)
        let datagram = a.count > portStart + 2 ? Data(a[(portStart + 2)...]) : Data()
        return UdpDatagram(host: host, port: port, data: datagram)
    }

    private static func appendU16LE(_ d: inout Data, _ v: UInt16) {
        d.append(UInt8(v & 0xff)); d.append(UInt8((v >> 8) & 0xff))
    }
    private static func appendU32LE(_ d: inout Data, _ v: UInt32) {
        d.append(UInt8(v & 0xff)); d.append(UInt8((v >> 8) & 0xff))
        d.append(UInt8((v >> 16) & 0xff)); d.append(UInt8((v >> 24) & 0xff))
    }
    private static func u16le(_ a: [UInt8], _ i: Int) -> UInt16 { UInt16(a[i]) | (UInt16(a[i + 1]) << 8) }
    private static func u32le(_ a: [UInt8], _ i: Int) -> UInt32 {
        UInt32(a[i]) | (UInt32(a[i + 1]) << 8) | (UInt32(a[i + 2]) << 16) | (UInt32(a[i + 3]) << 24)
    }
}

// MARK: - Connection table (thread-safe id -> NWConnection, cap 256)

final class ConnectionTable {
    static let capacity = 256
    private struct Entry { let connection: NWConnection; var hostSentClose: Bool }
    private var entries: [UInt32: Entry] = [:]
    private let lock = NSLock()

    var count: Int { lock.lock(); defer { lock.unlock() }; return entries.count }

    func insert(id: UInt32, connection: NWConnection) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard entries[id] == nil, entries.count < ConnectionTable.capacity else { return false }
        entries[id] = Entry(connection: connection, hostSentClose: false)
        return true
    }

    func connection(for id: UInt32) -> NWConnection? {
        lock.lock(); defer { lock.unlock() }
        return entries[id]?.connection
    }

    func markHostSentCloseIfNeeded(id: UInt32) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard var e = entries[id], !e.hostSentClose else { return false }
        e.hostSentClose = true; entries[id] = e
        return true
    }

    @discardableResult
    func remove(id: UInt32) -> NWConnection? {
        lock.lock(); defer { lock.unlock() }
        return entries.removeValue(forKey: id)?.connection
    }

    func removeAll() -> [NWConnection] {
        lock.lock(); defer { lock.unlock() }
        let all = entries.values.map { $0.connection }
        entries.removeAll()
        return all
    }
}

// MARK: - NetBridge (frames <-> NWConnection)

final class NetBridge {
    /// Abstract WebSocket the bridge speaks to (Telegraph adapter supplies this).
    protocol Socket: AnyObject {
        func sendBinary(_ data: Data)
        func close()
        var onBinary: ((Data) -> Void)? { get set }
        var onClose: (() -> Void)? { get set }
    }

    private let socket: Socket
    private let table = ConnectionTable()
    // UDP is connectionless: one guest socket (conn_id) may reach many destinations,
    // so keep an NWConnection(.udp) per (conn_id, "host:port").
    private var udpConns: [UInt32: [String: NWConnection]] = [:]
    private let udpLock = NSLock()
    private let workQueue = DispatchQueue(label: "app.ish.iSH.netbridge.work", attributes: .concurrent)
    private let sendQueue = DispatchQueue(label: "app.ish.iSH.netbridge.send")

    init(socket: Socket) {
        self.socket = socket
        socket.onBinary = { [weak self] data in self?.handleIncoming(data) }
        socket.onClose = { [weak self] in self?.shutdownAll() }
    }

    deinit { shutdownAll() }

    private func handleIncoming(_ data: Data) {
        let frame: Frame
        do { frame = try FrameCodec.decode(data) } catch {
            netLog.error("frame decode failed (\(data.count)B): \(String(describing: error))")
            return
        }
        switch frame.op {
        case .connect: handleConnect(id: frame.connID, payload: frame.payload)
        case .data:    handleData(id: frame.connID, payload: frame.payload)
        case .close:   handleClose(id: frame.connID)
        case .listen:  sendErr(id: frame.connID, reason: "LISTEN not supported")
        case .resolve: sendErr(id: frame.connID, reason: "RESOLVE not supported")
        case .udpOpen: break  // lazily create the UDP flow on first datagram
        case .udpData: handleUdpData(id: frame.connID, payload: frame.payload)
        case .udpClose: handleUdpClose(id: frame.connID)
        default:       break
        }
    }

    private func handleConnect(id: UInt32, payload: Data) {
        let cp: ConnectPayload
        do { cp = try FrameCodec.decodeConnect(payload) } catch {
            sendErr(id: id, reason: "bad CONNECT payload"); return
        }
        netLog.notice("CONNECT id=\(id) host=\(cp.host, privacy: .public):\(cp.port)")
        if table.count >= ConnectionTable.capacity { sendErr(id: id, reason: "connection cap exceeded"); return }
        guard cp.port != 0, let port = NWEndpoint.Port(rawValue: cp.port) else {
            sendErr(id: id, reason: "invalid port"); return
        }
        guard cp.proto == .tcp else { sendErr(id: id, reason: "UDP not supported in MVP"); return }

        let conn = NWConnection(host: NWEndpoint.Host(cp.host), port: port, using: .tcp)
        conn.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            switch state {
            case .ready:
                netLog.notice("conn id=\(id) READY -> \(cp.host, privacy: .public):\(cp.port)")
                guard self.table.insert(id: id, connection: conn) else {
                    conn.cancel(); self.sendErr(id: id, reason: "duplicate conn_id or cap exceeded"); return
                }
                self.sendOK(id: id)
                self.startReceiving(id: id, connection: conn)
            case .failed(let err):
                netLog.warning("conn id=\(id) FAILED: \(String(describing: err))")
                self.sendErr(id: id, reason: "connect failed: \(err.localizedDescription)")
                conn.cancel()
            case .waiting(let err):
                netLog.warning("conn id=\(id) WAITING: \(String(describing: err))")
                self.sendErr(id: id, reason: "connect waiting: \(err.localizedDescription)")
                conn.cancel()
            default: break
            }
        }
        conn.start(queue: workQueue)
    }

    private func startReceiving(id: UInt32, connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }
            if let data = data, !data.isEmpty { self.sendData(id: id, data: data) }
            if let error = error {
                netLog.warning("conn \(id) receive error: \(String(describing: error))")
                self.teardown(id: id, sendCloseToGuest: true); return
            }
            if isComplete { self.teardown(id: id, sendCloseToGuest: true); return }
            self.startReceiving(id: id, connection: connection)
        }
    }

    private func handleData(id: UInt32, payload: Data) {
        guard let conn = table.connection(for: id) else {
            netLog.warning("DATA id=\(id) \(payload.count)B but no connection in table")
            return
        }
        conn.send(content: payload, completion: .contentProcessed { [weak self] error in
            if let error = error {
                netLog.warning("conn \(id) send error: \(String(describing: error))")
                self?.teardown(id: id, sendCloseToGuest: true)
            }
        })
    }

    private func handleClose(id: UInt32) {
        if let conn = table.remove(id: id) {
            conn.send(content: nil, isComplete: true, completion: .idempotent)
            conn.cancel()
        }
    }

    // MARK: - UDP (datagram bridge — primarily DNS)

    private func handleUdpData(id: UInt32, payload: Data) {
        let dg: UdpDatagram
        do { dg = try FrameCodec.decodeUdp(payload) } catch { return }
        guard let port = NWEndpoint.Port(rawValue: dg.port) else { return }
        let key = "\(dg.host):\(dg.port)"
        udpLock.lock()
        var conns = udpConns[id] ?? [:]
        let existing = conns[key]
        if existing == nil {
            let c = NWConnection(host: NWEndpoint.Host(dg.host), port: port, using: .udp)
            conns[key] = c
            udpConns[id] = conns
            udpLock.unlock()
            netLog.notice("UDP id=\(id) -> \(dg.host, privacy: .public):\(dg.port)")
            c.stateUpdateHandler = { [weak self] state in
                if case .ready = state { self?.startUdpReceiving(id: id, host: dg.host, port: dg.port, connection: c) }
            }
            c.start(queue: workQueue)
            c.send(content: dg.data, completion: .idempotent)
        } else {
            udpLock.unlock()
            existing?.send(content: dg.data, completion: .idempotent)
        }
    }

    private func startUdpReceiving(id: UInt32, host: String, port: UInt16, connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, _, error in
            guard let self = self else { return }
            if let data = data, !data.isEmpty {
                self.sendFrame(.udpData, id: id, payload: FrameCodec.encodeUdp(UdpDatagram(host: host, port: port, data: data)))
            }
            if error == nil { self.startUdpReceiving(id: id, host: host, port: port, connection: connection) }
        }
    }

    private func handleUdpClose(id: UInt32) {
        udpLock.lock()
        let conns = udpConns.removeValue(forKey: id)
        udpLock.unlock()
        conns?.values.forEach { $0.cancel() }
    }

    private func teardown(id: UInt32, sendCloseToGuest: Bool) {
        if sendCloseToGuest && table.markHostSentCloseIfNeeded(id: id) { sendClose(id: id) }
        table.remove(id: id)?.cancel()
    }

    private func sendOK(id: UInt32) { sendFrame(.connectOK, id: id, payload: Data()) }
    private func sendErr(id: UInt32, reason: String) { sendFrame(.connectErr, id: id, payload: Data(reason.utf8)) }
    private func sendData(id: UInt32, data: Data) { sendFrame(.data, id: id, payload: data) }
    private func sendClose(id: UInt32) { sendFrame(.close, id: id, payload: Data()) }

    private func sendFrame(_ op: FrameOp, id: UInt32, payload: Data) {
        let bytes = FrameCodec.encode(Frame(op: op, connID: id, payload: payload))
        sendQueue.async { [weak self] in self?.socket.sendBinary(bytes) }
    }

    private func shutdownAll() {
        for conn in table.removeAll() { conn.cancel() }
        udpLock.lock()
        let udp = udpConns; udpConns.removeAll()
        udpLock.unlock()
        for conns in udp.values { for c in conns.values { c.cancel() } }
    }
}

// MARK: - Telegraph WebSocket adapter

final class NetSocketHandler: NetBridge.Socket {
    private let socket: Telegraph.WebSocket
    var onBinary: ((Data) -> Void)?
    var onClose: (() -> Void)?

    init(socket: Telegraph.WebSocket) { self.socket = socket }

    func sendBinary(_ data: Data) { socket.send(data: data) }
    func close() { socket.close(immediately: false) }

    func deliver(_ message: WebSocketMessage) {
        if case .binary(let data) = message.payload { onBinary?(data) }
    }
    func deliverClose() { onClose?() }
}

// MARK: - WebSocket demux (routes /net -> a NetBridge per socket)

final class WebSocketDemux: ServerWebSocketDelegate {
    private final class Slot {
        let handler: NetSocketHandler
        let bridge: NetBridge
        init(handler: NetSocketHandler, bridge: NetBridge) { self.handler = handler; self.bridge = bridge }
    }
    private var slots: [ObjectIdentifier: Slot] = [:]
    private let lock = NSLock()

    func server(_ server: Server, webSocketDidConnect webSocket: Telegraph.WebSocket, handshake: HTTPRequest) {
        guard handshake.uri.path == "/net" else {
            webSocket.send(message: WebSocketMessage(closeCode: 1008, reason: "unknown endpoint")); return
        }
        let handler = NetSocketHandler(socket: webSocket)
        let bridge = NetBridge(socket: handler)
        lock.lock(); slots[ObjectIdentifier(webSocket)] = Slot(handler: handler, bridge: bridge); lock.unlock()
        netLog.notice("/net WS connected")
    }

    func server(_ server: Server, webSocketDidDisconnect webSocket: Telegraph.WebSocket, error: Error?) {
        lock.lock(); let slot = slots.removeValue(forKey: ObjectIdentifier(webSocket)); lock.unlock()
        slot?.handler.deliverClose()
    }

    func server(_ server: Server, webSocket: Telegraph.WebSocket, didReceiveMessage message: WebSocketMessage) {
        lock.lock(); let slot = slots[ObjectIdentifier(webSocket)]; lock.unlock()
        slot?.handler.deliver(message)
    }
}
