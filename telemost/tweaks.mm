// TelemostTweaks.dylib — loaded into Yandex.Telemost via an added LC_LOAD_DYLIB.
//  * injects tweaks.js into every QWebEnginePage (no link previews, layout CSS)
//  * moves the macOS traffic lights into the window content (transparent, full-size titlebar)
// Log: ~/Library/Logs/TelemostTweaks.log

#import <Cocoa/Cocoa.h>
#import <objc/runtime.h>
#import <UserNotifications/UserNotifications.h>
#include <QtCore/QString>
#include <QtWidgets/QApplication>
#include <QtWidgets/QWidget>
#include <QtGui/QGuiApplication>
#include <QtGui/QWindow>
#include <QtWebEngineCore/QWebEnginePage>
#include <QtWebEngineCore/QWebEngineProfile>
#include <QtWebEngineCore/QWebEngineScript>
#include <QtWebEngineCore/QWebEngineScriptCollection>
#include <cstdio>
#include <string>

#include "tweaks_js.h" // generated: tweaks_js[], tweaks_js_len

// ---- layout constants (top-left origin, points); keep in sync with tweaks.js CSS var ----
static const CGFloat kLightsX = 16;       // left edge of the close button
static const CGFloat kLightsCenterY = 34; // vertical centre of the sidebar header row
static const CGFloat kLightsGap = 12;     // gap between zoom button and avatar
static const CGFloat kDragZoneHeight = 56;

static void tt_log(NSString *fmt, ...) {
	static FILE *f = fopen([[NSHomeDirectory() stringByAppendingPathComponent:@"Library/Logs/TelemostTweaks.log"] fileSystemRepresentation], "a");
	if (!f) return;
	va_list ap;
	va_start(ap, fmt);
	NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
	va_end(ap);
	fprintf(f, "%s %s\n", [[[NSDate date] description] UTF8String], [s UTF8String]);
	fflush(f);
}

// ======================= web part =======================

static CGFloat lightsWidth(); // defined below

static QString scriptSource() {
	std::string js;
	NSString *override = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/TelemostTweaks/tweaks.override.js"];
	NSData *data = [NSData dataWithContentsOfFile:override];
	if (data) js.assign((const char *)data.bytes, data.length);
	else js.assign((const char *)tweaks_js, tweaks_js_len);
	char prefix[160];
	snprintf(prefix, sizeof prefix, "window.__TT_LIGHTS_W=%d;\n",
	         (int)(lightsWidth() + kLightsGap));
	return QString::fromUtf8(prefix) + QString::fromUtf8(js.data(), (qsizetype)js.size());
}

static void injectInto(QWebEnginePage *page) {
	if (getenv("TT_NO_WEB")) return;
	QWebEngineScript s;
	s.setName(QStringLiteral("telemost-tweaks"));
	s.setSourceCode(scriptSource());
	s.setInjectionPoint(QWebEngineScript::DocumentCreation);
	s.setWorldId(QWebEngineScript::MainWorld);
	s.setRunsOnSubFrames(false);
	// once per profile: profile scripts apply to every page created in it
	QWebEngineProfile *profile = page->profile();
	static NSMutableSet<NSValue *> *done = [NSMutableSet set];
	NSValue *key = [NSValue valueWithPointer:profile];
	if ([done containsObject:key]) return;
	[done addObject:key];
	profile->scripts()->insert(s);
	tt_log(@"script injected into profile %p (first page %p)", profile, page);
}

// Mangled constructors we interpose. C2 is what Telemost's own QWebEnginePage subclass calls,
// C1 covers pages created directly (e.g. by QWebEngineView).
// On Apple arm64 C++ constructors return `this` and callers may use it, so the wrappers must
// pass it through: returning garbage broke the page Telemost creates for window.open, and
// with it every target=_blank link.
extern "C" void *_ZN14QWebEnginePageC1EP7QObject(void *self, QObject *parent);
extern "C" void *_ZN14QWebEnginePageC2EP7QObject(void *self, QObject *parent);
extern "C" void *_ZN14QWebEnginePageC1EP17QWebEngineProfileP7QObject(void *self, void *profile, QObject *parent);
extern "C" void *_ZN14QWebEnginePageC2EP17QWebEngineProfileP7QObject(void *self, void *profile, QObject *parent);

