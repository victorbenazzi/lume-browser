#import "CEFBridge.h"
#include "include/cef_app.h"
#include "include/cef_application_mac.h"
#include "include/cef_client.h"
#include "include/cef_cookie.h"
#include "include/cef_parser.h"
#include "include/cef_request_context.h"
#include "include/wrapper/cef_helpers.h"
#include "include/wrapper/cef_library_loader.h"
#include <algorithm>
#include <map>
#include <memory>
#include <cmath>

static NSString *ToNSString(const CefString &value) {
  return [NSString stringWithUTF8String:value.ToString().c_str()] ?: @"";
}

// `scheme://host[:port]`, the default HTTP and HTTPS ports left out as the core stores origins.
static NSString *URLOrigin(NSString *url) {
  NSURLComponents *parts = [NSURLComponents componentsWithString:url];
  if (!parts.scheme.length || !parts.host.length) return nil;
  NSString *scheme = parts.scheme.lowercaseString;
  NSInteger defaultPort = [scheme isEqualToString:@"https"] ? 443 : [scheme isEqualToString:@"http"] ? 80 : -1;
  NSString *port = parts.port && parts.port.integerValue != defaultPort ? [NSString stringWithFormat:@":%@", parts.port] : @"";
  return [NSString stringWithFormat:@"%@://%@%@", scheme, parts.host.lowercaseString, port];
}

static CefString ToCefString(NSString *text) { return CefString(text.UTF8String); }

static NSData *PNGData(CefRefPtr<CefImage> image) {
  int width = 0, height = 0;
  CefRefPtr<CefBinaryValue> png = image && !image->IsEmpty() ? image->GetAsPNG(1.0f, true, width, height) : nullptr;
  if (!png || png->GetSize() == 0) return nil;
  NSMutableData *data = [NSMutableData dataWithLength:png->GetSize()];
  png->GetData(data.mutableBytes, png->GetSize(), 0);
  return data;
}

// A JavaScript string literal for any text.
static NSString *ScriptLiteral(NSString *text) {
  NSData *data = [NSJSONSerialization dataWithJSONObject:@[text] options:0 error:nil];
  NSString *array = data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : @"[\"\"]";
  return [array substringWithRange:NSMakeRange(1, array.length - 2)];
}

// The DevTools frontend runs in an ordinary Alloy browser. Chromium serves it and gives it its host, but only a
// Chrome DevTools window can attach it to a page, so Lume carries its protocol messages. They leave through the
// frontend's console, marked with this prefix, and arrive through DevToolsAPI.
static NSString *const kDevToolsChannel = @"\x01lume-devtools\x01";
static NSString *const kDevToolsFrontendURL = @"devtools://devtools/bundled/devtools_app.html";
// Protocol requests Lume makes itself, numbered far above the frontend's own.
static const NSInteger kPrivateRequestBase = 1900000000;

static NSString *DevToolsFrontendPatch(void) {
  return [NSString stringWithFormat:@"(() => {"
      "if (window.__lumeDevTools) return;"
      "window.__lumeDevTools = true;"
      "const send = console.debug.bind(console), channel = %@;"
      "const patch = host => {"
      "  host.sendMessageToBackend = message => send(channel + 'm' + message);"
      "  host.openInNewTab = url => send(channel + 'o' + url);"
      "};"
      "if (window.InspectorFrontendHost) { patch(window.InspectorFrontendHost); return; }"
      "let host;"
      "Object.defineProperty(window, 'InspectorFrontendHost', {configurable: true, enumerable: true,"
      "  get: () => host, set: value => { host = value; if (value) patch(value); }});"
      "})();", ScriptLiteral(kDevToolsChannel)];
}

// The id of a response, as the protocol writes it first: {"id":12,...
static NSInteger ProtocolMessageID(NSString *message) {
  if (![message hasPrefix:@"{\"id\":"]) return 0;
  return [message substringWithRange:NSMakeRange(6, MIN(12, message.length - 6))].integerValue;
}

// Messages of a flattened session end with its id. The page's root session has none.
static NSRange TrailingSessionRange(NSString *message) {
  if (![message hasSuffix:@"\"}"]) return NSMakeRange(NSNotFound, 0);
  NSRange marker = [message rangeOfString:@",\"sessionId\":\"" options:NSBackwardsSearch];
  if (marker.location == NSNotFound) return marker;
  NSRange session = NSMakeRange(NSMaxRange(marker), message.length - 2 - NSMaxRange(marker));
  NSString *text = [message substringWithRange:session];
  if (!text.length || [text rangeOfString:@"^[A-Za-z0-9]+$" options:NSRegularExpressionSearch].location == NSNotFound)
    return NSMakeRange(NSNotFound, 0);
  return NSMakeRange(marker.location, message.length - marker.location);
}

static NSString *URLScheme(NSString *url) {
  NSRange colon = [url rangeOfString:@":"];
  if (colon.location == NSNotFound || colon.location == 0) return @"";
  NSString *scheme = [url substringToIndex:colon.location].lowercaseString;
  NSRange valid = [scheme rangeOfString:@"^[a-z][a-z0-9+.-]*$" options:NSRegularExpressionSearch];
  return valid.location == NSNotFound ? @"" : scheme;
}

// Schemes Chromium handles itself. Any other scheme belongs to an app on the Mac, such as mailto: or zoommtg:.
static BOOL IsExternalScheme(NSString *scheme) {
  static NSSet<NSString *> *engine = [NSSet setWithArray:@[
    @"http", @"https", @"about", @"blob", @"data", @"javascript", @"file", @"filesystem", @"ws", @"wss",
    @"chrome", @"chrome-extension", @"chrome-untrusted", @"chrome-error", @"devtools", @"view-source"]];
  return scheme.length > 0 && ![engine containsObject:scheme];
}

static BOOL IsWebURL(NSString *url) {
  NSString *scheme = URLScheme(url);
  return [scheme isEqualToString:@"https"] || [scheme isEqualToString:@"http"];
}

// A blob: address minted by an HTTP or HTTPS page, such as a generated PDF.
static BOOL IsWebBlob(NSString *url) {
  if (![URLScheme(url) isEqualToString:@"blob"]) return NO;
  NSString *inner = [url substringFromIndex:5];
  return IsWebURL(inner) && URLOrigin(inner) != nil;
}

// The selection on one line, cut short for a menu title.
static NSString *ShortSelection(NSString *text) {
  NSArray<NSString *> *words = [[text componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]
                                filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"length > 0"]];
  NSString *flat = [words componentsJoinedByString:@" "];
  if (flat.length <= 32) return flat;
  NSRange head = [flat rangeOfComposedCharacterSequencesForRange:NSMakeRange(0, 31)];
  return [[flat substringWithRange:head] stringByAppendingString:@"…"];
}

// The language macOS lists first, as Chromium expects it: "pt-BR".
static NSString *PreferredLanguage(void) {
  NSLocale *locale = [NSLocale localeWithLocaleIdentifier:NSLocale.preferredLanguages.firstObject ?: @"en-US"];
  NSString *language = locale.languageCode ?: @"en";
  return locale.countryCode.length ? [NSString stringWithFormat:@"%@-%@", language, locale.countryCode] : language;
}

// Sites see the same languages as Safari would send, each followed by its base language.
static NSString *AcceptLanguages(void) {
  NSMutableOrderedSet<NSString *> *languages = [NSMutableOrderedSet orderedSet];
  for (NSString *identifier in [NSLocale.preferredLanguages subarrayWithRange:NSMakeRange(0, MIN(4, NSLocale.preferredLanguages.count))]) {
    NSLocale *locale = [NSLocale localeWithLocaleIdentifier:identifier];
    if (!locale.languageCode.length) continue;
    if (locale.countryCode.length) [languages addObject:[NSString stringWithFormat:@"%@-%@", locale.languageCode, locale.countryCode]];
    [languages addObject:locale.languageCode];
  }
  if (!languages.count) [languages addObjectsFromArray:@[@"en-US", @"en"]];
  return [languages.array componentsJoinedByString:@","];
}

// Commands Lume adds to the page's context menu.
enum LumeMenuCommand {
  kOpenLinkInNewTab = MENU_ID_USER_FIRST,
  kCopyLinkAddress,
  kDownloadLink,
  kOpenMediaInNewTab,
  kSaveMedia,
  kCopyImage,
  kCopyMediaAddress,
  kSearchSelection,
  kInspect,
};

static BOOL TestingDiagnostics(void) {
  static const BOOL enabled = [NSProcessInfo.processInfo.arguments containsObject:@"--smoke-test"] ||
                              [NSProcessInfo.processInfo.arguments containsObject:@"--reliability-test"];
  return enabled;
}

static BOOL FixtureAccessAllowed(CefRefPtr<CefBrowser> browser, BOOL crash) {
  NSArray<NSString *> *args = NSProcessInfo.processInfo.arguments;
  if (![args containsObject:@"--reliability-test"] &&
      (crash || ![args containsObject:@"--smoke-test"])) return NO;
  NSString *fixture = NSProcessInfo.processInfo.environment[@"LUME_TEST_URL"];
  NSURLComponents *parts = [NSURLComponents componentsWithString:fixture ?: @""];
  if (![parts.scheme isEqualToString:@"http"] || ![parts.host isEqualToString:@"127.0.0.1"] || !parts.port) return NO;
  return browser && browser->IsValid() &&
         [URLOrigin(ToNSString(browser->GetMainFrame()->GetURL())) isEqualToString:URLOrigin(fixture)];
}

class FlushCompletion final : public CefCompletionCallback {
 public:
  explicit FlushCompletion(void (^completion)(void)) : completion_([completion copy]) {}
  void OnComplete() override { completion_(); }
 private:
  __strong void (^completion_)(void);
  IMPLEMENT_REFCOUNTING(FlushCompletion);
};

// A question for the user on behalf of one tab: a permission, a login or an external app.
// The engine shows one at a time, only for the tab on screen, so a sheet always belongs to the visible page.
@interface LBPrompt : NSObject
@property(nonatomic, copy) NSString *tab;
/// The CEF permission prompt it answers, so CEF can withdraw it. Zero for other questions.
@property(nonatomic) uint64_t permissionPromptID;
/// Shows the sheet and returns it, or returns nil after answering on its own. Calls `finished` exactly once.
@property(nonatomic, copy) NSAlert *_Nullable (^present)(NSWindow *window, void (^finished)(void));
/// Answers no without asking, when the tab closes first.
@property(nonatomic, copy, nullable) void (^withdraw)(void);
@property(nonatomic, strong, nullable) NSAlert *alert;
@end
@implementation LBPrompt
@end

@interface LBApplication : NSApplication <CefAppProtocol>
@property(nonatomic) BOOL handlingSendEvent;
@end
@implementation LBApplication
- (BOOL)isHandlingSendEvent { return self.handlingSendEvent; }
- (void)sendEvent:(NSEvent *)event {
  CefScopedSendingEvent scope;
  [super sendEvent:event];
}
- (void)terminate:(id)sender {
  [[NSNotificationCenter defaultCenter] postNotificationName:@"LumeWillQuit" object:nil];
}
@end

