// CheerpX networkInterface shim — fronts a WS to the Swift NetBridge at
// ws://<host>/net and exposes the WHATWG Direct Sockets-shaped object the
// engine consumes. Ported from w-shell (device-verified on iOS).
//
// Contract: Linux.create({ networkInterface: customNet }) — when customNet has
// no netmapUpdateCb — calls customNet.TCPSocket(host, port) for each guest
// connect(). It does NOT reliably call up() first, so we open the WS eagerly
// in the constructor and queue any frames sent before `open` fires.
//
//   TCPSocket return shape:
//       { opened: Promise<{readable, writable, remoteAddress, remotePort,
//                          localAddress, localPort}>,
//         closed: Promise<void>,
//         close:  () => void }
//   readable yields Uint8Array; writable accepts Uint8Array.

import {
  OP,
  FAMILY,
  PROTO,
  encodeFrame,
  decodeFrame,
  encodeConnectPayload,
  encodeUdpPayload,
  decodeUdpPayload,
} from "./frame-codec.js";

const STUB_LOCAL_ADDR = "127.0.0.1";
const STUB_LOCAL_PORT_BASE = 49152;

function notImplementedSocket(reason) {
  return {
    opened: Promise.reject(new Error(reason)),
    closed: Promise.resolve(),
    close: () => {},
  };
}

export class WebVMRawSocketTransport {
  constructor(wsUrl) {
    if (typeof wsUrl !== "string") {
      throw new Error("WebVMRawSocketTransport: wsUrl must be a string");
    }
    this._wsUrl = wsUrl;
    this._ws = null;
    this._nextConnId = 1;
    this._conns = new Map(); // connId -> Conn
    // why: CheerpX does NOT reliably call up() before TCPSocket() in our
    // configuration. Open the WS eagerly at construction; buffer any frames
    // sent before `open` fires.
    this._pendingFrames = [];
    this._open();
  }

  _open() {
    console.log(`[net] eager open WS ${this._wsUrl}`);
    const ws = new WebSocket(this._wsUrl);
    ws.binaryType = "arraybuffer";
    this._ws = ws;
    this._upPromise = new Promise((resolve, reject) => {
      ws.addEventListener("open", () => {
        console.log(`[net] WS open readyState=${ws.readyState} pending=${this._pendingFrames.length}`);
        const queued = this._pendingFrames;
        this._pendingFrames = [];
        for (const bytes of queued) ws.send(bytes);
        resolve();
      }, { once: true });
      ws.addEventListener("error", (e) => {
        console.warn(`[net] WS error opening ${this._wsUrl} readyState=${ws.readyState}`);
        reject(new Error(`WS error opening ${this._wsUrl}`));
      }, { once: true });
    });
    ws.addEventListener("message", (ev) => this._onMessage(ev));
    ws.addEventListener("close", (ev) => {
      console.warn(`[net] WS close code=${ev.code} reason=${ev.reason || "(none)"}`);
      this._onWsClose();
    });
  }

  // Idempotent — CheerpX may or may not invoke this; the constructor already
  // opened the WS. Returns the same opening promise either way.
  up() { return this._upPromise; }

  delete() {
    if (this._ws && this._ws.readyState <= 1) this._ws.close();
    this._ws = null;
    for (const conn of this._conns.values()) conn._teardown(new Error("transport deleted"));
    this._conns.clear();
  }

  TCPSocket(host, port) {
    if (!this._ws) {
      return notImplementedSocket("TCPSocket called before _open()");
    }
    const connId = this._allocConnId();
    const conn = new Conn(this, connId, host, port);
    this._conns.set(connId, conn);
    const family = looksLikeIPv6(host) ? FAMILY.IPV6 : FAMILY.IPV4;
    const payload = encodeConnectPayload({ family, proto: PROTO.TCP, host, port });
    this._send(encodeFrame(OP.CONNECT, connId, payload));
    return conn.publicHandle();
  }

  TCPServerSocket(_host, _opts) {
    return notImplementedSocket("TCPServerSocket: not implemented in MVP (per spec/03)");
  }

