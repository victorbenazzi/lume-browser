#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

// Only Foundation/AppKit types cross into Swift. CEF stays private to the adapter.
@interface LBCEFEngine : NSObject
@property(nonatomic, copy, nullable) void (^eventHandler)(NSDictionary<NSString *, id> *event);
@property(nonatomic, weak, nullable) NSWindow *dialogWindow;
- (NSView *)createTab:(NSString *)identifier url:(NSString *)url;
- (void)activateTab:(NSString *)identifier;
- (void)navigateTab:(NSString *)identifier url:(NSString *)url;
- (void)goBack:(NSString *)identifier;
- (void)goForward:(NSString *)identifier;
- (void)reload:(NSString *)identifier;
- (void)stop:(NSString *)identifier;
- (void)muteTab:(NSString *)identifier muted:(BOOL)muted;
- (void)closeTab:(NSString *)identifier;
- (void)showDevTools:(NSString *)identifier;
- (void)find:(NSString *)identifier text:(NSString *)text forward:(BOOL)forward findNext:(BOOL)findNext;
- (void)stopFinding:(NSString *)identifier;
- (void)setZoom:(NSString *)identifier level:(double)level;
- (void)printPage:(NSString *)identifier;
- (void)cancelDownload:(NSString *)identifier;
- (void)runFixtureScript:(NSString *)identifier script:(NSString *)script;
- (void)crashRendererForTesting:(NSString *)identifier;
- (void)shutdown;
@end

// This function owns the CEF/AppKit main loop until orderly shutdown completes.
#ifdef __cplusplus
extern "C" {
#endif
int LBRunBrowser(int argc, char *_Nullable *_Nonnull argv, NSString *profilePath,
                 void (^ready)(void));
#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END