class LumeClient;
class DevToolsClient;
struct TabSlot {
  __strong NSView *container;
  CefRefPtr<CefBrowser> browser;
  CefRefPtr<LumeClient> client;
  std::string pendingURL;
  std::string startedURL;
  std::string lastPageURL;
  bool rendererTerminated = false;
  bool closing = false;
  bool muted = false;
  double zoomLevel = 0.0;
  bool creating = false;
  bool popup = false;
  std::string openerID;
  int popupID = 0;
  // Carries the page's protocol messages to its DevTools, from the first time it opens until the page closes.
  CefRefPtr<CefRegistration> devToolsObserver;
};

// A tab's DevTools, drawn into its own view so the window can place it in the panel beside the page.
struct DevToolsSlot {
  __strong NSView *container;
  CefRefPtr<CefBrowser> browser;
  CefRefPtr<DevToolsClient> client;
  // A session of DevTools' own on the page, as Chrome's DevTools window attaches one. Detaching it undoes
  // what DevTools changed there: breakpoints, emulation, highlights.
  std::string session;
  // Frontend messages sent before the session exists.
  __strong NSMutableArray<NSString *> *queued;
  bool frontendStarted = false;
  // The frontend listens for nodes to reveal once its Overlay.enable is answered.
  NSInteger overlayRequest = 0;
  bool revealsNodes = false;
  int pendingNode = 0;
  // The window learns about it once its frontend has loaded, so the page keeps its width until then.
  bool announced = false;
  bool closing = false;
};

struct DownloadMetadata {
  std::string filename;
  std::string path;
};

@interface LBCEFEngine () {
  std::map<std::string, std::unique_ptr<TabSlot>> _slots;
  std::map<std::string, DevToolsSlot> _devTools;
  NSMutableDictionary<NSNumber *, void (^)(NSDictionary *)> *_devToolsRequests;
  NSInteger _devToolsRequestCount;
  BOOL _quitting;
  BOOL _flushPending;
  NSString *_activeID;
  std::map<std::string, CefRefPtr<CefDownloadItemCallback>> _downloads;
  std::map<std::string, DownloadMetadata> _downloadMetadata;
  NSMutableArray<LBPrompt *> *_prompts;
  LBPrompt *_shownPrompt;
  id _sheetObserver;
  // The page each tab last asked about an external app without a click, so a page cannot ask again in a loop.
  NSMutableDictionary<NSString *, NSString *> *_externalAskedPages;
}
- (void)openExternalURL:(NSString *)url tab:(NSString *)identifier pageURL:(NSString *)pageURL
                 origin:(NSString *)origin rememberable:(BOOL)rememberable userGesture:(BOOL)userGesture;
- (void)requestMedia:(uint32_t)requested origin:(NSString *)origin tab:(NSString *)identifier browser:(CefRefPtr<CefBrowser>)browser
               frame:(CefRefPtr<CefFrame>)frame callback:(CefRefPtr<CefMediaAccessCallback>)callback;
- (void)showPermissionPrompt:(uint64_t)promptID origin:(NSString *)origin requested:(uint32_t)requested tab:(NSString *)identifier
                     browser:(CefRefPtr<CefBrowser>)browser callback:(CefRefPtr<CefPermissionPromptCallback>)callback;
- (void)dismissPermissionPrompt:(uint64_t)promptID;
- (void)requestCredentialsForHost:(NSString *)host port:(int)port realm:(NSString *)realm origin:(NSString *)origin
                            proxy:(BOOL)proxy tab:(NSString *)identifier callback:(CefRefPtr<CefAuthCallback>)callback;
- (void)emit:(NSDictionary *)event;
- (void)didCreate:(CefRefPtr<CefBrowser>)browser identifier:(NSString *)identifier;
- (void)didClose:(NSString *)identifier;
- (void)didCancelClose:(NSString *)identifier;
- (BOOL)isActive:(NSString *)identifier;
- (void)startTab:(NSString *)identifier url:(NSString *)url;
- (void)preparePopup:(NSString *)identifier opener:(NSString *)opener popupID:(int)popupID
                 info:(CefWindowInfo &)info client:(CefRefPtr<CefClient> &)client;
- (void)abortPopup:(int)popupID opener:(NSString *)opener;
- (void)downloadUpdated:(CefRefPtr<CefDownloadItem>)item tab:(NSString *)identifier
               callback:(CefRefPtr<CefDownloadItemCallback>)callback;
- (void)finishShutdown;
- (void)didNavigate:(NSString *)identifier url:(NSString *)url;
- (void)rendererTerminated:(NSString *)identifier;
- (void)rememberDownloadName:(NSString *)name item:(CefRefPtr<CefDownloadItem>)item tab:(NSString *)identifier;
- (void)showDevTools:(NSString *)identifier inspect:(BOOL)inspect x:(int)x y:(int)y;
- (void)didCreateDevTools:(CefRefPtr<CefBrowser>)browser identifier:(NSString *)identifier client:(DevToolsClient *)client;
- (void)devToolsStarted:(NSString *)identifier client:(DevToolsClient *)client;
- (void)devToolsLoaded:(NSString *)identifier client:(DevToolsClient *)client;
- (void)didCloseDevTools:(NSString *)identifier client:(DevToolsClient *)client;
- (void)devToolsFrontendSent:(NSString *)message tab:(NSString *)identifier;
- (void)devToolsBackendSent:(NSString *)message tab:(NSString *)identifier;
@end

// Chromium downloads the icon with the page's own cookies, cache and proxy settings.
class FaviconDownload final : public CefDownloadImageCallback {
 public:
  FaviconDownload(LBCEFEngine *owner, NSString *identifier) : owner_(owner), identifier_(identifier) {}
  void OnDownloadImageFinished(const CefString &url, int status, CefRefPtr<CefImage> image) override {
    NSMutableDictionary *event = [@{@"kind": @"faviconImage", @"id": identifier_, @"value": ToNSString(url)} mutableCopy];
    if (NSData *data = PNGData(image)) event[@"data"] = data;
    [owner_ emit:event];
  }
 private:
  __weak LBCEFEngine *owner_;
  __strong NSString *identifier_;
  IMPLEMENT_REFCOUNTING(FaviconDownload);
};

// Puts an image from the page on the clipboard, fetched with the page's own cookies and cache.
class ImageCopy final : public CefDownloadImageCallback {
 public:
  void OnDownloadImageFinished(const CefString &url, int status, CefRefPtr<CefImage> image) override {
    NSData *data = PNGData(image);
    if (!data) { NSBeep(); return; }
    NSImage *picture = [[NSImage alloc] initWithData:data];
    NSPasteboardItem *item = [[NSPasteboardItem alloc] init];
    [item setData:data forType:NSPasteboardTypePNG];
    if (NSData *tiff = picture.TIFFRepresentation) [item setData:tiff forType:NSPasteboardTypeTIFF];
    [NSPasteboard.generalPasteboard clearContents];
    [NSPasteboard.generalPasteboard writeObjects:@[item]];
  }
 private:
  IMPLEMENT_REFCOUNTING(ImageCopy);
};