  UDPSocket(opts) {
    if (!this._ws) {
      return notImplementedSocket("UDPSocket called before _open()");
    }
    const connId = this._allocConnId();
    const udp = new UdpConn(this, connId, (opts && opts.localPort) || 0);
    this._conns.set(connId, udp);
    this._send(encodeFrame(OP.UDP_OPEN, connId));
    return udp.publicHandle();
  }

  _allocConnId() {
    // why: conn_id 0 is reserved for control-plane (spec/03 §Connection ID allocation).
    let id = this._nextConnId++;
    if (id === 0) id = this._nextConnId++;
    if (this._nextConnId > 0xffffffff) this._nextConnId = 1;
    return id;
  }

  _send(bytes) {
    if (!this._ws) {
      console.warn(`[net] _send DROP (${bytes.byteLength}B) no-ws`);
      return;
    }
    if (this._ws.readyState === 0) {
      // CONNECTING — buffer until open. Cap to prevent unbounded growth if WS
      // never opens.
      if (this._pendingFrames.length >= 1024) {
        console.warn(`[net] _send DROP (${bytes.byteLength}B) pending queue full`);
        return;
      }
      this._pendingFrames.push(bytes);
      return;
    }
    if (this._ws.readyState !== 1) {
      console.warn(`[net] _send DROP (${bytes.byteLength}B) ws.readyState=${this._ws.readyState}`);
      return;
    }
    this._ws.send(bytes);
  }

  _onMessage(ev) {
    const data = ev.data;
    const bytes = data instanceof ArrayBuffer
      ? new Uint8Array(data)
      : data instanceof Uint8Array
      ? data
      : null;
    if (!bytes) {
      console.warn(`[net] _onMessage non-binary ${typeof data}`);
      return;
    }
    let frame;
    try {
      frame = decodeFrame(bytes);
    } catch (err) {
      console.warn(`[net] frame decode failed (${bytes.byteLength}B): ${err && err.message ? err.message : err}`);
      return;
    }
    const conn = this._conns.get(frame.connId);
    if (!conn) {
      console.warn(`[net] dropped frame op=${frame.op} connId=${frame.connId} (no matching connection)`);
      return;
    }
    conn._onFrame(frame);
  }

  _onWsClose() {
    for (const conn of this._conns.values()) conn._teardown(new Error("WS closed"));
    this._conns.clear();
  }
}

class Conn {
  constructor(transport, id, host, port) {
    this._transport = transport;
    this._id = id;
    this._host = host;
    this._port = port;
    this._localPort = STUB_LOCAL_PORT_BASE + (id & 0x3fff);
    this._opened = new Deferred();
    this._closed = new Deferred();
    this._sentClose = false;
    this._readableController = null;
    // why: ReadableStream is constructed eagerly so incoming DATA before
    // the consumer attaches a reader is buffered by the stream's queue.
    this._readable = new ReadableStream({
      start: (c) => { this._readableController = c; },
      cancel: () => this._initiateClose(),
    });
    const self = this;
    this._writable = new WritableStream({
      write(chunk) {
        if (!(chunk instanceof Uint8Array)) {
          chunk = new Uint8Array(chunk);
        }
        // why: spec/03 §Message size limits — guest MUST NOT send DATA payloads >1 MiB.
        const MAX = 1024 * 1024;
        for (let off = 0; off < chunk.byteLength; off += MAX) {
          const slice = chunk.subarray(off, Math.min(off + MAX, chunk.byteLength));
          self._transport._send(encodeFrame(OP.DATA, self._id, slice));
        }
      },
      close() {
        self._initiateClose();
      },
      abort() {
        self._initiateClose();
      },
    });
  }

  publicHandle() {
    return {
      opened: this._opened.promise,
      closed: this._closed.promise,
      close: () => this._initiateClose(),
    };
  }

