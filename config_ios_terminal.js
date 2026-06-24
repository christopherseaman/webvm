// iOS build config (selected by WEBVM_MODE=ios in vite.config.js).
// The disk image is served locally ("bytes") by the embedded loopback HTTP
// server alongside the web bundle, so every asset is same-origin and the page
// stays cross-origin isolated (required by CheerpX's SharedArrayBuffer).
export const diskImageUrl = "/disk/debian_mini.ext2";
export const diskImageType = "bytes";
// Networking: tunnel guest TCP over a loopback WebSocket to the in-app native
// NWConnection relay (the device IS the gateway — no Tailscale, no extra hops).
// Served by the embedded LocalServer on the fixed port at /net.
export const netTransport = "directsockets";
export const netWs = "ws://127.0.0.1:47821/net";
// Print an introduction message about the technology
export const printIntro = true;
// Is a graphical display needed
export const needsDisplay = false;
// Executable full path (Required)
export const cmd = "/bin/bash";
// Arguments, as an array (Required)
// Arguments, as an array (Required)
export const args = ["--login"];
// Optional extra parameters
export const opts = {
	// Environment variables. RES_OPTIONS=use-vc forces the resolver to use TCP
	// (the DirectSockets relay carries TCP; UDP is not yet bridged), so hostname
	// resolution works through the device when /etc/resolv.conf has a nameserver.
	env: ["HOME=/home/user", "TERM=xterm", "USER=user", "SHELL=/bin/bash", "EDITOR=vim", "LANG=en_US.UTF-8", "LC_ALL=C", "RES_OPTIONS=use-vc"],
	// Current working directory
	cwd: "/home/user",
	// User id
	uid: 1000,
	// Group id
	gid: 1000
};