class LumeClient final : public CefClient,
                         public CefLifeSpanHandler,
                         public CefDisplayHandler,
                         public CefLoadHandler,
                         public CefRequestHandler,
                         public CefFocusHandler,
                         public CefJSDialogHandler,
                         public CefDownloadHandler,
                         public CefFindHandler,
                         public CefPermissionHandler,
                         public CefContextMenuHandler {
 public:
  LumeClient(LBCEFEngine *owner, NSString *identifier) : owner_(owner), identifier_(identifier) {}
  CefRefPtr<CefContextMenuHandler> GetContextMenuHandler() override { return this; }
  CefRefPtr<CefLifeSpanHandler> GetLifeSpanHandler() override { return this; }
  CefRefPtr<CefDisplayHandler> GetDisplayHandler() override { return this; }
  CefRefPtr<CefLoadHandler> GetLoadHandler() override { return this; }
  CefRefPtr<CefRequestHandler> GetRequestHandler() override { return this; }
  CefRefPtr<CefFocusHandler> GetFocusHandler() override { return this; }
  CefRefPtr<CefJSDialogHandler> GetJSDialogHandler() override { return this; }
  CefRefPtr<CefDownloadHandler> GetDownloadHandler() override { return this; }
  CefRefPtr<CefFindHandler> GetFindHandler() override { return this; }
  CefRefPtr<CefPermissionHandler> GetPermissionHandler() override { return this; }

  void OnAfterCreated(CefRefPtr<CefBrowser> browser) override {
    CEF_REQUIRE_UI_THREAD();
    [owner_ didCreate:browser identifier:identifier_];
  }
  bool DoClose(CefRefPtr<CefBrowser> browser) override {
    // Remove only this tab's CEF wrapper view after beforeunload has completed.
    // Releasing the wrapper triggers WindowDestroyed and then OnBeforeClose.
    NSView *view = (__bridge NSView *)browser->GetHost()->GetWindowHandle();
    dispatch_async(dispatch_get_main_queue(), ^{ [view removeFromSuperview]; });
    return true;
  }
  void OnBeforeClose(CefRefPtr<CefBrowser> browser) override {
    CEF_REQUIRE_UI_THREAD();
    [owner_ didClose:identifier_];
  }
  void OnTitleChange(CefRefPtr<CefBrowser> browser, const CefString &title) override {
    Send(@"title", ToNSString(title));
  }
  void OnAddressChange(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame,
                       const CefString &url) override {
    if (frame->IsMain()) [owner_ didNavigate:identifier_ url:ToNSString(url)];
  }
  void OnFaviconURLChange(CefRefPtr<CefBrowser> browser,
                          const std::vector<CefString> &urls) override {
    if (urls.empty()) return;
    Send(@"favicon", ToNSString(urls.front()));
    // 64 px keeps the 16 pt tab icon sharp on Retina.
    browser->GetHost()->DownloadImage(urls.front(), true, 64, false, new FaviconDownload(owner_, identifier_));
  }
  void OnFullscreenModeChange(CefRefPtr<CefBrowser> browser, bool fullscreen) override {
    // With Alloy the page only fills its view. The window takes over the screen on Lume's side.
    [owner_ emit:@{@"kind": @"fullscreen", @"id": identifier_, @"fullscreen": @(fullscreen)}];
  }
  void OnLoadingStateChange(CefRefPtr<CefBrowser> browser, bool loading,
                             bool back, bool forward) override {
    [owner_ emit:@{@"kind": @"loading", @"id": identifier_, @"loading": @(loading),
                   @"back": @(back), @"forward": @(forward)}];
  }
  void OnLoadError(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame,
                   ErrorCode code, const CefString &message, const CefString &url) override {
    if (frame->IsMain() && code != ERR_ABORTED) Send(@"failure", ToNSString(message));
  }
  void OnRenderProcessTerminated(CefRefPtr<CefBrowser> browser, TerminationStatus status,
                                  int code, const CefString &message) override {
    [owner_ rendererTerminated:identifier_];
  }
  bool OnSetFocus(CefRefPtr<CefBrowser> browser, FocusSource source) override {
    // Background loads must not steal keyboard focus from native controls.
    return source == FOCUS_SOURCE_NAVIGATION || ![owner_ isActive:identifier_];
  }
  bool OnBeforeBrowse(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame,
                       CefRefPtr<CefRequest> request, bool user, bool redirect) override {
    NSString *target = ToNSString(request->GetURL());
    // Links to other apps never load in a frame. Lume asks before handing them to macOS.
    if (IsExternalScheme(URLScheme(target))) {
      OpenExternal(browser, frame, target, user);
      return true;
    }
    if (!frame->IsMain()) return false;
    const auto url = request->GetURL().ToString();
    const bool allowed = url.starts_with("https://") || url.starts_with("http://") ||
                         url == "about:blank" || url.starts_with("chrome://") ||
                         url.starts_with("devtools://") || IsWebBlob(target);
    if (!allowed) Send(@"failure", @"Este tipo de endereço ainda não é suportado.");
    return !allowed;
  }
  bool OnBeforePopup(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame, int popupID,
                     const CefString &url, const CefString &name, WindowOpenDisposition disposition,
                     bool userGesture, const CefPopupFeatures &features, CefWindowInfo &info,
                     CefRefPtr<CefClient> &client, CefBrowserSettings &settings,
                     CefRefPtr<CefDictionaryValue> &extra, bool *noAccess) override {
    if (!userGesture) return true;
    NSString *target = ToNSString(url);
    if (IsExternalScheme(URLScheme(target))) {
      OpenExternal(browser, frame, target, true);
      return true;
    }
    if (target.length && ![target isEqualToString:@"about:blank"] && !IsWebURL(target) && !IsWebBlob(target)) return true;
    NSString *newID = NSUUID.UUID.UUIDString;
    [owner_ preparePopup:newID opener:identifier_ popupID:popupID info:info client:client];
    // Preserve CEF's opener relationship and default JavaScript access policy.
    return false;
  }
  void OnBeforePopupAborted(CefRefPtr<CefBrowser> browser, int popupID) override {
    [owner_ abortPopup:popupID opener:identifier_];
  }
  bool OnOpenURLFromTab(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame,
                        const CefString &url, WindowOpenDisposition disposition, bool user) override {
    if (disposition != CEF_WOD_NEW_FOREGROUND_TAB && disposition != CEF_WOD_NEW_BACKGROUND_TAB &&
        disposition != CEF_WOD_NEW_WINDOW && disposition != CEF_WOD_NEW_POPUP) return false;
    if (!user) return true;
    NSString *target = ToNSString(url);
    if (IsExternalScheme(URLScheme(target))) OpenExternal(browser, frame, target, true);
    else Send(@"popup", target);
    return true;
  }
  bool OnBeforeUnloadDialog(CefRefPtr<CefBrowser> browser, const CefString &message,
                             bool reload, CefRefPtr<CefJSDialogCallback> callback) override {
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = @"Sair desta página?";
    NSString *pageURL = ToNSString(browser->GetMainFrame()->GetURL());
    alert.informativeText = [NSString stringWithFormat:@"%@\n\nA página informa que algumas alterações podem não estar salvas.", pageURL];
    [alert addButtonWithTitle:@"Permanecer na página"];
    [alert addButtonWithTitle:@"Sair da página"];
    NSWindow *window = ((__bridge NSView *)browser->GetHost()->GetWindowHandle()).window ?: owner_.dialogWindow;
    auto finish = ^(NSModalResponse result) {
      BOOL leave = result == NSAlertSecondButtonReturn;
      if (!leave) [owner_ didCancelClose:identifier_];
      callback->Continue(leave, CefString());
    };
    if (window) {
      [window makeKeyAndOrderFront:nil];
      [NSApp activateIgnoringOtherApps:YES];
      [alert beginSheetModalForWindow:window completionHandler:finish];
    }
    else finish(NSAlertFirstButtonReturn);
    return true;
  }
  bool OnBeforeDownload(CefRefPtr<CefBrowser> browser, CefRefPtr<CefDownloadItem> item,
                         const CefString &suggestedName,
                         CefRefPtr<CefBeforeDownloadCallback> callback) override {
    NSString *filename = ToNSString(suggestedName).lastPathComponent;
    if (!filename.length) filename = @"download";
    [owner_ rememberDownloadName:filename item:item tab:identifier_];
    NSString *directory = NSSearchPathForDirectoriesInDomains(NSDownloadsDirectory, NSUserDomainMask, YES).firstObject;
    NSString *path = [(directory ?: NSHomeDirectory()) stringByAppendingPathComponent:filename];
    // CEF owns the native Save As dialog, including overwrite confirmation.
    callback->Continue(path.UTF8String, true);
    return true;
  }
  void OnDownloadUpdated(CefRefPtr<CefBrowser> browser, CefRefPtr<CefDownloadItem> item,
                          CefRefPtr<CefDownloadItemCallback> callback) override {
    [owner_ downloadUpdated:item tab:identifier_ callback:callback];
  }
  void OnFindResult(CefRefPtr<CefBrowser> browser, int requestID, int count,
                    const CefRect &selection, int active, bool finalUpdate) override {
    [owner_ emit:@{@"kind": @"findResult", @"id": identifier_, @"count": @(count),
                   @"active": @(active), @"final": @(finalUpdate)}];
  }
  bool OnRequestMediaAccessPermission(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame,
                                      const CefString &origin, uint32_t requested,
                                      CefRefPtr<CefMediaAccessCallback> callback) override {
    [owner_ requestMedia:requested origin:ToNSString(origin) tab:identifier_ browser:browser frame:frame callback:callback];
    return true;
  }
  bool OnShowPermissionPrompt(CefRefPtr<CefBrowser> browser, uint64_t promptID,
                               const CefString &origin, uint32_t requested,
                               CefRefPtr<CefPermissionPromptCallback> callback) override {
    [owner_ showPermissionPrompt:promptID origin:ToNSString(origin) requested:requested tab:identifier_
                         browser:browser callback:callback];
    return true;
  }
  void OnDismissPermissionPrompt(CefRefPtr<CefBrowser> browser, uint64_t promptID,
                                 cef_permission_request_result_t result) override {
    [owner_ dismissPermissionPrompt:promptID];
  }
  bool GetAuthCredentials(CefRefPtr<CefBrowser> browser, const CefString &originURL, bool isProxy,
                          const CefString &host, int port, const CefString &realm,
                          const CefString &scheme, CefRefPtr<CefAuthCallback> callback) override {
    // Called on the IO thread. The sheet belongs on the main thread.
    LBCEFEngine *owner = owner_;
    NSString *identifier = identifier_;
    NSString *hostName = ToNSString(host), *realmName = ToNSString(realm), *origin = ToNSString(originURL);
    dispatch_async(dispatch_get_main_queue(), ^{
      if (owner) [owner requestCredentialsForHost:hostName port:port realm:realmName origin:origin
                                            proxy:isProxy tab:identifier callback:callback];
      else callback->Cancel();
    });
    return true;
  }

  void OnBeforeContextMenu(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame,
                           CefRefPtr<CefContextMenuParams> params, CefRefPtr<CefMenuModel> model) override {
    model->Clear();
    auto add = [&](int command, NSString *title, bool enabled = true) {
      model->AddItem(command, ToCefString(title));
      model->SetEnabled(command, enabled);
    };
    auto separate = [&] {
      const size_t count = model->GetCount();
      if (count && model->GetTypeAt(count - 1) != MENUITEMTYPE_SEPARATOR) model->AddSeparator();
    };
    const int type = params->GetTypeFlags();
    NSString *link = ToNSString(params->GetLinkUrl());
    NSString *source = ToNSString(params->GetSourceUrl());
    NSString *selection = ShortSelection(ToNSString(params->GetSelectionText()));
    const auto media = params->GetMediaType();
    const bool image = media == CM_MEDIATYPE_IMAGE;
    const bool video = media == CM_MEDIATYPE_VIDEO, audio = media == CM_MEDIATYPE_AUDIO;

    if (type & CM_TYPEFLAG_EDITABLE) {
      if (!params->GetMisspelledWord().empty()) {
        std::vector<CefString> suggestions;
        params->GetDictionarySuggestions(suggestions);
        const size_t limit = MENU_ID_SPELLCHECK_SUGGESTION_LAST - MENU_ID_SPELLCHECK_SUGGESTION_0 + 1;
        for (size_t index = 0; index < std::min(suggestions.size(), limit); ++index)
          model->AddItem(MENU_ID_SPELLCHECK_SUGGESTION_0 + int(index), suggestions[index]);
        if (suggestions.empty()) add(MENU_ID_NO_SPELLING_SUGGESTIONS, @"Nenhuma sugestão", false);
        add(MENU_ID_ADD_TO_DICTIONARY, @"Aprender ortografia");
        separate();
      }
      const int edit = params->GetEditStateFlags();
      add(MENU_ID_UNDO, @"Desfazer", edit & CM_EDITFLAG_CAN_UNDO);
      add(MENU_ID_REDO, @"Refazer", edit & CM_EDITFLAG_CAN_REDO);
      separate();
      add(MENU_ID_CUT, @"Recortar", edit & CM_EDITFLAG_CAN_CUT);
      add(MENU_ID_COPY, @"Copiar", edit & CM_EDITFLAG_CAN_COPY);
      add(MENU_ID_PASTE, @"Colar", edit & CM_EDITFLAG_CAN_PASTE);
      if (edit & CM_EDITFLAG_CAN_EDIT_RICHLY)
        add(MENU_ID_PASTE_MATCH_STYLE, @"Colar sem formatação", edit & CM_EDITFLAG_CAN_PASTE);
      add(MENU_ID_SELECT_ALL, @"Selecionar tudo", edit & CM_EDITFLAG_CAN_SELECT_ALL);
      if (selection.length) {
        separate();
        add(kSearchSelection, [NSString stringWithFormat:@"Buscar “%@” na web", selection]);
      }
    } else {
      if (link.length) {
        if (IsWebURL(link)) add(kOpenLinkInNewTab, @"Abrir link em nova guia");
        add(kCopyLinkAddress, @"Copiar endereço do link");
        if (IsWebURL(link)) add(kDownloadLink, @"Baixar arquivo do link");
        separate();
      }
      if ((image || video || audio) && source.length) {
        NSString *noun = image ? @"imagem" : video ? @"vídeo" : @"áudio";
        if (IsWebURL(source)) add(kOpenMediaInNewTab, [NSString stringWithFormat:@"Abrir %@ em nova guia", noun]);
        if (image || IsWebURL(source)) add(kSaveMedia, [NSString stringWithFormat:@"Salvar %@…", noun]);
        if (image && params->HasImageContents()) add(kCopyImage, @"Copiar imagem");
        if (IsWebURL(source)) add(kCopyMediaAddress, [NSString stringWithFormat:@"Copiar endereço %@", image ? @"da imagem" : video ? @"do vídeo" : @"do áudio"]);
        separate();
      }
      if (selection.length) {
        add(MENU_ID_COPY, @"Copiar");
        add(kSearchSelection, [NSString stringWithFormat:@"Buscar “%@” na web", selection]);
        separate();
      }
      if (!model->GetCount()) {
        add(MENU_ID_BACK, @"Voltar", browser->CanGoBack());
        add(MENU_ID_FORWARD, @"Avançar", browser->CanGoForward());
        add(MENU_ID_RELOAD, @"Recarregar");
        separate();
        add(MENU_ID_PRINT, @"Imprimir…");
        add(MENU_ID_VIEW_SOURCE, @"Ver código-fonte");
      }
    }
    separate();
    add(kInspect, @"Inspecionar");
  }
  bool OnContextMenuCommand(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame,
                            CefRefPtr<CefContextMenuParams> params, int command, EventFlags flags) override {
    NSString *link = ToNSString(params->GetLinkUrl());
    NSString *source = ToNSString(params->GetSourceUrl());
    auto copy = [](NSString *text) {
      [NSPasteboard.generalPasteboard clearContents];
      [NSPasteboard.generalPasteboard setString:text forType:NSPasteboardTypeString];
    };
    switch (command) {
      case kOpenLinkInNewTab: Send(@"openInBackground", link); return true;
      // The unfiltered address is what the page wrote, as other browsers copy it.
      case kCopyLinkAddress: {
        NSString *unfiltered = ToNSString(params->GetUnfilteredLinkUrl());
        copy(unfiltered.length ? unfiltered : link);
        return true;
      }
      case kDownloadLink: browser->GetHost()->StartDownload(ToCefString(link)); return true;
      case kOpenMediaInNewTab: Send(@"openInBackground", source); return true;
      case kSaveMedia: browser->GetHost()->StartDownload(ToCefString(source)); return true;
      case kCopyImage: browser->GetHost()->DownloadImage(ToCefString(source), false, 0, false, new ImageCopy()); return true;
      case kCopyMediaAddress: copy(source); return true;
      case kSearchSelection: Send(@"searchSelection", ToNSString(params->GetSelectionText())); return true;
      case kInspect: [owner_ showDevTools:identifier_ inspect:YES x:params->GetXCoord() y:params->GetYCoord()]; return true;
      default: return false;
    }
  }
 private:
  // Only the page's own origin can be remembered. A frame from another site speaks for itself and needs a click.
  void OpenExternal(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame, NSString *target, bool userGesture) {
    NSString *pageURL = ToNSString(browser->GetMainFrame()->GetURL());
    NSString *page = URLOrigin(pageURL);
    NSString *requester = frame && !frame->IsMain() ? URLOrigin(ToNSString(frame->GetURL())) : page;
    const bool ownPage = page && [requester isEqualToString:page];
    if (!ownPage && !userGesture) return;
    [owner_ openExternalURL:target tab:identifier_ pageURL:pageURL origin:requester ?: page
               rememberable:ownPage userGesture:userGesture];
  }
  void Send(NSString *kind, NSString *value) {
    [owner_ emit:@{@"kind": kind, @"id": identifier_, @"value": value}];
  }
  __weak LBCEFEngine *owner_;
  __strong NSString *identifier_;
  IMPLEMENT_REFCOUNTING(LumeClient);
};