  _onFrame(frame) {
    if (frame.op === OP.CONNECT_OK) {
      this._opened.resolve({
        readable: this._readable,
        writable: this._writable,
        remoteAddress: this._host,
        remotePort: this._port,
        localAddress: STUB_LOCAL_ADDR,
        localPort: this._localPort,
      });
    } else if (frame.op === OP.CONNECT_ERR) {
      let reason;
      try { reason = new TextDecoder("utf-8").decode(frame.payload); }
      catch { reason = "CONNECT_ERR"; }
      this._opened.reject(new Error(reason || "CONNECT_ERR"));
      this._teardown(new Error(reason || "CONNECT_ERR"));
    } else if (frame.op === OP.DATA) {
      if (this._readableController) {
        try { this._readableController.enqueue(frame.payload); }
        catch { /* stream cancelled */ }
      }
    } else if (frame.op === OP.CLOSE) {
      this._teardown(null);
    }
  }

  _initiateClose() {
    if (this._sentClose) return;
    this._sentClose = true;
    this._transport._send(encodeFrame(OP.CLOSE, this._id));
    // Wait for peer CLOSE before resolving `closed`; if WS dies, _teardown handles it.
  }

  _teardown(err) {
    if (this._readableController) {
      try { this._readableController.close(); } catch {}
      this._readableController = null;
    }
    if (err) this._opened.reject(err);
    this._closed.resolve();
    this._transport._conns.delete(this._id);
  }
}

// WHATWG UDPSocket (bound mode): opened resolves immediately; readable yields
// { data, remoteAddress, remotePort }; writable accepts the same shape.
class UdpConn {
  constructor(transport, id, localPort) {
    this._transport = transport;
    this._id = id;
    this._localPort = localPort || (49152 + (id & 0x3fff));
    this._opened = new Deferred();
    this._closed = new Deferred();
    this._sentClose = false;
    this._readableController = null;
    this._readable = new ReadableStream({
      start: (c) => { this._readableController = c; },
      cancel: () => this._initiateClose(),
    });
    const self = this;
    this._writable = new WritableStream({
      write(msg) {
        if (!msg || msg.remoteAddress == null || msg.remotePort == null) return;
        const data = msg.data instanceof Uint8Array ? msg.data : new Uint8Array(msg.data || 0);
        const family = looksLikeIPv6(msg.remoteAddress) ? FAMILY.IPV6 : FAMILY.IPV4;
        self._transport._send(encodeFrame(OP.UDP_DATA, self._id,
          encodeUdpPayload({ family, host: msg.remoteAddress, port: msg.remotePort, data })));
      },
      close() { self._initiateClose(); },
      abort() { self._initiateClose(); },
    });
    // UDP has no handshake — open immediately.
    this._opened.resolve({
      readable: this._readable,
      writable: this._writable,
      localAddress: "0.0.0.0",
      localPort: this._localPort,
    });
  }

  publicHandle() {
    return {
      opened: this._opened.promise,
      closed: this._closed.promise,
      close: () => this._initiateClose(),
    };
  }

  _onFrame(frame) {
    if (frame.op === OP.UDP_DATA) {
      try {
        const { host, port, data } = decodeUdpPayload(frame.payload);
        if (this._readableController) {
          this._readableController.enqueue({ data, remoteAddress: host, remotePort: port });
        }
      } catch (e) { console.warn(`[net] UDP decode failed conn=${this._id}: ${e}`); }
    } else if (frame.op === OP.UDP_CLOSE) {
      this._teardown();
    }
  }

  _initiateClose() {
    if (this._sentClose) return;
    this._sentClose = true;
    this._transport._send(encodeFrame(OP.UDP_CLOSE, this._id));
    this._teardown();
  }

  _teardown() {
    if (this._readableController) {
      try { this._readableController.close(); } catch {}
      this._readableController = null;
    }
    this._closed.resolve();
    this._transport._conns.delete(this._id);
  }
}

class Deferred {
  constructor() {
    this.promise = new Promise((resolve, reject) => {
      this._resolve = resolve;
      this._reject = reject;
    });
    this._settled = false;
  }
  resolve(v) { if (!this._settled) { this._settled = true; this._resolve(v); } }
  reject(e)  { if (!this._settled) { this._settled = true; this._reject(e); } }
}

function looksLikeIPv6(host) {
  return typeof host === "string" && host.includes(":");
}
