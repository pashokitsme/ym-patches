// Injected by TelemostTweaks.dylib into every QWebEnginePage at DocumentCreation, main world.
// Anchored on protocol strings and BEM class names, not on minified identifiers,
// so it should survive most Telemost updates.
(() => {
	if (window.__telemostTweaks) return;
	const T = (window.__telemostTweaks = { previewSelectorPatched: 0 });

	// 1. URL previews: the messenger bundle gates both fetching and rendering of
	//    link previews on a selector `e => a(e, "url_previews_enabled")` reading
	//    state.config.degradation (a server-side kill switch). We hook webpack's
	//    __webpack_require__.d so that getter yields `() => false` instead.
	const PREVIEW_KEY = '"url_previews_enabled"';
	const fnToString = Function.prototype.toString;
	const alwaysFalse = () => false;

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
				if (src.length < 200 && src.includes(PREVIEW_KEY)) {
					replacement = alwaysFalse;
					T.previewSelectorPatched++;
				}
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