static void *tt_C1(void *self, QObject *p) {
	void *r = _ZN14QWebEnginePageC1EP7QObject(self, p);
	injectInto((QWebEnginePage *)self);
	return r;
}
static void *tt_C2(void *self, QObject *p) {
	void *r = _ZN14QWebEnginePageC2EP7QObject(self, p);
	injectInto((QWebEnginePage *)self);
	return r;
}
static void *tt_C1p(void *self, void *pr, QObject *p) {
	void *r = _ZN14QWebEnginePageC1EP17QWebEngineProfileP7QObject(self, pr, p);
	injectInto((QWebEnginePage *)self);
	return r;
}
static void *tt_C2p(void *self, void *pr, QObject *p) {
	void *r = _ZN14QWebEnginePageC2EP17QWebEngineProfileP7QObject(self, pr, p);
	injectInto((QWebEnginePage *)self);
	return r;
}

struct interpose_t { const void *replacement; const void *original; };
__attribute__((used, section("__DATA,__interpose"))) static const interpose_t tt_interposers[] = {
	{(const void *)tt_C1, (const void *)_ZN14QWebEnginePageC1EP7QObject},
	{(const void *)tt_C2, (const void *)_ZN14QWebEnginePageC2EP7QObject},
	{(const void *)tt_C1p, (const void *)_ZN14QWebEnginePageC1EP17QWebEngineProfileP7QObject},
	{(const void *)tt_C2p, (const void *)_ZN14QWebEnginePageC2EP17QWebEngineProfileP7QObject},
};

// ======================= window part =======================

static NSArray<NSButton *> *lightButtons(NSWindow *w) {
	NSMutableArray *a = [NSMutableArray array];
	for (NSWindowButton b : {NSWindowCloseButton, NSWindowMiniaturizeButton, NSWindowZoomButton}) {
		NSButton *btn = [w standardWindowButton:b];
		if (btn) [a addObject:btn];
	}
	return a;
}

static CGFloat lightsWidth() {
	// close/minimize/zoom are 14pt wide, origins 20pt apart on current macOS
	return 14 + 2 * 20;
}

static bool isTarget(NSWindow *w) {
	if (![NSStringFromClass([w class]) containsString:@"QNSWindow"]) return false;
	NSWindowStyleMask m = w.styleMask;
	if (!(m & NSWindowStyleMaskTitled) || !(m & NSWindowStyleMaskResizable)) return false;
	NSString *t = w.title ?: @"";
	return [t rangeOfString:@"Telemost" options:NSCaseInsensitiveSearch].location != NSNotFound ||
	       [t rangeOfString:@"Телемост" options:NSCaseInsensitiveSearch].location != NSNotFound;
}

static void layoutLights(NSWindow *w) {
	if (w.styleMask & NSWindowStyleMaskFullScreen) return; // system owns them in full screen
	NSArray<NSButton *> *btns = lightButtons(w);
	if (btns.count != 3) return;
	NSView *container = btns[0].superview.superview; // NSTitlebarContainerView
	if (!container) return;
	CGFloat bh = btns[0].frame.size.height;
	CGFloat top = kLightsCenterY - bh / 2;
	NSRect r = container.frame;
	r.size.height = bh + top * 2; // keep the buttons vertically centred in the container
	r.origin.y = w.frame.size.height - r.size.height;
	container.frame = r;
	for (NSUInteger i = 0; i < btns.count; i++) {
		NSRect br = btns[i].frame;
		br.origin.x = kLightsX + i * 20;
		br.origin.y = (btns[i].superview.frame.size.height - bh) / 2;
		[btns[i] setFrameOrigin:br.origin];
	}
}

// Qt 6.8 sizes its top-level view from -contentLayoutRect, which excludes the titlebar
// even with NSWindowStyleMaskFullSizeContentView. Report the full window for our window.
static IMP origContentLayoutRect;
static NSRect tt_contentLayoutRect(NSWindow *self, SEL _cmd) {
	if ((self.styleMask & NSWindowStyleMaskFullSizeContentView) && isTarget(self))
		return NSMakeRect(0, 0, self.frame.size.width, self.frame.size.height);
	return ((NSRect(*)(id, SEL))origContentLayoutRect)(self, _cmd);
}

static void hookContentLayoutRect() {
	Method m = class_getInstanceMethod([NSWindow class], @selector(contentLayoutRect));
	origContentLayoutRect = method_setImplementation(m, (IMP)tt_contentLayoutRect);
}

