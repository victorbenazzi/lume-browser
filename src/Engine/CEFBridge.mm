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

static NSString *URLOrigin(NSString *url) {
  NSURLComponents *parts = [NSURLComponents componentsWithString:url];
  if (!parts.scheme.length || !parts.host.length) return nil;
  NSString *port = parts.port ? [NSString stringWithFormat:@":%@", parts.port] : @"";
  return [NSString stringWithFormat:@"%@://%@%@", parts.scheme.lowercaseString,
          parts.host.lowercaseString, port];
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
};

struct DownloadMetadata {
  std::string filename;
  std::string path;
};

@interface LBCEFEngine () {
  std::map<std::string, std::unique_ptr<TabSlot>> _slots;
  BOOL _quitting;
  BOOL _flushPending;
  NSString *_activeID;
  std::map<std::string, CefRefPtr<CefDownloadItemCallback>> _downloads;
  std::map<std::string, DownloadMetadata> _downloadMetadata;
}
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
@end

class LumeClient final : public CefClient,
                         public CefLifeSpanHandler,
                         public CefDisplayHandler,
                         public CefLoadHandler,
                         public CefRequestHandler,
                         public CefFocusHandler,
                         public CefJSDialogHandler,
                         public CefDownloadHandler,
                         public CefFindHandler,
                         public CefPermissionHandler {
 public:
  LumeClient(LBCEFEngine *owner, NSString *identifier) : owner_(owner), identifier_(identifier) {}
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
    if (!urls.empty()) Send(@"favicon", ToNSString(urls.front()));
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
    if (!frame->IsMain()) return false;
    const auto url = request->GetURL().ToString();
    const bool allowed = url.starts_with("https://") || url.starts_with("http://") ||
                         url == "about:blank" || url.starts_with("chrome://") ||
                         url.starts_with("devtools://");
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
    NSURLComponents *parts = [NSURLComponents componentsWithString:target];
    if (target.length && ![target isEqualToString:@"about:blank"] &&
        ![parts.scheme.lowercaseString isEqualToString:@"https"] &&
        ![parts.scheme.lowercaseString isEqualToString:@"http"]) return true;
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
    if (user) Send(@"popup", ToNSString(url));
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
    const uint32_t supported = CEF_MEDIA_PERMISSION_DEVICE_AUDIO_CAPTURE |
                               CEF_MEDIA_PERMISSION_DEVICE_VIDEO_CAPTURE;
    NSString *requestOrigin = URLOrigin(ToNSString(origin));
    if (!requested || (requested & ~supported) || !frame || !frame->IsValid() ||
        ![URLOrigin(ToNSString(frame->GetURL())) isEqualToString:requestOrigin]) {
      callback->Cancel();
      return true;
    }
    NSMutableArray<NSString *> *devices = [NSMutableArray array];
    if (requested & CEF_MEDIA_PERMISSION_DEVICE_AUDIO_CAPTURE) [devices addObject:@"microfone"];
    if (requested & CEF_MEDIA_PERMISSION_DEVICE_VIDEO_CAPTURE) [devices addObject:@"câmera"];
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = @"Permitir acesso à mídia?";
    alert.informativeText = [NSString stringWithFormat:@"%@ solicita %@. A permissão vale somente para esta solicitação.",
                             requestOrigin, [devices componentsJoinedByString:@" e "]];
    [alert addButtonWithTitle:@"Não permitir"];
    [alert addButtonWithTitle:@"Permitir"];
    NSWindow *window = ((__bridge NSView *)browser->GetHost()->GetWindowHandle()).window ?: owner_.dialogWindow;
    if (!window || window.attachedSheet) { callback->Cancel(); return true; }
    [alert beginSheetModalForWindow:window completionHandler:^(NSModalResponse result) {
      BOOL sameOrigin = browser->IsValid() && frame->IsValid() &&
          [URLOrigin(ToNSString(frame->GetURL())) isEqualToString:requestOrigin];
      if (result == NSAlertSecondButtonReturn && sameOrigin) callback->Continue(requested);
      else callback->Cancel();
    }];
    return true;
  }
  bool OnShowPermissionPrompt(CefRefPtr<CefBrowser> browser, uint64_t promptID,
                               const CefString &origin, uint32_t requested,
                               CefRefPtr<CefPermissionPromptCallback> callback) override {
    // Other capabilities require a dedicated policy and UI before being granted.
    callback->Continue(CEF_PERMISSION_RESULT_DENY);
    return true;
  }
 private:
  void Send(NSString *kind, NSString *value) {
    [owner_ emit:@{@"kind": kind, @"id": identifier_, @"value": value}];
  }
  __weak LBCEFEngine *owner_;
  __strong NSString *identifier_;
  IMPLEMENT_REFCOUNTING(LumeClient);
};

@implementation LBCEFEngine
- (void)emit:(NSDictionary *)event {
  // Deferring callbacks prevents synchronous store rendering during CEF callbacks.
  dispatch_async(dispatch_get_main_queue(), ^{
    if (self.eventHandler) self.eventHandler(event);
  });
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
  _slots.erase(identifier.UTF8String);
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
- (void)showDevTools:(NSString *)identifier {
  auto slot = _slots.find(identifier.UTF8String);
  if (slot == _slots.end() || !slot->second->browser) return;
  CefWindowInfo info;
  CefBrowserSettings settings;
  slot->second->browser->GetHost()->ShowDevTools(info, nullptr, settings, CefPoint());
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
  if (_flushPending || !_quitting || !_slots.empty()) return;
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
    CefMainArgs args(argc, argv);
    CefRefPtr<LumeApp> app = new LumeApp(ready);
    if (!CefInitialize(args, settings, app, nullptr)) return CefGetExitCode();
    CefRunMessageLoop();
    CefShutdown();
    return 0;
  }
}
