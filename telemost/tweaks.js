// Injected by TelemostTweaks.dylib into every QWebEnginePage at DocumentCreation, main world.
// Anchored on protocol strings and BEM class names, not on minified identifiers,
// so it should survive most Telemost updates.
(() => {
	if (window.__telemostTweaks) return;
	const T = (window.__telemostTweaks = { previewSelectorPatched: 0 });

	// Export-level patches. We hook webpack's __webpack_require__.d so every module
	// export getter goes through wrapGetter; the first time an export resolves to a
	// function, each patch's `match` sees its source and may substitute it.
	const fnToString = Function.prototype.toString;
	const PATCHES = [];

	// 1. URL previews: the messenger bundle gates both fetching and rendering of
	//    link previews on a selector `e => a(e, "url_previews_enabled")` reading
	//    state.config.degradation (a server-side kill switch). Make it `() => false`.
	PATCHES.push({
		match: (src) => src.length < 200 && src.includes('"url_previews_enabled"'),
		replace: () => {
			T.previewSelectorPatched++;
			return () => false;
		},
	});

	// 2. Notifications: every desktop notification is built by one function,
	//    `(state, event) => ({type: NOTIFICATION, data: {chat_id, incomingCallId, forceShow, ...}})`,
	//    whose result is emitted on the "ipc" bus and forwarded to the native side.
	//    For events we drop, return an action type the ipc handler does not know: its
	//    switch has no default branch, so nothing is shown and nothing throws.
	//    Shown: incoming calls, notifications addressed to us, messages that mention
	//    us, and anything from a chat in a folder named in IMPORTANT_FOLDERS.
	const IMPORTANT_FOLDERS = ["important", "важное"];
	const SUPPRESSED = { type: "telemost-tweaks/notification-suppressed" };
	const N = (T.notifications = { shown: 0, suppressed: 0, recent: [] });

	const importantChatIds = (state) => {
		const ids = new Set();
		const byOrgData = state.buckets?.folders?.data || {};
		const meta = state.metastore?.folders?.byOrg;
		for (const org of Object.keys(byOrgData)) {
			for (const f of byOrgData[org]?.custom_folders || []) {
				if (!IMPORTANT_FOLDERS.includes(String(f.name).trim().toLowerCase())) continue;
				const excluded = new Set(f.excluded_chat_ids || []);
				for (const id of f.included_chat_ids || []) if (!excluded.has(id)) ids.add(id);
				// membership the client computed itself, covering included types too
				const m = meta?.get?.(Number(org)) || meta?.get?.(org);
				for (const id of Object.keys(m?.customFolders?.[f.id]?.chats || {})) ids.add(id);
			}
		}
		return ids;
	};

	const decide = (state, ev) => {
		const src = ev?.source;
		if (src === "incoming_call_show") return "call";
		if (src === "notification") return "addressed to me";
		const chatId = ev?.data?.chatId;
		const parent = state.chats?.[chatId]?.threadData?.chatId;
		const important = importantChatIds(state);
		if (important.has(chatId) || (parent && important.has(parent))) return "important folder";
		const mentions = ev?.data?.message?.mentions;
		if (src === "message" && Array.isArray(mentions) && mentions.some((m) => m?.guid === state.authId)) return "mention";
		return null;
	};

	PATCHES.push({
		match: (src) => src.length < 2000 && src.includes("incomingCallId:") && src.includes("forceShow:"),
		replace: (build) => {
			N.hooked = true;
			return function (state, ev) {
				let why = null;
				try {
					why = decide(state, ev);
				} catch (e) {
					why = "filter error, shown: " + e; // fail open rather than lose notifications
				}
				N.recent.push({ at: Date.now(), source: ev?.source, chatId: ev?.data?.chatId, shown: !!why, why });
				if (N.recent.length > 30) N.recent.shift();
				if (!why) {
					N.suppressed++;
					return SUPPRESSED;
				}
				N.shown++;
				return build.apply(this, arguments);
			};
		},
	});
	T.debugNotificationDecision = decide;

	const wrapGetter = (get) => {
		let decided = false;
		let replacement = null;
		return () => {
			if (decided) return replacement || get();
			const v = get();
			if (v === undefined) return v; // binding not initialised yet, decide later
			decided = true;
			if (typeof v === "function") {
				const src = fnToString.call(v);
				const patch = PATCHES.find((p) => p.match(src));
				if (patch) replacement = patch.replace(v);
			}
			return replacement || v;
		};
	};

	const hookRequire = (req) => {
		if (!req || typeof req.d !== "function" || req.d.__tt) return;
		const origD = req.d;
		const d = function (exports, defs) {
			const wrapped = {};
			for (const k in defs) wrapped[k] = wrapGetter(defs[k]);
			return origD.call(this, exports, wrapped);
		};
		d.__tt = true;
		req.d = d;
		T.requireHooked = true;
	};

	// Webpack runtime does `g = self[name] = self[name] || []; g.push = jsonpCallback`.
	// Trap that assignment, grab __webpack_require__ via a fake chunk, hook .d
	// before any entry module executes.
	const installChunkTrap = (name) => {
		const arr = [];
		const nativePush = Array.prototype.push;
		let current = nativePush;
		Object.defineProperty(arr, "push", {
			configurable: true,
			get: () => current,
			set: (fn) => {
				current = fn;
				try {
					fn.call(arr, [["__telemost_tweaks__"], {}, (req) => hookRequire(req)]); // callback runs only for not-yet-installed chunk ids
				} catch (e) {
					T.error = String(e);
				}
			},
		});
		Object.defineProperty(window, name, {
			value: arr,
			writable: true,
			configurable: true,
		});
	};
	installChunkTrap("webpackChunk_yandex_int_messenger");

	// 2. Layout CSS.
	const CSS = `
    /* belt and braces: never show a link preview card even if the hook misses */
    .yamb-url-preview { display: none !important; }

    /* black frame around the app */
    .yamb-root__content_window-frame { padding: 0 !important; }
    .yamb-root__layout { border-radius: 0 !important; }

    /* room for the macOS traffic lights moved into the sidebar header */
    .yamb-sidebar-navigation-header__identity { padding-left: ${window.__TT_LIGHTS_W || 0}px !important; }

    /* chat header: centre it on the sidebar avatar row (y=34), leaving a strip above to drag the window by */
    .yamb-chat-header { padding-top: 10px !important; height: 57px !important; min-height: 57px !important; box-sizing: border-box !important; }

    /* only the avatar, the title/status text and the buttons react to clicks; empty header space is a drag area */
    .yamb-chat-header { pointer-events: none !important; }
    .yamb-chat-header .ui-entity-block-horizontal-layout__left-addon .ui-avatar-orb,
    .yamb-chat-header .ui-entity-block-horizontal-layout__content .ui-text-container,
    .yamb-chat-header .ui-entity-block__right-addon .ui-icon-button { pointer-events: auto !important; }
  `;
	const addStyle = () => {
		const s = document.createElement("style");
		s.id = "telemost-tweaks";
		s.textContent = CSS;
		(document.head || document.documentElement).appendChild(s);
	};
	if (document.documentElement) addStyle();
	else document.addEventListener("DOMContentLoaded", addStyle, { once: true });
})();