// Qt 6.8 also shrinks widget layouts by the view's safe area, which now covers the titlebar.
static IMP origSafeAreaInsets;
static NSEdgeInsets tt_safeAreaInsets(NSView *self, SEL _cmd) {
	NSWindow *w = self.window;
	if (w && (w.styleMask & NSWindowStyleMaskFullSizeContentView) && isTarget(w)) return NSEdgeInsetsMake(0, 0, 0, 0);
	return ((NSEdgeInsets(*)(id, SEL))origSafeAreaInsets)(self, _cmd);
}

static void hookSafeArea(NSView *qnsview) {
	if (origSafeAreaInsets) return;
	Class c = [qnsview class];
	SEL sel = @selector(safeAreaInsets);
	Method m = class_getInstanceMethod(c, sel);
	origSafeAreaInsets = method_getImplementation(m);
	// add an override on the Qt class rather than replacing NSView's implementation
	if (!class_addMethod(c, sel, (IMP)tt_safeAreaInsets, method_getTypeEncoding(m)))
		method_setImplementation(m, (IMP)tt_safeAreaInsets);
	tt_log(@"safeAreaInsets hooked on %@", NSStringFromClass(c));
}

static void applyChrome(NSWindow *w) {
	if (!isTarget(w)) return;
	if (!(w.styleMask & NSWindowStyleMaskFullSizeContentView)) {
		w.styleMask |= NSWindowStyleMaskFullSizeContentView;
		hookSafeArea(w.contentView);
		tt_log(@"chrome applied to %@ '%@' %@", NSStringFromClass([w class]), w.title, NSStringFromRect(w.frame));
		// Qt only re-reads the content rect on a resize; nudge the frame so the
		// web view grows into the area under the transparent titlebar.
		NSRect f = w.frame;
		f.size.height += 1;
		[w setFrame:f display:NO];
		f.size.height -= 1;
		[w setFrame:f display:YES];
	}
	w.titlebarAppearsTransparent = YES;
	w.titleVisibility = NSWindowTitleHidden;
	layoutLights(w);
}

// Window drag: Qt's view swallows mouse events in the (now transparent) titlebar strip,
// so start a native window drag when the mouse is dragged from the top strip.
static void installDragMonitor() {
	static NSEvent *down = nil;
	[NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskLeftMouseDown | NSEventMaskLeftMouseDragged | NSEventMaskLeftMouseUp
	                                      handler:^NSEvent *(NSEvent *e) {
		                                      NSWindow *w = e.window;
		                                      if (!w || !isTarget(w) || (w.styleMask & NSWindowStyleMaskFullScreen)) return e;
		                                      CGFloat fromTop = w.frame.size.height - e.locationInWindow.y;
		                                      switch (e.type) {
		                                      case NSEventTypeLeftMouseDown:
			                                      down = fromTop <= kDragZoneHeight ? e : nil;
			                                      if (down && e.clickCount == 2) {
				                                      down = nil;
				                                      [w zoom:nil];
				                                      return nil;
			                                      }
			                                      break;
		                                      case NSEventTypeLeftMouseDragged:
			                                      if (down && hypot(e.locationInWindow.x - down.locationInWindow.x, e.locationInWindow.y - down.locationInWindow.y) > 3) {
				                                      NSEvent *d = down;
				                                      down = nil;
				                                      [w performWindowDragWithEvent:d];
				                                      return nil;
			                                      }
			                                      break;
		                                      default:
			                                      down = nil;
			                                      break;
		                                      }
		                                      return e;
	                                      }];
}

// ======================= show window on activation =======================
// Stock Telemost reopens its closed (hidden) main window on a Dock click, but not when
// the app is activated with Cmd+Tab: that only sends didBecomeActive, never reopen.
// On activation, if the main window is hidden, show it through Qt (not AppKit) so
// Qt's own visibility state stays consistent.

// The main window is an `Orbita::Frame` with an empty widget title; "Yandex Telemost"
// is set only on its native window. Match the title on either, else take the largest
// plain top-level window that is not a menu bar.
static bool isTelemostTitle(const QString &t) {
	return t.contains(QStringLiteral("Telemost"), Qt::CaseInsensitive) || t.contains(QStringLiteral("Телемост"), Qt::CaseInsensitive);
}

