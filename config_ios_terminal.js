// iOS build config (selected by WEBVM_MODE=ios in vite.config.js).
// The disk image is served locally ("bytes") by the embedded loopback HTTP
// server alongside the web bundle, so every asset is same-origin and the page
// stays cross-origin isolated (required by CheerpX's SharedArrayBuffer).
export const diskImageUrl = "/disk/debian_mini.ext2";
export const diskImageType = "bytes";
// Networking: no netTransport override here -> falls back to the default
// Tailscale/lwIP networkInterface (src/lib/network.js). CheerpX's DirectSockets
// networkInterface (device-direct, no Tailscale) cannot reliably wake a guest
// recv() for unmodified tools (curl/apt/getent) — an engine limitation, not a
// bug in this app — so general internet goes through Tailscale + an
// admin-approved exit node instead. Tailscale auto-connects on boot
// (WebVM.svelte) using the authKey baked from ios/.network.env at stage time.
// Print an introduction message about the technology
export const printIntro = true;
// Is a graphical display needed
export const needsDisplay = false;
// Executable full path (Required)
export const cmd = "/bin/bash";
// Arguments, as an array (Required)
export const args = ["--login"];
// Optional extra parameters
export const opts = {
	// Environment variables
	env: ["HOME=/home/user", "TERM=xterm", "USER=user", "SHELL=/bin/bash", "EDITOR=vim", "LANG=en_US.UTF-8", "LC_ALL=C"],
	// Current working directory
	cwd: "/home/user",
	// User id
	uid: 1000,
	// Group id
	gid: 1000
};