// The DevTools frontend of one tab. Links it opens go to new tabs, as in Chrome.
class DevToolsClient final : public CefClient,
                             public CefLifeSpanHandler,
                             public CefLoadHandler,
                             public CefDisplayHandler,
                             public CefRequestHandler {
 public:
  DevToolsClient(LBCEFEngine *owner, NSString *identifier) : owner_(owner), identifier_(identifier) {}
  CefRefPtr<CefLifeSpanHandler> GetLifeSpanHandler() override { return this; }
  CefRefPtr<CefLoadHandler> GetLoadHandler() override { return this; }
  CefRefPtr<CefDisplayHandler> GetDisplayHandler() override { return this; }
  CefRefPtr<CefRequestHandler> GetRequestHandler() override { return this; }

  void OnAfterCreated(CefRefPtr<CefBrowser> browser) override {
    [owner_ didCreateDevTools:browser identifier:identifier_ client:this];
  }
  bool DoClose(CefRefPtr<CefBrowser> browser) override {
    // As for a tab: releasing the view ends the browser and reaches OnBeforeClose.
    NSView *view = (__bridge NSView *)browser->GetHost()->GetWindowHandle();
    dispatch_async(dispatch_get_main_queue(), ^{ [view removeFromSuperview]; });
    return true;
  }
  void OnBeforeClose(CefRefPtr<CefBrowser> browser) override {
    [owner_ didCloseDevTools:identifier_ client:this];
  }
  void OnLoadStart(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame, TransitionType transition) override {
    if (!frame->IsMain()) return;
    // Before the frontend's own scripts, which connect as soon as they run.
    frame->ExecuteJavaScript(DevToolsFrontendPatch().UTF8String, "", 0);
    [owner_ devToolsStarted:identifier_ client:this];
  }
  void OnLoadingStateChange(CefRefPtr<CefBrowser> browser, bool loading, bool back, bool forward) override {
    if (!loading) [owner_ devToolsLoaded:identifier_ client:this];
  }
  bool OnConsoleMessage(CefRefPtr<CefBrowser> browser, cef_log_severity_t level, const CefString &message,
                        const CefString &source, int line) override {
    NSString *text = ToNSString(message);
    if (![text hasPrefix:kDevToolsChannel] || text.length <= kDevToolsChannel.length) return false;
    NSString *body = [text substringFromIndex:kDevToolsChannel.length + 1];
    switch ([text characterAtIndex:kDevToolsChannel.length]) {
      case 'm': [owner_ devToolsFrontendSent:body tab:identifier_]; break;
      case 'o': OpenInTab(body); break;
    }
    return true;
  }
  bool OnBeforeBrowse(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame,
                      CefRefPtr<CefRequest> request, bool user, bool redirect) override {
    NSString *target = ToNSString(request->GetURL());
    if (!frame->IsMain() || [target hasPrefix:@"devtools://"]) return false;
    OpenInTab(target);
    return true;
  }
  bool OnBeforePopup(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame, int popupID,
                     const CefString &url, const CefString &name, WindowOpenDisposition disposition,
                     bool userGesture, const CefPopupFeatures &features, CefWindowInfo &info,
                     CefRefPtr<CefClient> &client, CefBrowserSettings &settings,
                     CefRefPtr<CefDictionaryValue> &extra, bool *noAccess) override {
    OpenInTab(ToNSString(url));
    return true;
  }
  bool OnOpenURLFromTab(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame,
                        const CefString &url, WindowOpenDisposition disposition, bool user) override {
    OpenInTab(ToNSString(url));
    return true;
  }
 private:
  void OpenInTab(NSString *url) {
    if (IsWebURL(url)) [owner_ emit:@{@"kind": @"popup", @"id": identifier_, @"value": url}];
  }
  __weak LBCEFEngine *owner_;
  __strong NSString *identifier_;
  IMPLEMENT_REFCOUNTING(DevToolsClient);
};

// The page's side of the protocol, for its DevTools.
class DevToolsObserver final : public CefDevToolsMessageObserver {
 public:
  DevToolsObserver(LBCEFEngine *owner, NSString *identifier) : owner_(owner), identifier_(identifier) {}
  bool OnDevToolsMessage(CefRefPtr<CefBrowser> browser, const void *message, size_t size) override {
    NSString *text = [[NSString alloc] initWithBytes:message length:size encoding:NSUTF8StringEncoding];
    if (text) [owner_ devToolsBackendSent:text tab:identifier_];
    return true;
  }
  void OnDevToolsAgentDetached(CefRefPtr<CefBrowser> browser) override { [owner_ closeDevTools:identifier_]; }
 private:
  __weak LBCEFEngine *owner_;
  __strong NSString *identifier_;
  IMPLEMENT_REFCOUNTING(DevToolsObserver);
};

@implementation LBCEFEngine
- (void)emit:(NSDictionary *)event {
  // Deferring callbacks prevents synchronous store rendering during CEF callbacks.
  dispatch_async(dispatch_get_main_queue(), ^{
    if (self.eventHandler) self.eventHandler(event);
  });
}
- (void)dealloc {
  if (_sheetObserver) [NSNotificationCenter.defaultCenter removeObserver:_sheetObserver];
}

// MARK: Questions for the user

- (void)enqueuePrompt:(LBPrompt *)prompt {
  if (!_prompts) _prompts = [NSMutableArray array];
  [_prompts addObject:prompt];
  [self showNextPrompt];
}

// Shows the oldest question from the tab on screen, once no other sheet covers the window.
- (void)showNextPrompt {
  NSWindow *window = self.dialogWindow;
  if (_shownPrompt || !window || !_prompts.count) return;
  if (!_sheetObserver) {
    __weak LBCEFEngine *weakSelf = self;
    _sheetObserver = [NSNotificationCenter.defaultCenter addObserverForName:NSWindowDidEndSheetNotification
        object:window queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *notification) {
      dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf showNextPrompt]; });
    }];
  }
  if (window.attachedSheet) return;
  NSUInteger index = [_prompts indexOfObjectPassingTest:^BOOL(LBPrompt *prompt, NSUInteger position, BOOL *stop) {
    return [self isActive:prompt.tab];
  }];
  if (index == NSNotFound) return;
  LBPrompt *prompt = _prompts[index];
  [_prompts removeObjectAtIndex:index];
  _shownPrompt = prompt;
  __weak LBCEFEngine *weakSelf = self;
  __weak LBPrompt *weakPrompt = prompt;
  prompt.alert = prompt.present(window, ^{
    LBCEFEngine *engine = weakSelf;
    if (!engine || engine->_shownPrompt != weakPrompt) return;
    engine->_shownPrompt = nil;
    dispatch_async(dispatch_get_main_queue(), ^{ [engine showNextPrompt]; });
  });
}

// The tab went away: its questions are answered no, and a sheet on screen for it closes.
- (void)withdrawPromptsForTab:(NSString *)identifier {
  NSIndexSet *theirs = [_prompts indexesOfObjectsPassingTest:^BOOL(LBPrompt *prompt, NSUInteger position, BOOL *stop) {
    return [prompt.tab isEqualToString:identifier];
  }];
  if (theirs.count) {
    NSArray<LBPrompt *> *withdrawn = [_prompts objectsAtIndexes:theirs];
    [_prompts removeObjectsAtIndexes:theirs];
    for (LBPrompt *prompt in withdrawn) if (prompt.withdraw) prompt.withdraw();
  }
  if ([_shownPrompt.tab isEqualToString:identifier]) [self closeShownPromptAnsweringNo:YES];
}

// Ends the sheet on screen. Its completion sees NSModalResponseAbort and answers nothing itself.
- (void)closeShownPromptAnsweringNo:(BOOL)answerNo {
  LBPrompt *prompt = _shownPrompt;
  if (!prompt) return;
  if (answerNo && prompt.withdraw) prompt.withdraw();
  NSWindow *sheet = prompt.alert.window;
  [sheet.sheetParent endSheet:sheet returnCode:NSModalResponseAbort];
}

- (void)dismissPermissionPrompt:(uint64_t)promptID {
  // CEF withdrew the question, after a navigation for example. It no longer takes an answer.
  NSUInteger index = _prompts ? [_prompts indexOfObjectPassingTest:^BOOL(LBPrompt *prompt, NSUInteger position, BOOL *stop) {
    return prompt.permissionPromptID == promptID;
  }] : NSNotFound;
  if (index != NSNotFound) [_prompts removeObjectAtIndex:index];
  else if (promptID && _shownPrompt.permissionPromptID == promptID) [self closeShownPromptAnsweringNo:NO];
}