static QWidget *mainWidget() {
	QWidget *byTitle = nullptr, *largest = nullptr;
	for (QWidget *w : QApplication::topLevelWidgets()) {
		if (!w->isWindow() || w->windowType() != Qt::Window || w->inherits("QMenuBar")) continue;
		if (!largest || w->width() * w->height() > largest->width() * largest->height()) largest = w;
		if (isTelemostTitle(w->windowTitle()) || (w->windowHandle() && isTelemostTitle(w->windowHandle()->title()))) byTitle = w;
	}
	return byTitle ? byTitle : largest;
}

static void dumpWindows(const char *tag) {
	for (QWidget *x : QApplication::topLevelWidgets())
		tt_log(@"  %s widget %s '%s' window=%d visible=%d type=0x%x %dx%d", tag, x->metaObject()->className(), x->windowTitle().toUtf8().constData(),
		       x->isWindow(), x->isVisible(), (unsigned)x->windowType(), x->width(), x->height());
	for (QWindow *x : QGuiApplication::topLevelWindows())
		tt_log(@"  %s qwindow %s '%s' visible=%d %dx%d", tag, x->metaObject()->className(), x->title().toUtf8().constData(), x->isVisible(), x->width(), x->height());
	for (NSWindow *x in NSApp.windows)
		tt_log(@"  %s nswindow %@ '%@' visible=%d", tag, NSStringFromClass([x class]), x.title, x.visible);
}

static void showMainWindowIfHidden() {
	// any other visible titled window (a call, settings) means the user has something on screen
	for (NSWindow *nw in NSApp.windows)
		if (nw.visible && (nw.styleMask & NSWindowStyleMaskTitled)) return;
	QWidget *w = mainWidget();
	if (!w) {
		tt_log(@"activate: no hidden main window found");
		dumpWindows("activate");
		return;
	}
	w->showNormal();
	w->raise();
	w->activateWindow();
	tt_log(@"activate: showed '%s'", w->windowTitle().toUtf8().constData());
}

static void installActivationHandler() {
	[[NSNotificationCenter defaultCenter] addObserverForName:NSApplicationDidBecomeActiveNotification
	                                                  object:nil
	                                                   queue:nil
	                                              usingBlock:^(NSNotification *) {
		                                              // let a Dock-click reopen, which also activates, go first
		                                              dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 300 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
			                                              showMainWindowIfHidden();
		                                              });
	                                              }];
}

// ======================= notification diagnostics =======================
// Logs what macOS answers to every notification request, so "the web side sent it,
// nothing appeared" can be told apart from a refusal by the system.

static IMP origAddRequest;
static void tt_addRequest(id self, SEL _cmd, UNNotificationRequest *req, void (^done)(NSError *)) {
	NSString *ident = req.identifier;
	void (^wrapped)(NSError *) = ^(NSError *err) {
		tt_log(@"notification %@ -> %@", ident, err ? err.description : @"accepted by macOS");
		if (done) done(err);
	};
	((void (*)(id, SEL, UNNotificationRequest *, void (^)(NSError *)))origAddRequest)(self, _cmd, req, wrapped);
}

static void hookNotifications() {
	Method m = class_getInstanceMethod([UNUserNotificationCenter class], @selector(addNotificationRequest:withCompletionHandler:));
	if (!m) return;
	origAddRequest = method_setImplementation(m, (IMP)tt_addRequest);
	[[UNUserNotificationCenter currentNotificationCenter] getNotificationSettingsWithCompletionHandler:^(UNNotificationSettings *st) {
		tt_log(@"notification settings: authorization=%ld alert=%ld sound=%ld", (long)st.authorizationStatus, (long)st.alertSetting, (long)st.soundSetting);
	}];
}

__attribute__((constructor)) static void tt_init() {
	tt_log(@"loaded into %@ pid %d", [[NSBundle mainBundle] bundleIdentifier], getpid());
	dispatch_async(dispatch_get_main_queue(), ^{
		hookNotifications();
		installActivationHandler();
	});
	if (getenv("TT_NO_WINDOW")) return;
	dispatch_async(dispatch_get_main_queue(), ^{
		NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
		for (NSNotificationName n in @[NSWindowDidBecomeKeyNotification, NSWindowDidBecomeMainNotification, NSWindowDidResizeNotification,
		                               NSWindowDidEndLiveResizeNotification, NSWindowDidExitFullScreenNotification]) {
			[nc addObserverForName:n object:nil queue:nil usingBlock:^(NSNotification *note) {
				   if ([note.object isKindOfClass:[NSWindow class]]) applyChrome(note.object);
			   }];
		}
		installDragMonitor();
		hookContentLayoutRect();
	});
}
