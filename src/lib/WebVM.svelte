<script>
	import { onMount, tick } from 'svelte';
	import { get } from 'svelte/store';
	import Nav from 'labs/packages/global-navbar/src/Nav.svelte';
	import SideBar from '$lib/SideBar.svelte';
	import '$lib/global.css';
	import '@xterm/xterm/css/xterm.css'
	import '@fortawesome/fontawesome-free/css/all.min.css'
	import { networkInterface, startLogin } from '$lib/network.js'
	import { WebVMRawSocketTransport } from '$lib/net/webvm-net-transport.js'
	import { cpuActivity, diskActivity, cpuPercentage, diskLatency } from '$lib/activities.js'
	import { introMessage, errorMessage, unexpectedErrorMessage } from '$lib/messages.js'
	import { displayConfig, handleToolImpl } from '$lib/anthropic.js'
	import { tryPlausible } from '$lib/plausible.js'

	export let configObj = null;
	export let processCallback = null;
	export let cacheId = null;
	export let cpuActivityEvents = [];
	export let diskLatencies = [];
	export let activityEventsInterval = 0;

	var term = null;
	var cx = null;
	var fitAddon = null;
	var cxReadFunc = null;
	var blockCache = null;
	var processCount = 0;
	var curVT = 0;
	var sideBarPinned = false;
	function writeData(buf, vt)
	{
		if(vt != 1)
			return;
		term.write(new Uint8Array(buf));
	}
	function readData(str)
	{
		if(cxReadFunc == null)
			return;
		for(var i=0;i<str.length;i++)
			cxReadFunc(str.charCodeAt(i));
	}
	function printMessage(msg)
	{
		for(var i=0;i<msg.length;i++)
			term.write(msg[i] + "\n");
	}
	function expireEvents(list, curTime, limitTime)
	{
		while(list.length > 1)
		{
			if(list[1].t < limitTime)
			{
				list.shift();
			}
			else
			{
				break;
			}
		}
	}
	function cleanupEvents()
	{
		var curTime = Date.now();
		var limitTime = curTime - 10000;
		expireEvents(cpuActivityEvents, curTime, limitTime);
		computeCpuActivity(curTime, limitTime);
		if(cpuActivityEvents.length == 0)
		{
			clearInterval(activityEventsInterval);
			activityEventsInterval = 0;
		}
	}
	function computeCpuActivity(curTime, limitTime)
	{
		var totalActiveTime = 0;
		var lastActiveTime = limitTime;
		var lastWasActive = false;
		for(var i=0;i<cpuActivityEvents.length;i++)
		{
			var e = cpuActivityEvents[i];
			// NOTE: The first event could be before the limit,
			//       we need at least one event to correctly mark
			//       active time when there is long time under load
			var eTime = e.t;
			if(eTime < limitTime)
				eTime = limitTime;
			if(e.state == "ready")
			{
				// Inactive state, add the time from lastActiveTime
				totalActiveTime += (eTime - lastActiveTime);
				lastWasActive = false;
			}
			else
			{
				// Active state
				lastActiveTime = eTime;
				lastWasActive = true;
			}
		}
		// Add the last interval if needed
		if(lastWasActive)
		{
			totalActiveTime += (curTime - lastActiveTime);
		}
		cpuPercentage.set(Math.ceil((totalActiveTime / 10000) * 100));
	}
	function hddCallback(state)
	{
		diskActivity.set(state != "ready");
	}
	function latencyCallback(latency)
	{
		diskLatencies.push(latency);
		if(diskLatencies.length > 30)
			diskLatencies.shift();
		// Average the latency over at most 30 blocks
		var total = 0;
		for(var i=0;i<diskLatencies.length;i++)
			total += diskLatencies[i];
		var avg = total / diskLatencies.length;
		diskLatency.set(Math.ceil(avg));
	}
	function cpuCallback(state)
	{
		cpuActivity.set(state != "ready");
		var curTime = Date.now();
		var limitTime = curTime - 10000;
		expireEvents(cpuActivityEvents, curTime, limitTime);
		cpuActivityEvents.push({t: curTime, state: state});
		computeCpuActivity(curTime, limitTime);
		// Start an interval timer to cleanup old samples when no further activity is received
		if(activityEventsInterval != 0)
			clearInterval(activityEventsInterval);
		activityEventsInterval = setInterval(cleanupEvents, 2000);
	}
	function computeXTermFontSize()
	{
		return parseInt(getComputedStyle(document.body).fontSize);
	}
	function setScreenSize(display)
	{
		var internalMult = 1.0;
		var displayWidth = display.offsetWidth;
		var displayHeight = display.offsetHeight;
		var minWidth = 1024;
		var minHeight = 768;
		if(displayWidth < minWidth)
			internalMult = minWidth / displayWidth;
		if(displayHeight < minHeight)
			internalMult = Math.max(internalMult, minHeight / displayHeight);
		var internalWidth = Math.floor(displayWidth * internalMult);
		var internalHeight = Math.floor(displayHeight * internalMult);
		cx.setKmsCanvas(display, internalWidth, internalHeight);
		// Compute the size to be used for AI screenshots
		var screenshotMult = 1.0;
		var maxWidth = 1024;
		var maxHeight = 768;
		if(internalWidth > maxWidth)
			screenshotMult = maxWidth / internalWidth;
		if(internalHeight > maxHeight)
			screenshotMult = Math.min(screenshotMult, maxHeight / internalHeight);
		var screenshotWidth = Math.floor(internalWidth * screenshotMult);
		var screenshotHeight = Math.floor(internalHeight * screenshotMult);
		// Track the state of the mouse as requested by the AI, to avoid losing the position due to user movement
		displayConfig.set({width: screenshotWidth, height: screenshotHeight, mouseMult: internalMult * screenshotMult});
	}
	var curInnerWidth = 0;
	var curInnerHeight = 0;
	function handleResize()
	{
		// Avoid spurious resize events caused by the soft keyboard
		if(curInnerWidth == window.innerWidth && curInnerHeight == window.innerHeight)
			return;
		curInnerWidth = window.innerWidth;
		curInnerHeight = window.innerHeight;
		triggerResize();
	}
	function triggerResize()
	{
		term.options.fontSize = computeXTermFontSize();
		fitAddon.fit();
		const display = document.getElementById("display");
		if(display)
			setScreenSize(display);
	}
	// OSC 52 (guest-initiated clipboard write, e.g. `vim` yank or a shell
	// script doing `printf '\e]52;c;%s\a' "$(base64 <<<"$1")"`) is not
	// implemented by xterm.js itself; this is a cheap, independent addition.
	function registerOsc52(term)
	{
		term.parser.registerOscHandler(52, (data) => {
			try
			{
				const b64 = data.split(";")[1] || "";
				navigator.clipboard.writeText(atob(b64)).catch(() => {});
			}
			catch(e) {}
			return true;
		});
	}
	// Touch-based text selection: xterm.js's CSS sets user-select:none and its
	// SelectionService only responds to real mousedown/mousemove/mouseup, so a
	// long-press arms selection mode and re-dispatches touchmove as synthetic
	// mouse events. Registered with {capture:true} because xterm.js's own
	// touchstart/touchmove listeners (scroll-by-drag, on a descendant of
	// #console) otherwise fire first on every bubble-phase event and would
	// scroll the buffer out from under an in-progress selection.
	function initTouchSelection(term)
	{
		if(!('ontouchstart' in window || navigator.maxTouchPoints > 0))
			return;
		const consoleDiv = document.getElementById("console");
		const LONG_PRESS_MS = 450;
		const MOVE_CANCEL_PX = 10;
		let pressTimer = null, armed = false, startX = 0, startY = 0, copyBtn = null;

		function dispatchMouse(type, touch)
		{
			const target = document.elementFromPoint(touch.clientX, touch.clientY) || consoleDiv;
			target.dispatchEvent(new MouseEvent(type, {
				bubbles: true, cancelable: true, composed: true,
				button: 0, buttons: type === "mouseup" ? 0 : 1,
				// xterm.js's SelectionService checks e.detail (1/2/3 = single/
				// double/triple click) to pick _handleSingleClick vs. double/triple;
				// a synthetic MouseEvent defaults detail to 0, which matches none
				// of those branches and silently no-ops (no selectionStart is ever
				// set). Force 1 (single-click / start-drag) on every dispatch.
				detail: 1,
				clientX: touch.clientX, clientY: touch.clientY
			}));
		}
		function hideCopyButton() { if(copyBtn) { copyBtn.remove(); copyBtn = null; } }
		function showCopyButton(touch)
		{
			hideCopyButton();
			copyBtn = document.createElement("button");
			copyBtn.className = "xterm-copy-btn";
			copyBtn.textContent = "Copy";
			copyBtn.style.left = touch.clientX + "px";
			copyBtn.style.top = Math.max(touch.clientY - 44, 4) + "px";
			copyBtn.addEventListener("click", (e) => {
				e.preventDefault(); e.stopPropagation();
				const text = term.getSelection();
				if(text)
					navigator.clipboard.writeText(text).catch(() => {});
				hideCopyButton();
			});
			document.body.appendChild(copyBtn);
		}

		consoleDiv.addEventListener("touchstart", (e) => {
			if(e.touches.length !== 1) return;
			const touch = e.touches[0];
			startX = touch.clientX; startY = touch.clientY; armed = false;
			hideCopyButton();
			clearTimeout(pressTimer);
			pressTimer = setTimeout(() => { armed = true; dispatchMouse("mousedown", touch); }, LONG_PRESS_MS);
		}, {capture: true, passive: true});

		consoleDiv.addEventListener("touchmove", (e) => {
			const touch = e.touches[0];
			if(!armed)
			{
				if(Math.abs(touch.clientX - startX) > MOVE_CANCEL_PX || Math.abs(touch.clientY - startY) > MOVE_CANCEL_PX)
					clearTimeout(pressTimer); // let xterm's own scroll handler own this gesture
				return;
			}
			e.preventDefault(); e.stopPropagation();
			dispatchMouse("mousemove", touch);
		}, {capture: true, passive: false});

		consoleDiv.addEventListener("touchend", (e) => {
			clearTimeout(pressTimer);
			if(armed)
			{
				dispatchMouse("mouseup", e.changedTouches[0]);
				if(term.hasSelection())
					showCopyButton(e.changedTouches[0]);
				armed = false;
			}
		}, {capture: true, passive: true});
	}
	// Native paste: WKWebView/iOS Safari only grants navigator.clipboard.readText()
	// during a trusted system-paste gesture, not a scripted button click, so the
	// button posts to a native UIPasteboard bridge (ios/App/WasmWebView.swift)
	// instead; outside WKWebView (desktop, Playwright) it falls back to the
	// standard Clipboard API. Assigned onto window only from initTerminal()
	// (client-only, via onMount) — this file's <script> body also runs during
	// SvelteKit's SSR prerender, where `window` does not exist.
	function webvmPaste(text)
	{
		term.paste(text);
		term.focus();
	}
	function handlePasteButton()
	{
		if(window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.nativePaste)
		{
			window.webkit.messageHandlers.nativePaste.postMessage(null);
		}
		else
		{
			navigator.clipboard.readText().then(text => { term.paste(text); term.focus(); }).catch(e => console.log("paste failed: " + e));
		}
	}
	const isTouchDevice = typeof window !== 'undefined' && ('ontouchstart' in window || navigator.maxTouchPoints > 0);
	async function initTerminal()
	{
		const { Terminal } = await import('@xterm/xterm');
		const { FitAddon } = await import('@xterm/addon-fit');
		const { WebLinksAddon } = await import('@xterm/addon-web-links');
		term = new Terminal({cursorBlink:true, convertEol:true, fontFamily:"monospace", fontWeight: 400, fontWeightBold: 700, fontSize: computeXTermFontSize()});
		fitAddon = new FitAddon();
		term.loadAddon(fitAddon);
		var linkAddon = new WebLinksAddon();
		term.loadAddon(linkAddon);
		registerOsc52(term);
		const consoleDiv = document.getElementById("console");
		term.open(consoleDiv);
		term.scrollToTop();
		fitAddon.fit();
		window.addEventListener("resize", handleResize);
		term.focus();
		term.onData(readData);
		initTouchSelection(term);
		window.__webvmPaste = webvmPaste;
		// Avoid undesired default DnD handling
		function preventDefaults (e) {
			e.preventDefault()
			e.stopPropagation()
		}
		consoleDiv.addEventListener("dragover", preventDefaults, false);
		consoleDiv.addEventListener("dragenter", preventDefaults, false);
		consoleDiv.addEventListener("dragleave", preventDefaults, false);
		consoleDiv.addEventListener("drop", preventDefaults, false);
		curInnerWidth = window.innerWidth;
		curInnerHeight = window.innerHeight;
		if(configObj.printIntro)
			printMessage(introMessage);
		try
		{
			await initCheerpX();
		}
		catch(e)
		{
			printMessage(unexpectedErrorMessage);
			printMessage([e.toString()]);
			return;
		}
	}
	function handleActivateConsole(vt)
	{
		if(curVT == vt)
			return;
		curVT = vt;
		if(vt != 7)
			return;
		// Raise the display to the foreground
		const display = document.getElementById("display");
		display.parentElement.style.zIndex = 5;
		tryPlausible("Display activated");
	}
	function handleProcessCreated()
	{
		processCount++;
		if(processCallback)
			processCallback(processCount);
	}
	async function initCheerpX()
	{
		const CheerpX = await import('@leaningtech/cheerpx');
		var blockDevice = null;
		switch(configObj.diskImageType)
		{
			case "cloud":
				try
				{
					blockDevice = await CheerpX.CloudDevice.create(configObj.diskImageUrl);
				}
				catch(e)
				{
					// Report the failure and try again with plain HTTP
					var wssProtocol = "wss:";
					if(configObj.diskImageUrl.startsWith(wssProtocol))
					{
						// WebSocket protocol failed, try agin using plain HTTP
						tryPlausible("WS Disk failure");
						blockDevice = await CheerpX.CloudDevice.create("https:" + configObj.diskImageUrl.substr(wssProtocol.length));
					}
					else
					{
						// No other recovery option
						throw e;
					}
				}
				break;
			case "bytes":
				blockDevice = await CheerpX.HttpBytesDevice.create(configObj.diskImageUrl);
				break;
			case "github":
				blockDevice = await CheerpX.GitHubDevice.create(configObj.diskImageUrl);
				break;
			default:
				throw new Error("Unrecognized device type");
		}
		blockCache = await CheerpX.IDBDevice.create(cacheId);
		var overlayDevice = await CheerpX.OverlayDevice.create(blockDevice, blockCache);
		var webDevice = await CheerpX.WebDevice.create("");
		var documentsDevice = await CheerpX.WebDevice.create("documents");
		var dataDevice = await CheerpX.DataDevice.create();
		var mountPoints = [
			// The root filesystem, as an Ext2 image
			{type:"ext2", dev:overlayDevice, path:"/"},
			// Access to files on the Web server, relative to the current page
			{type:"dir", dev:webDevice, path:"/web"},
			// Access to read-only data coming from JavaScript
			{type:"dir", dev:dataDevice, path:"/data"},
			// Automatically created device files
			{type:"devs", path:"/dev"},
			// Pseudo-terminals
			{type:"devpts", path:"/dev/pts"},
			// The Linux 'proc' filesystem which provides information about running processes
			{type:"proc", path:"/proc"},
			// The Linux 'sysfs' filesystem which is used to enumerate emulated devices
			{type:"sys", path:"/sys"},
			// Convenient access to sample documents in the user directory
			{type:"dir", dev:documentsDevice, path:"/home/user/documents"}
		];
		try
		{
			// "directsockets": tunnel guest TCP over a loopback WebSocket to the
			// native NWConnection relay (no netmapUpdateCb -> CheerpX DirectSocketsNetwork).
			// Otherwise use the default Tailscale networkInterface.
			const netIf = configObj.netTransport === "directsockets"
				? new WebVMRawSocketTransport(configObj.netWs)
				: networkInterface;
			cx = await CheerpX.Linux.create({mounts: mountPoints, networkInterface: netIf});
		}
		catch(e)
		{
			printMessage(errorMessage);
			printMessage([e.toString()]);
			return;
		}
		cx.registerCallback("cpuActivity", cpuCallback);
		cx.registerCallback("diskActivity", hddCallback);
		cx.registerCallback("diskLatency", latencyCallback);
		cx.registerCallback("processCreated", handleProcessCreated);
		term.scrollToBottom();
		cxReadFunc = cx.setCustomConsole(writeData, term.cols, term.rows);
			// Headless auto-connect: bring up Tailscale shortly AFTER the run loop
			// starts (the UI "Connect" button is otherwise the only trigger, always
			// tapped post-boot; calling networkLogin during boot froze the main thread).
			if(configObj.netTransport !== "directsockets" && networkInterface.authKey)
				setTimeout(() => { try { console.log("[net] tailscale auto-connect"); cx.networkLogin(); } catch(e) { console.warn("[net] networkLogin failed: " + e); } }, 5000);
		const display = document.getElementById("display");
		if(display)
		{
			setScreenSize(display);
			cx.setActivateConsole(handleActivateConsole);
		}
		// Run the command in a loop, in case the user exits
		while (true)
		{
			await cx.run(configObj.cmd, configObj.args, configObj.opts);
		}
	}
	onMount(initTerminal);
	async function handleConnect()
	{
		const w = window.open("login.html", "_blank");
		cx.networkLogin();
		try
		{
			w.location.href = await startLogin();
		}
		catch(e)
		{
			w.close();
			console.warn(e);
		}
	}
	async function handleReset()
	{
		// Be robust before initialization
		if(blockCache == null)
			return;
		await blockCache.reset();
		location.reload();
	}
	async function handleTool(tool)
	{
		return await handleToolImpl(tool, term);
	}
	async function handleSidebarPinChange(event)
	{
		sideBarPinned = event.detail;
		// Make sure the pinning state of reflected in the layout
		await tick();
		// Adjust the layout based on the new sidebar state
		triggerResize();
	}
</script>

<main class="relative w-full h-full">
	<Nav />
	<div class="absolute top-10 bottom-0 left-0 right-0">
		<SideBar on:connect={handleConnect} on:reset={handleReset} handleTool={!configObj.needsDisplay || curVT == 7 ? handleTool : null} on:sidebarPinChange={handleSidebarPinChange}>
			<slot></slot>
		</SideBar>
		{#if configObj.needsDisplay}
			<div class="absolute top-0 bottom-0 {sideBarPinned ? 'left-[23.5rem]' : 'left-14'} right-0">
				<canvas class="w-full h-full cursor-none" id="display"></canvas>
			</div>
		{/if}
		<div class="absolute top-0 bottom-0 {sideBarPinned ? 'left-[23.5rem]' : 'left-14'} right-0 p-1 scrollbar" id="console">
		</div>
		{#if isTouchDevice}
			<button class="xterm-paste-btn" on:click={handlePasteButton} aria-label="Paste">
				<i class="fas fa-paste"></i>
			</button>
		{/if}
	</div>
</main>