// YES when every permission is remembered as allowed, NO when any is remembered as refused, nil to ask.
- (NSNumber *)rememberedAnswer:(NSArray<NSString *> *)permissions origin:(NSString *)origin {
  if (!origin.length || !self.permissionLookup) return nil;
  BOOL allAllowed = YES;
  for (NSString *permission in permissions) {
    NSNumber *answer = self.permissionLookup(origin, permission);
    if (answer && !answer.boolValue) return @NO;
    allAllowed = allAllowed && answer.boolValue;
  }
  return allAllowed ? @YES : nil;
}

// The core stores the decision. The bridge only reports what the user asked to remember.
- (void)emitRememberedDecision:(NSArray<NSString *> *)permissions origin:(NSString *)origin allowed:(BOOL)allowed {
  for (NSString *permission in permissions)
    [self emit:@{@"kind": @"permissionDecided", @"id": @"", @"origin": origin, @"permission": permission, @"allowed": @(allowed)}];
}

// Only a page's own origin can be remembered. An embedded frame is asked about every time.
- (NSAlert *)permissionAlert:(NSString *)title origin:(NSString *)origin page:(NSString *)page
                      detail:(NSString *)detail rememberable:(BOOL)rememberable {
  NSAlert *alert = [[NSAlert alloc] init];
  alert.messageText = title;
  NSString *who = [origin isEqualToString:page] || !page.length ? origin
      : [NSString stringWithFormat:@"%@, dentro de %@,", origin, page];
  alert.informativeText = [NSString stringWithFormat:@"%@ %@", who, detail];
  if (rememberable) {
    alert.showsSuppressionButton = YES;
    alert.suppressionButton.title = @"Lembrar desta decisão para este site";
    alert.suppressionButton.state = NSControlStateValueOff;
  }
  return alert;
}

- (void)requestMedia:(uint32_t)requested origin:(NSString *)rawOrigin tab:(NSString *)identifier browser:(CefRefPtr<CefBrowser>)browser
               frame:(CefRefPtr<CefFrame>)frame callback:(CefRefPtr<CefMediaAccessCallback>)callback {
  const uint32_t devices = CEF_MEDIA_PERMISSION_DEVICE_AUDIO_CAPTURE | CEF_MEDIA_PERMISSION_DEVICE_VIDEO_CAPTURE;
  const uint32_t screen = CEF_MEDIA_PERMISSION_DESKTOP_AUDIO_CAPTURE | CEF_MEDIA_PERMISSION_DESKTOP_VIDEO_CAPTURE;
  NSString *origin = URLOrigin(rawOrigin);
  BOOL (^sameOrigin)(void) = ^BOOL {
    return browser->IsValid() && frame && frame->IsValid() && [URLOrigin(ToNSString(frame->GetURL())) isEqualToString:origin];
  };
  BOOL sharesScreen = (requested & screen) != 0;
  if (!origin || !requested || (requested & ~(devices | screen)) || ((requested & devices) && sharesScreen) ||
      (sharesScreen && !(requested & CEF_MEDIA_PERMISSION_DESKTOP_VIDEO_CAPTURE)) || !sameOrigin()) {
    callback->Cancel();
    return;
  }
  NSString *page = URLOrigin(ToNSString(browser->GetMainFrame()->GetURL()));
  BOOL rememberable = !sharesScreen && [origin isEqualToString:page];
  NSMutableArray<NSString *> *permissions = [NSMutableArray array];
  NSMutableArray<NSString *> *names = [NSMutableArray array];
  if (requested & CEF_MEDIA_PERMISSION_DEVICE_VIDEO_CAPTURE) { [permissions addObject:@"camera"]; [names addObject:@"a câmera"]; }
  if (requested & CEF_MEDIA_PERMISSION_DEVICE_AUDIO_CAPTURE) { [permissions addObject:@"microphone"]; [names addObject:@"o microfone"]; }
  if (NSNumber *answer = rememberable ? [self rememberedAnswer:permissions origin:origin] : nil) {
    if (answer.boolValue) callback->Continue(requested);
    else callback->Cancel();
    return;
  }
  LBPrompt *prompt = [[LBPrompt alloc] init];
  prompt.tab = identifier;
  prompt.withdraw = ^{ callback->Cancel(); };
  prompt.present = ^NSAlert *(NSWindow *window, void (^finished)(void)) {
    if (!sameOrigin()) { callback->Cancel(); finished(); return nil; }
    NSAlert *alert;
    if (sharesScreen) {
      // Alloy has no picker: the whole screen is shared, so the prompt says exactly that.
      alert = [self permissionAlert:@"Compartilhar a tela inteira?" origin:origin page:page
                             detail:@"quer ver a sua tela. Tudo o que aparecer nela, inclusive outras janelas e notificações, ficará visível para o site até o compartilhamento terminar."
                       rememberable:NO];
      [alert addButtonWithTitle:@"Não compartilhar"];
      [alert addButtonWithTitle:@"Compartilhar tela"];
    } else {
      NSString *wanted = [names componentsJoinedByString:@" e "];
      alert = [self permissionAlert:[NSString stringWithFormat:@"Permitir %@?", wanted] origin:origin page:page
                             detail:[NSString stringWithFormat:@"quer usar %@.", wanted] rememberable:rememberable];
      [alert addButtonWithTitle:@"Não permitir"];
      [alert addButtonWithTitle:@"Permitir"];
    }
    [alert beginSheetModalForWindow:window completionHandler:^(NSModalResponse result) {
      finished();
      if (result == NSModalResponseAbort) return;
      BOOL valid = sameOrigin();
      BOOL allowed = result == NSAlertSecondButtonReturn && valid;
      if (allowed) callback->Continue(requested);
      else callback->Cancel();
      if (rememberable && valid && alert.suppressionButton.state == NSControlStateValueOn)
        [self emitRememberedDecision:permissions origin:origin allowed:allowed];
    }];
    return alert;
  };
  [self enqueuePrompt:prompt];
}

- (void)showPermissionPrompt:(uint64_t)promptID origin:(NSString *)rawOrigin requested:(uint32_t)requested tab:(NSString *)identifier
                     browser:(CefRefPtr<CefBrowser>)browser callback:(CefRefPtr<CefPermissionPromptCallback>)callback {
  // Notifications stay off: Alloy has no way to show them, so granting would only mislead the site.
  static const std::vector<std::pair<uint32_t, NSString *>> supported = {
      {CEF_PERMISSION_TYPE_GEOLOCATION, @"location"},
      {CEF_PERMISSION_TYPE_CLIPBOARD, @"clipboard"},
      {CEF_PERMISSION_TYPE_MULTIPLE_DOWNLOADS, @"multipleDownloads"}};
  uint32_t known = 0;
  NSMutableArray<NSString *> *permissions = [NSMutableArray array];
  for (const auto &[flag, name] : supported) {
    known |= flag;
    if (requested & flag) [permissions addObject:name];
  }
  NSString *origin = URLOrigin(rawOrigin);
  NSString *page = URLOrigin(ToNSString(browser->GetMainFrame()->GetURL()));
  if (!origin || !permissions.count || (requested & ~known)) { callback->Continue(CEF_PERMISSION_RESULT_DENY); return; }
  BOOL rememberable = [origin isEqualToString:page];
  if (NSNumber *answer = rememberable ? [self rememberedAnswer:permissions origin:origin] : nil) {
    callback->Continue(answer.boolValue ? CEF_PERMISSION_RESULT_ACCEPT : CEF_PERMISSION_RESULT_DENY);
    return;
  }
  BOOL (^samePage)(void) = ^BOOL {
    return browser->IsValid() && [URLOrigin(ToNSString(browser->GetMainFrame()->GetURL())) isEqualToString:page];
  };
  NSDictionary<NSString *, NSString *> *details = @{
      @"location": @"ver a sua localização",
      @"clipboard": @"ler o texto e as imagens que você copiou",
      @"multipleDownloads": @"baixar vários arquivos de uma vez"};
  NSMutableArray<NSString *> *wants = [NSMutableArray array];
  for (NSString *permission in permissions) [wants addObject:details[permission]];
  NSString *wanted = [wants componentsJoinedByString:@" e "];
  LBPrompt *prompt = [[LBPrompt alloc] init];
  prompt.tab = identifier;
  prompt.permissionPromptID = promptID;
  prompt.withdraw = ^{ callback->Continue(CEF_PERMISSION_RESULT_DISMISS); };
  prompt.present = ^NSAlert *(NSWindow *window, void (^finished)(void)) {
    if (!samePage()) { callback->Continue(CEF_PERMISSION_RESULT_DISMISS); finished(); return nil; }
    NSAlert *alert = [self permissionAlert:[NSString stringWithFormat:@"Permitir que o site possa %@?", wanted]
                                    origin:origin page:page detail:[NSString stringWithFormat:@"quer %@.", wanted]
                              rememberable:rememberable];
    [alert addButtonWithTitle:@"Não permitir"];
    [alert addButtonWithTitle:@"Permitir"];
    [alert beginSheetModalForWindow:window completionHandler:^(NSModalResponse result) {
      finished();
      if (result == NSModalResponseAbort) return;
      if (!samePage()) { callback->Continue(CEF_PERMISSION_RESULT_DISMISS); return; }
      BOOL allowed = result == NSAlertSecondButtonReturn;
      callback->Continue(allowed ? CEF_PERMISSION_RESULT_ACCEPT : CEF_PERMISSION_RESULT_DENY);
      if (rememberable && alert.suppressionButton.state == NSControlStateValueOn)
        [self emitRememberedDecision:permissions origin:origin allowed:allowed];
    }];
    return alert;
  };
  [self enqueuePrompt:prompt];
}

- (void)openExternalURL:(NSString *)url tab:(NSString *)identifier pageURL:(NSString *)pageURL
                 origin:(NSString *)origin rememberable:(BOOL)rememberable userGesture:(BOOL)userGesture {
  NSURL *target = [NSURL URLWithString:url];
  NSString *scheme = URLScheme(url);
  // Out of the CEF callback: opening an app or a sheet must not run inside the navigation.
  dispatch_async(dispatch_get_main_queue(), ^{
    if (!target || !scheme.length) return;
    // Without a click, only the tab on screen may ask, and only once per page, so a page cannot loop.
    if (!userGesture) {
      if (![self isActive:identifier] || [self->_externalAskedPages[identifier] isEqualToString:pageURL]) return;
      if (!self->_externalAskedPages) self->_externalAskedPages = [NSMutableDictionary dictionary];
      self->_externalAskedPages[identifier] = pageURL;
    }
    NSString *permission = [@"external:" stringByAppendingString:scheme];
    NSURL *application = [NSWorkspace.sharedWorkspace URLForApplicationToOpenURL:target];
    if (application && rememberable && [self rememberedAnswer:@[permission] origin:origin].boolValue) {
      [NSWorkspace.sharedWorkspace openURL:target];
      return;
    }
    if (!application && !userGesture) return;
    LBPrompt *prompt = [[LBPrompt alloc] init];
    prompt.tab = identifier;
    prompt.present = ^NSAlert *(NSWindow *window, void (^finished)(void)) {
      NSAlert *alert = [[NSAlert alloc] init];
      if (!application) {
        alert.messageText = @"Nenhum app abre este link";
        alert.informativeText = [NSString stringWithFormat:@"Nenhum app deste Mac abre links “%@:”.", scheme];
        [alert addButtonWithTitle:@"OK"];
        [alert beginSheetModalForWindow:window completionHandler:^(NSModalResponse result) { finished(); }];
        return alert;
      }
      NSString *name = [NSFileManager.defaultManager displayNameAtPath:application.path].stringByDeletingPathExtension;
      alert.messageText = [NSString stringWithFormat:@"Abrir o %@?", name];
      alert.informativeText = [NSString stringWithFormat:@"%@ quer abrir um link “%@:” no %@.",
                               origin ?: @"Esta página", scheme, name];
      [alert addButtonWithTitle:@"Cancelar"];
      [alert addButtonWithTitle:[NSString stringWithFormat:@"Abrir %@", name]];
      if (rememberable && origin) {
        alert.showsSuppressionButton = YES;
        alert.suppressionButton.title = [NSString stringWithFormat:@"Sempre permitir que este site abra links “%@:”", scheme];
        alert.suppressionButton.state = NSControlStateValueOff;
      }
      [alert beginSheetModalForWindow:window completionHandler:^(NSModalResponse result) {
        finished();
        if (result != NSAlertSecondButtonReturn) return;
        [NSWorkspace.sharedWorkspace openURL:target];
        // Only a yes is remembered here. Refusing once does not block the site for good.
        if (rememberable && origin && alert.suppressionButton.state == NSControlStateValueOn)
          [self emitRememberedDecision:@[permission] origin:origin allowed:YES];
      }];
      return alert;
    };
    [self enqueuePrompt:prompt];
  });
}

- (void)requestCredentialsForHost:(NSString *)host port:(int)port realm:(NSString *)realm origin:(NSString *)origin
                            proxy:(BOOL)proxy tab:(NSString *)identifier callback:(CefRefPtr<CefAuthCallback>)callback {
  if (_slots.find(identifier.UTF8String) == _slots.end()) { callback->Cancel(); return; }
  LBPrompt *prompt = [[LBPrompt alloc] init];
  prompt.tab = identifier;
  prompt.withdraw = ^{ callback->Cancel(); };
  prompt.present = ^NSAlert *(NSWindow *window, void (^finished)(void)) {
    NSAlert *alert = [[NSAlert alloc] init];
    NSString *server = proxy ? [NSString stringWithFormat:@"%@:%d", host, port] : host;
    alert.messageText = proxy ? @"Entrar no proxy" : [NSString stringWithFormat:@"Entrar em %@", host];
    NSMutableString *detail = [NSMutableString stringWithFormat:@"%@ pede usuário e senha", proxy ? [@"O proxy " stringByAppendingString:server] : server];
    [detail appendString:realm.length ? [NSString stringWithFormat:@" para “%@”.", realm] : @"."];
    if (!proxy && [URLScheme(origin) isEqualToString:@"http"])
      [detail appendString:@" A conexão não é segura: a senha seguirá sem criptografia."];
    alert.informativeText = detail;
    NSView *fields = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 260, 58)];
    NSTextField *user = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 32, 260, 24)];
    user.placeholderString = @"Usuário";
    user.contentType = NSTextContentTypeUsername;
    NSSecureTextField *password = [[NSSecureTextField alloc] initWithFrame:NSMakeRect(0, 0, 260, 24)];
    password.placeholderString = @"Senha";
    password.contentType = NSTextContentTypePassword;
    [fields addSubview:user];
    [fields addSubview:password];
    user.nextKeyView = password;
    alert.accessoryView = fields;
    [alert addButtonWithTitle:@"Entrar"];
    [alert addButtonWithTitle:@"Cancelar"];
    alert.window.initialFirstResponder = user;
    [alert beginSheetModalForWindow:window completionHandler:^(NSModalResponse result) {
      finished();
      if (result == NSModalResponseAbort) return;
      if (result == NSAlertFirstButtonReturn) callback->Continue(user.stringValue.UTF8String, password.stringValue.UTF8String);
      else callback->Cancel();
    }];
    return alert;
  };
  [self enqueuePrompt:prompt];
}

- (void)didNavigate:(NSString *)identifier url:(NSString *)url {
  // Chromium's deliberate crash URL must never replace the recoverable page.
  if ([url hasPrefix:@"chrome://crash"]) return;
  auto found = _slots.find(identifier.UTF8String);
  if (found != _slots.end() && url.length) found->second->lastPageURL = url.UTF8String;
  [self emit:@{@"kind": @"url", @"id": identifier, @"value": url}];
}
- (void)rendererTerminated:(NSString *)identifier {
  auto found = _slots.find(identifier.UTF8String);
  if (found != _slots.end()) found->second->rendererTerminated = true;
  [self emit:@{@"kind": @"rendererTerminated", @"id": identifier,
               @"value": @"Esta página parou de responder. Recarregue para continuar."}];
}
- (void)preparePopup:(NSString *)identifier opener:(NSString *)opener popupID:(int)popupID
                 info:(CefWindowInfo &)info client:(CefRefPtr<CefClient> &)client {
  auto slot = std::make_unique<TabSlot>();
  slot->container = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 1000, 740)];
  slot->container.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
  slot->client = new LumeClient(self, identifier);
  slot->creating = true;
  slot->popup = true;
  slot->openerID = opener.UTF8String;
  slot->popupID = popupID;
  info.SetAsChild((__bridge CefWindowHandle)slot->container, CefRect(0, 0, 1000, 740));
  info.runtime_style = CEF_RUNTIME_STYLE_ALLOY;
  client = slot->client;
  _slots.emplace(identifier.UTF8String, std::move(slot));
}
- (void)abortPopup:(int)popupID opener:(NSString *)opener {
  for (auto it = _slots.begin(); it != _slots.end(); ++it) {
    const auto &slot = *it->second;
    if (slot.popup && slot.creating && slot.popupID == popupID && slot.openerID == opener.UTF8String) {
      _slots.erase(it);
      if (_quitting && _slots.empty()) [self finishShutdown];
      return;
    }
  }
}
- (void)downloadUpdated:(CefRefPtr<CefDownloadItem>)item tab:(NSString *)identifier
               callback:(CefRefPtr<CefDownloadItemCallback>)callback {
  if (!item->IsValid()) return;
  NSString *downloadID = [NSString stringWithFormat:@"%@:%u", identifier, item->GetId()];
  NSString *state = item->IsComplete() ? @"complete" : item->IsCanceled() ? @"cancelled" :
                    item->IsInProgress() ? @"inProgress" : @"failed";
  if (item->IsInProgress()) {
    if (callback) _downloads[downloadID.UTF8String] = callback;
  } else _downloads.erase(downloadID.UTF8String);
  auto &metadata = _downloadMetadata[downloadID.UTF8String];
  NSString *path = ToNSString(item->GetFullPath());
  if (path.length) metadata.path = path.UTF8String;
  else if (!metadata.path.empty()) path = [NSString stringWithUTF8String:metadata.path.c_str()];
  NSString *filename = path.lastPathComponent;
  if (!filename.length && !metadata.filename.empty())
    filename = [NSString stringWithUTF8String:metadata.filename.c_str()];
  if (!filename.length) filename = ToNSString(item->GetSuggestedFileName()).lastPathComponent;
  if (!filename.length) filename = [NSURL URLWithString:ToNSString(item->GetURL())].lastPathComponent;
  if (!filename.length) filename = @"download";
  metadata.filename = filename.UTF8String;
  [self emit:@{@"kind": @"download", @"id": identifier, @"downloadID": downloadID,
               @"url": ToNSString(item->GetURL()), @"filename": filename, @"path": path,
               @"received": @(item->GetReceivedBytes()), @"total": @(item->GetTotalBytes()), @"state": state}];
  // Retain metadata through repeated terminal updates; CEF can clear its path
  // when cancelled. This records the chosen destination, not file existence.
}
- (void)rememberDownloadName:(NSString *)name item:(CefRefPtr<CefDownloadItem>)item tab:(NSString *)identifier {
  if (!item->IsValid()) return;
  NSString *downloadID = [NSString stringWithFormat:@"%@:%u", identifier, item->GetId()];
  auto &metadata = _downloadMetadata[downloadID.UTF8String];
  if (metadata.path.empty()) metadata.filename = name.UTF8String;
  [self downloadUpdated:item tab:identifier callback:nullptr];
}
- (NSView *)createTab:(NSString *)identifier url:(NSString *)url {
  CEF_REQUIRE_UI_THREAD();
  auto key = std::string(identifier.UTF8String);
  auto found = _slots.find(key);
  if (found != _slots.end()) return found->second->container;
  auto slot = std::make_unique<TabSlot>();
  slot->container = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 1000, 740)];
  slot->container.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
  slot->client = new LumeClient(self, identifier);
  NSView *container = slot->container;
  _slots.emplace(key, std::move(slot));
  [self startTab:identifier url:url];
  return container;
}
- (void)startTab:(NSString *)identifier url:(NSString *)url {
  auto found = _slots.find(identifier.UTF8String);
  if (found == _slots.end()) return;
  auto &slot = *found->second;
  if (slot.browser || slot.creating || slot.closing) return;
  slot.pendingURL = url.UTF8String;
  slot.startedURL = url.UTF8String;
  slot.lastPageURL = url.UTF8String;
  slot.creating = true;
  CefWindowInfo info;
  NSRect bounds = slot.container.bounds;
  info.SetAsChild((__bridge CefWindowHandle)slot.container,
                  CefRect(0, 0, MAX(1, bounds.size.width), MAX(1, bounds.size.height)));
  info.runtime_style = CEF_RUNTIME_STYLE_ALLOY;
  CefBrowserSettings settings;
  settings.background_color = CefColorSetARGB(255, 250, 249, 247);
  if (!CefBrowserHost::CreateBrowser(info, slot.client, url.UTF8String, settings, nullptr,
                                    CefRequestContext::GetGlobalContext())) {
    slot.creating = false;
    [self emit:@{@"kind": @"failure", @"id": identifier, @"value": @"Não foi possível iniciar a página."}];
  }
}
- (void)didCreate:(CefRefPtr<CefBrowser>)browser identifier:(NSString *)identifier {
  auto found = _slots.find(identifier.UTF8String);
  if (found == _slots.end()) { browser->GetHost()->CloseBrowser(true); return; }
  auto &slot = *found->second;
  slot.creating = false;
  slot.browser = browser;
  if (slot.popup) {
    NSString *url = ToNSString(browser->GetMainFrame()->GetURL());
    [self emit:@{@"kind": @"popupCreated", @"id": identifier, @"value": url.length ? url : @"about:blank"}];
  }
  NSView *view = (__bridge NSView *)browser->GetHost()->GetWindowHandle();
  view.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
  view.frame = slot.container.bounds;
  browser->GetHost()->SetAudioMuted(slot.muted);
  browser->GetHost()->SetZoomLevel(slot.zoomLevel);
  if (slot.closing || _quitting) browser->GetHost()->CloseBrowser(false);
  else if (!slot.pendingURL.empty() && slot.pendingURL != slot.startedURL) {
    browser->GetMainFrame()->LoadURL(slot.pendingURL);
  }
  slot.pendingURL.clear();
}
- (void)didClose:(NSString *)identifier {
  [self closeDevTools:identifier];
  _slots.erase(identifier.UTF8String);
  [self withdrawPromptsForTab:identifier];
  [_externalAskedPages removeObjectForKey:identifier];
  // CEF may omit OnBeforePopupAborted after the opener is destroyed.
  // Pending children have not been adopted by the core yet. A late creation
  // reaches didCreate's missing-slot path and is closed immediately.
  for (auto it = _slots.begin(); it != _slots.end();) {
    const auto &slot = *it->second;
    if (slot.popup && slot.creating && slot.openerID == identifier.UTF8String)
      it = _slots.erase(it);
    else ++it;
  }
  [self emit:@{@"kind": @"closed", @"id": identifier}];
  if (_quitting && _slots.empty()) [self finishShutdown];
}
- (void)didCancelClose:(NSString *)identifier {
  auto found = _slots.find(identifier.UTF8String);
  if (found != _slots.end()) found->second->closing = false;
  _quitting = NO;
  [self emit:@{@"kind": @"closeCancelled", @"id": identifier}];
}
- (BOOL)isActive:(NSString *)identifier { return [_activeID isEqualToString:identifier]; }
- (void)activateTab:(NSString *)identifier {
  _activeID = [identifier copy];
  // Questions this tab asked while in the background come up now that it is on screen.
  dispatch_async(dispatch_get_main_queue(), ^{ [self showNextPrompt]; });
  auto found = _slots.find(identifier.UTF8String);
  if (found != _slots.end() && found->second->browser) found->second->browser->GetHost()->SetFocus(true);
}
- (void)navigateTab:(NSString *)identifier url:(NSString *)url {
  auto found = _slots.find(identifier.UTF8String);
  if (found == _slots.end()) return;
  if (found->second->browser) {
    found->second->rendererTerminated = false;
    found->second->browser->GetMainFrame()->LoadURL(url.UTF8String);
  }
  else {
    found->second->pendingURL = url.UTF8String;
    [self startTab:identifier url:url];
  }
}
- (void)goBack:(NSString *)identifier {
  auto slot = _slots.find(identifier.UTF8String);
  if (slot != _slots.end() && slot->second->browser) slot->second->browser->GoBack();
}
- (void)goForward:(NSString *)identifier {
  auto slot = _slots.find(identifier.UTF8String);
  if (slot != _slots.end() && slot->second->browser) slot->second->browser->GoForward();
}
- (void)reload:(NSString *)identifier {
  auto slot = _slots.find(identifier.UTF8String);
  if (slot == _slots.end()) return;
  if (slot->second->browser) {
    if (slot->second->rendererTerminated) {
      slot->second->rendererTerminated = false;
      const auto &url = slot->second->lastPageURL;
      slot->second->browser->GetMainFrame()->LoadURL(url.empty() ? "about:blank" : url);
    } else slot->second->browser->Reload();
  }
  else [self startTab:identifier url:[NSString stringWithUTF8String:slot->second->pendingURL.c_str()]];
}
- (void)stop:(NSString *)identifier {
  auto slot = _slots.find(identifier.UTF8String);
  if (slot != _slots.end() && slot->second->browser) slot->second->browser->StopLoad();
}
- (void)muteTab:(NSString *)identifier muted:(BOOL)muted {
  auto slot = _slots.find(identifier.UTF8String);
  if (slot == _slots.end()) return;
  slot->second->muted = muted;
  if (slot->second->browser) slot->second->browser->GetHost()->SetAudioMuted(muted);
}
- (void)closeTab:(NSString *)identifier {
  auto slot = _slots.find(identifier.UTF8String);
  if (slot == _slots.end()) {
    [self emit:@{@"kind": @"closed", @"id": identifier}];
    return;
  }
  if (slot->second->closing) return;
  if (!slot->second->browser && !slot->second->creating) {
    [self didClose:identifier];
    return;
  }
  slot->second->closing = true;
  if (slot->second->browser) slot->second->browser->GetHost()->CloseBrowser(false);
}
- (void)showDevTools:(NSString *)identifier { [self showDevTools:identifier inspect:NO x:0 y:0]; }
- (void)showDevTools:(NSString *)identifier inspect:(BOOL)inspect x:(int)x y:(int)y {
  auto slot = _slots.find(identifier.UTF8String);
  if (slot == _slots.end() || !slot->second->browser || slot->second->closing || _quitting) return;
  auto &devTools = _devTools[identifier.UTF8String];
  if (devTools.closing) return;
  // Asked before the point moves: the panel narrows the page only once the frontend has loaded.
  if (inspect) [self inspect:identifier x:x y:y];
  if (devTools.container) {
    // Asked again before its frontend loaded: the panel shows it as it is.
    if (devTools.browser && !devTools.announced) {
      devTools.announced = true;
      [self emit:@{@"kind": @"devTools", @"id": identifier, @"open": @YES}];
    }
    if (devTools.browser) devTools.browser->GetHost()->SetFocus(true);
    return;
  }
  auto &page = *slot->second;
  if (!page.devToolsObserver) page.devToolsObserver = page.browser->GetHost()->AddDevToolsMessageObserver(new DevToolsObserver(self, identifier));
  devTools.container = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 440, 740)];
  devTools.container.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
  devTools.client = new DevToolsClient(self, identifier);
  devTools.queued = [NSMutableArray array];
  [self attachDevTools:identifier];
  CefWindowInfo info;
  info.SetAsChild((__bridge CefWindowHandle)devTools.container, CefRect(0, 0, 440, 740));
  info.runtime_style = CEF_RUNTIME_STYLE_ALLOY;
  CefBrowserSettings settings;
  if (!CefBrowserHost::CreateBrowser(info, devTools.client, kDevToolsFrontendURL.UTF8String, settings, nullptr,
                                    CefRequestContext::GetGlobalContext())) {
    [self detachDevTools:devTools tab:identifier];
    _devTools.erase(identifier.UTF8String);
  }
}
- (void)closeDevTools:(NSString *)identifier {
  auto found = _devTools.find(identifier.UTF8String);
  if (found == _devTools.end() || found->second.closing) return;
  found->second.closing = true;
  [self detachDevTools:found->second tab:identifier];
  if (found->second.browser) found->second.browser->GetHost()->CloseBrowser(true);
}
- (NSView *)devToolsView:(NSString *)identifier {
  auto found = _devTools.find(identifier.UTF8String);
  return found == _devTools.end() ? nil : found->second.container;
}

// A protocol command of Lume's own. Its answer never reaches the frontend.
- (void)devToolsCommand:(NSString *)identifier method:(NSString *)method params:(NSDictionary *)params
                session:(const std::string &)session then:(void (^_Nullable)(NSDictionary *reply))then {
  auto slot = _slots.find(identifier.UTF8String);
  if (slot == _slots.end() || !slot->second->browser) return;
  if (!_devToolsRequests) _devToolsRequests = [NSMutableDictionary dictionary];
  const NSInteger requestID = kPrivateRequestBase + (++_devToolsRequestCount % 100000000);
  if (then) _devToolsRequests[@(requestID)] = [then copy];
  NSMutableDictionary *command = [@{@"id": @(requestID), @"method": method, @"params": params ?: @{}} mutableCopy];
  if (!session.empty()) command[@"sessionId"] = [NSString stringWithUTF8String:session.c_str()];
  NSData *data = [NSJSONSerialization dataWithJSONObject:command options:0 error:nil];
  if (data) slot->second->browser->GetHost()->SendDevToolsMessage(data.bytes, data.length);
}
- (void)attachDevTools:(NSString *)identifier {
  __weak LBCEFEngine *weakSelf = self;
  DevToolsClient *client = _devTools[identifier.UTF8String].client.get();
  [self devToolsCommand:identifier method:@"Target.getTargetInfo" params:nil session:"" then:^(NSDictionary *reply) {
    NSString *target = reply[@"result"][@"targetInfo"][@"targetId"];
    if (![target isKindOfClass:NSString.class]) return;
    [weakSelf devToolsCommand:identifier method:@"Target.attachToTarget" params:@{@"targetId": target, @"flatten": @YES}
                      session:"" then:^(NSDictionary *attached) {
      [weakSelf devToolsAttached:identifier session:attached[@"result"][@"sessionId"] client:client];
    }];
  }];
}
- (void)devToolsAttached:(NSString *)identifier session:(NSString *)session client:(DevToolsClient *)client {
  if (![session isKindOfClass:NSString.class] || !session.length) return;
  auto found = _devTools.find(identifier.UTF8String);
  if (found == _devTools.end() || found->second.client.get() != client || found->second.closing) {
    // DevTools closed while attaching: the session goes at once.
    [self devToolsCommand:identifier method:@"Target.detachFromTarget" params:@{@"sessionId": session} session:"" then:nil];
    return;
  }
  found->second.session = session.UTF8String;
  NSArray<NSString *> *queued = found->second.queued;
  found->second.queued = [NSMutableArray array];
  for (NSString *message in queued) [self devToolsFrontendSent:message tab:identifier];
}
- (void)detachDevTools:(DevToolsSlot &)devTools tab:(NSString *)identifier {
  if (!devTools.session.empty()) {
    [self devToolsCommand:identifier method:@"Target.detachFromTarget"
                   params:@{@"sessionId": [NSString stringWithUTF8String:devTools.session.c_str()]} session:"" then:nil];
  }
  devTools.session.clear();
  devTools.revealsNodes = false;
  devTools.overlayRequest = 0;
}

// Finds the node under a point of the page, then has the frontend reveal it, as Chrome's Inspect does.
- (void)inspect:(NSString *)identifier x:(int)x y:(int)y {
  auto slot = _slots.find(identifier.UTF8String);
  if (slot == _slots.end()) return;
  const double zoom = std::pow(1.2, slot->second->zoomLevel);
  auto found = _devTools.find(identifier.UTF8String);
  // Once the frontend reads the page, its session knows the DOM. Before, the root session answers.
  const std::string session = found != _devTools.end() && found->second.revealsNodes ? found->second.session : "";
  __weak LBCEFEngine *weakSelf = self;
  [self devToolsCommand:identifier method:@"DOM.getNodeForLocation"
                 params:@{@"x": @(std::lround(x / zoom)), @"y": @(std::lround(y / zoom)), @"ignorePointerEventsNone": @YES}
                session:session then:^(NSDictionary *reply) {
    NSNumber *node = reply[@"result"][@"backendNodeId"];
    LBCEFEngine *engine = weakSelf;
    if (!engine || ![node isKindOfClass:NSNumber.class]) return;
    auto slot = engine->_devTools.find(identifier.UTF8String);
    if (slot == engine->_devTools.end()) return;
    slot->second.pendingNode = node.intValue;
    [engine revealPendingNode:slot->second];
  }];
}
- (void)revealPendingNode:(DevToolsSlot &)devTools {
  if (!devTools.revealsNodes || !devTools.pendingNode) return;
  NSString *event = [NSString stringWithFormat:@"{\"method\":\"Overlay.inspectNodeRequested\",\"params\":{\"backendNodeId\":%d}}",
                     devTools.pendingNode];
  devTools.pendingNode = 0;
  [self deliver:event to:devTools];
}
- (void)deliver:(NSString *)message to:(DevToolsSlot &)devTools {
  if (!devTools.browser) return;
  NSString *code = [NSString stringWithFormat:@"DevToolsAPI.dispatchMessage(%@)", ScriptLiteral(message)];
  devTools.browser->GetMainFrame()->ExecuteJavaScript(code.UTF8String, "", 0);
}
// The frontend speaks as if it owned the page's root session. Lume gives its messages DevTools' session.
- (void)devToolsFrontendSent:(NSString *)message tab:(NSString *)identifier {
  auto found = _devTools.find(identifier.UTF8String);
  auto slot = _slots.find(identifier.UTF8String);
  if (found == _devTools.end() || found->second.closing || slot == _slots.end() || !slot->second->browser) return;
  auto &devTools = found->second;
  if (TrailingSessionRange(message).location == NSNotFound) {
    if (devTools.session.empty()) { [devTools.queued addObject:message]; return; }
    if (![message hasSuffix:@"}"]) return;
    if ([message rangeOfString:@"\"method\":\"Overlay.enable\""].location != NSNotFound)
      devTools.overlayRequest = ProtocolMessageID(message);
    message = [NSString stringWithFormat:@"%@,\"sessionId\":\"%s\"}", [message substringToIndex:message.length - 1],
               devTools.session.c_str()];
  }
  if (TestingDiagnostics() && FixtureAccessAllowed(slot->second->browser, NO)) {
    NSDictionary *command = [NSJSONSerialization JSONObjectWithData:[message dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
    if ([command[@"method"] isKindOfClass:NSString.class])
      [self emit:@{@"kind": @"devToolsProtocol", @"id": identifier, @"value": command[@"method"]}];
  }
  NSData *data = [message dataUsingEncoding:NSUTF8StringEncoding];
  slot->second->browser->GetHost()->SendDevToolsMessage(data.bytes, data.length);
}
- (void)devToolsBackendSent:(NSString *)message tab:(NSString *)identifier {
  const NSInteger requestID = ProtocolMessageID(message);
  if (requestID >= kPrivateRequestBase) {
    void (^then)(NSDictionary *) = _devToolsRequests[@(requestID)];
    [_devToolsRequests removeObjectForKey:@(requestID)];
    NSDictionary *reply = then ? [NSJSONSerialization JSONObjectWithData:[message dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil] : nil;
    if ([reply isKindOfClass:NSDictionary.class]) then(reply);
    return;
  }
  auto found = _devTools.find(identifier.UTF8String);
  if (found == _devTools.end() || found->second.session.empty() || found->second.closing) return;
  auto &devTools = found->second;
  NSRange trailing = TrailingSessionRange(message);
  // The page's root session belongs to Lume, and other sessions to the frontend as they are.
  if (trailing.location == NSNotFound) return;
  NSString *session = [message substringWithRange:NSMakeRange(trailing.location + 14, trailing.length - 16)];
  const bool own = [session isEqualToString:[NSString stringWithUTF8String:devTools.session.c_str()]];
  if (own) message = [[message substringToIndex:trailing.location] stringByAppendingString:@"}"];
  [self deliver:message to:devTools];
  if (own && requestID && requestID == devTools.overlayRequest) {
    devTools.revealsNodes = true;
    [self revealPendingNode:devTools];
  }
}
- (void)didCreateDevTools:(CefRefPtr<CefBrowser>)browser identifier:(NSString *)identifier client:(DevToolsClient *)client {
  auto found = _devTools.find(identifier.UTF8String);
  if (found == _devTools.end() || found->second.client.get() != client) { browser->GetHost()->CloseBrowser(true); return; }
  found->second.browser = browser;
  NSView *view = (__bridge NSView *)browser->GetHost()->GetWindowHandle();
  view.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
  view.frame = found->second.container.bounds;
  if (found->second.closing || _quitting) browser->GetHost()->CloseBrowser(true);
}
// A frontend reloaded from DevTools itself starts over on a fresh session, as a new window would.
- (void)devToolsStarted:(NSString *)identifier client:(DevToolsClient *)client {
  auto found = _devTools.find(identifier.UTF8String);
  if (found == _devTools.end() || found->second.client.get() != client || found->second.closing) return;
  auto &devTools = found->second;
  if (!devTools.frontendStarted) { devTools.frontendStarted = true; return; }
  if (devTools.session.empty()) return;
  [self detachDevTools:devTools tab:identifier];
  devTools.queued = [NSMutableArray array];
  [self attachDevTools:identifier];
}
- (void)devToolsLoaded:(NSString *)identifier client:(DevToolsClient *)client {
  auto found = _devTools.find(identifier.UTF8String);
  if (found == _devTools.end() || found->second.client.get() != client || found->second.announced || found->second.closing) return;
  found->second.announced = true;
  [self emit:@{@"kind": @"devTools", @"id": identifier, @"open": @YES}];
}
- (void)didCloseDevTools:(NSString *)identifier client:(DevToolsClient *)client {
  auto found = _devTools.find(identifier.UTF8String);
  if (found != _devTools.end() && found->second.client.get() == client) {
    _devTools.erase(found);
    [self emit:@{@"kind": @"devTools", @"id": identifier, @"open": @NO}];
  }
  if (_quitting) [self finishShutdown];
}
- (void)inspectForTesting:(NSString *)identifier x:(int)x y:(int)y {
  auto slot = _slots.find(identifier.UTF8String);
  if (slot != _slots.end() && FixtureAccessAllowed(slot->second->browser, NO)) [self showDevTools:identifier inspect:YES x:x y:y];
}
- (void)find:(NSString *)identifier text:(NSString *)text forward:(BOOL)forward findNext:(BOOL)findNext {
  auto slot = _slots.find(identifier.UTF8String);
  if (slot != _slots.end() && slot->second->browser)
    slot->second->browser->GetHost()->Find(text.UTF8String, forward, false, findNext);
}
- (void)stopFinding:(NSString *)identifier {
  auto slot = _slots.find(identifier.UTF8String);
  if (slot != _slots.end() && slot->second->browser) slot->second->browser->GetHost()->StopFinding(true);
}
- (void)setZoom:(NSString *)identifier level:(double)level {
  auto slot = _slots.find(identifier.UTF8String);
  if (!std::isfinite(level) || slot == _slots.end()) return;
  slot->second->zoomLevel = std::clamp(level, std::log(0.25) / std::log(1.2), std::log(5.0) / std::log(1.2));
  if (slot->second->browser) slot->second->browser->GetHost()->SetZoomLevel(slot->second->zoomLevel);
}
- (void)printPage:(NSString *)identifier {
  auto slot = _slots.find(identifier.UTF8String);
  if (slot != _slots.end() && slot->second->browser) slot->second->browser->GetHost()->Print();
}
- (void)exitFullscreen:(NSString *)identifier {
  auto slot = _slots.find(identifier.UTF8String);
  if (slot != _slots.end() && slot->second->browser) slot->second->browser->GetHost()->ExitFullscreen(true);
}
- (void)cancelDownload:(NSString *)identifier {
  auto found = _downloads.find(identifier.UTF8String);
  // Hold the callback across Cancel, which may synchronously update the map.
  CefRefPtr<CefDownloadItemCallback> callback = found == _downloads.end() ? nullptr : found->second;
  if (callback) callback->Cancel();
}
- (void)runFixtureScript:(NSString *)identifier script:(NSString *)script {
  auto slot = _slots.find(identifier.UTF8String);
  if (slot != _slots.end() && FixtureAccessAllowed(slot->second->browser, NO)) {
    auto frame = slot->second->browser->GetMainFrame();
    frame->ExecuteJavaScript(script.UTF8String, frame->GetURL(), 0);
  }
}
- (void)crashRendererForTesting:(NSString *)identifier {
  auto slot = _slots.find(identifier.UTF8String);
  if (slot != _slots.end() && FixtureAccessAllowed(slot->second->browser, YES))
    slot->second->browser->GetMainFrame()->LoadURL("chrome://crash");
}
- (void)finishShutdown {
  // DevTools closes with its page, but may outlive it briefly.
  if (_flushPending || !_quitting || !_slots.empty() || !_devTools.empty()) return;
  _flushPending = YES;
  _downloads.clear();
  _downloadMetadata.clear();
  CefRefPtr<FlushCompletion> completion = new FlushCompletion(^{ CefQuitMessageLoop(); });
  auto manager = CefCookieManager::GetGlobalManager(nullptr);
  if (!manager || !manager->FlushStore(completion)) CefQuitMessageLoop();
}
- (void)shutdown {
  if (_quitting) return;
  _quitting = YES;
  std::vector<CefRefPtr<CefDownloadItemCallback>> downloads;
  for (const auto &[key, callback] : _downloads) downloads.push_back(callback);
  for (const auto &callback : downloads) callback->Cancel();
  if (_slots.empty()) { [self finishShutdown]; return; }
  std::vector<std::string> identifiers;
  for (const auto &[key, slot] : _slots) identifiers.push_back(key);
  for (const auto &key : identifiers) [self closeTab:[NSString stringWithUTF8String:key.c_str()]];
}
@end

class LumeApp final : public CefApp, public CefBrowserProcessHandler {
 public:
  explicit LumeApp(void (^ready)(void)) : ready_([ready copy]) {}
  CefRefPtr<CefBrowserProcessHandler> GetBrowserProcessHandler() override { return this; }
  void OnContextInitialized() override { ready_(); }
  void OnBeforeCommandLineProcessing(const CefString &processType, CefRefPtr<CefCommandLine> commandLine) override {
    // Spelling follows the Mac's language instead of Chromium's default English dictionary.
    if (processType.empty() && !commandLine->HasSwitch("override-spell-check-lang"))
      commandLine->AppendSwitchWithValue("override-spell-check-lang", PreferredLanguage().UTF8String);
  }
 private:
  __strong void (^ready_)(void);
  IMPLEMENT_REFCOUNTING(LumeApp);
};

int LBRunBrowser(int argc, char **argv, NSString *profilePath, void (^ready)(void)) {
  @autoreleasepool {
    CefScopedLibraryLoader loader;
    if (!loader.LoadInMain()) return 1;
    [LBApplication sharedApplication];
    [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
    CefSettings settings;
    settings.no_sandbox = false;
    CefString(&settings.root_cache_path) = profilePath.UTF8String;
    CefString(&settings.cache_path) = [profilePath stringByAppendingPathComponent:@"Default"].UTF8String;
    CefString(&settings.log_file) = [profilePath stringByAppendingPathComponent:@"chromium.log"].UTF8String;
    settings.log_severity = LOGSEVERITY_WARNING;
    settings.persist_session_cookies = true;
    // Menus, dialogs and the languages sites see follow macOS, as in Safari.
    CefString(&settings.locale) = PreferredLanguage().UTF8String;
    CefString(&settings.accept_language_list) = AcceptLanguages().UTF8String;
    CefMainArgs args(argc, argv);
    CefRefPtr<LumeApp> app = new LumeApp(ready);
    if (!CefInitialize(args, settings, app, nullptr)) return CefGetExitCode();
    CefRunMessageLoop();
    CefShutdown();
    return 0;
  }
}
