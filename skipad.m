/*
 * skipad.m — 通用开屏广告跳过插件（v1.2：网络层拦截主路径）
 *
 * 全谱系覆盖：
 *   L0 网络层拦截   —— hook NSURLSession，广告域名请求直接失败（广告不加载）
 *   L1 视图树点击   —— 标准/倒计时跳过按钮（UIButton sendActions + target-action / UILabel+手势）
 *   L2 WebView JS   —— H5 广告 DOM 匹配 click
 *   L3 Accessibility —— SwiftUI/自绘/部分 Flutter（activate + frame 合成触摸）
 *   L4 触摸合成     —— 环形计时等自绘控件（进程内 UITouch+UIEvent，走 hitTest 链路）
 *   L5 广告窗口关闭 —— v1.1 已禁用（误杀严重，v1.3 严格版再做）
 *   L6 传感器拦截   —— hook 加速度计，摇一摇/反转跳转广告失效
 *   L7 OCR 兜底     —— 截图 + Vision 识别"跳过/关闭"文字坐标 → 合成点击
 *
 * v1.2 修改（针对大厂 App / 滑屏广告 UI 层无效）：
 *   - 新增 L0 网络层拦截：广告域名请求直接返回失败，广告不加载（主路径）
 *   - 新增落盘诊断日志（沙盒 Documents/skipad.log）
 *   - 保留 v1.1：L5 禁用、命中多轮观察、关键词收紧
 *
 * 工程规则（trollfools-inject-dev skill）：
 *   - constructor 只做日志 + dispatch + 轻量 hook 注册，不碰 UIKit（SIGILL）
 *   - 全部 UI 操作在主线程、App 启动后执行
 */

#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>
#import <Vision/Vision.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <dispatch/dispatch.h>

#define PLUGIN_TAG "SkipAd"

#ifdef ENABLE_DEBUG_UI
#define UI_VISIBLE 1
#else
#define UI_VISIBLE 0
#endif

#define LOGF(fmt, ...) fprintf(stderr, "[" PLUGIN_TAG "] " fmt "\n", ##__VA_ARGS__)

static void logMsg(NSString *fmt, ...) {
    va_list args;
    va_start(args, fmt);
    NSLogv([@"[" PLUGIN_TAG "] " stringByAppendingString:fmt], args);
    va_end(args);
}

/* ========== 落盘诊断日志（沙盒 Documents/skipad.log） ========== */
static void logToFile(NSString *fmt, ...) {
    va_list args;
    va_start(args, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:args];
    va_end(args);

    @try {
        NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
        NSString *path = [[paths.firstObject stringByAppendingPathComponent:@"skipad.log"] copy];
        NSString *line = [NSString stringWithFormat:@"[%@] %@\n",
                          [NSDateFormatter localizedStringFromDate:[NSDate date]
                                                         dateStyle:NSDateFormatterShortStyle
                                                         timeStyle:NSDateFormatterMediumStyle],
                          msg];
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
        if (!fh) {
            [line writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
        } else {
            [fh seekToEndOfFile];
            [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
            [fh closeFile];
        }
    } @catch (NSException *e) {
    }
}

#define LOG(fmt, ...) do { logMsg(fmt, ##__VA_ARGS__); logToFile(fmt, ##__VA_ARGS__); } while (0)

/* ========== L0: 网络层拦截（广告域名请求直接失败） ========== */
static BOOL isAdRequest(NSURLRequest *req) {
    NSString *host = req.URL.host.lowercaseString;
    if (!host.length) return NO;
    static NSArray *adDomains = @[
        @"pangolin-sdk.com", @"csjplatform.com", @"pglstatp.com", @"pangle.cn",
        @"gdt.qq.com", @"cpro.baidu.com", @"pos.baidu.com", @"cpro.cn",
        @"ksad.ksyun.com", @"ksapisrv.com",
        @"adservice.google.com", @"doubleclick.net", @"googleadservices.com",
        @"mtg.com", @"inmobi.com", @"adsmogo.com", @"adview.cn",
        @"snssdk.com", @"ibytedtos.com", @"byteimg.com"
    ];
    for (NSString *d in adDomains) {
        if ([host containsString:d]) return YES;
    }
    return NO;
}

/* hook -[NSURLSession dataTaskWithRequest:completionHandler:]：广告请求直接失败 */
typedef NSURLSessionDataTask *(*DataTaskWithReqIMP)(id, SEL, NSURLRequest *, id);
static DataTaskWithReqIMP g_origDataTaskWithRequest;

static NSURLSessionDataTask *hookDataTaskWithRequest(id self, SEL _cmd, NSURLRequest *request, id completionHandler) {
    if (request && isAdRequest(request)) {
        LOG(@"L0 BLOCKED ad request: %@", request.URL.absoluteString);
        NSError *err = [NSError errorWithDomain:NSURLErrorDomain
                                           code:NSURLErrorCannotConnectToHost
                                       userInfo:@{NSLocalizedDescriptionKey: @"blocked by SkipAd"}];
        if (completionHandler) {
            void (^cb)(NSData *, NSURLResponse *, NSError *) = completionHandler;
            cb(nil, nil, err);
        }
        NSURLSession *session = (NSURLSession *)self;
        NSURLSessionDataTask *dummy = [session dataTaskWithURL:[NSURL URLWithString:@"about:blank"]];
        [dummy cancel];
        return dummy;
    }
    return g_origDataTaskWithRequest(self, _cmd, request, completionHandler);
}

static void hookNSURLSession(void) {
    Class cls = [NSURLSession class];
    SEL sel = NSSelectorFromString(@"dataTaskWithRequest:completionHandler:");
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return;
    g_origDataTaskWithRequest = (DataTaskWithReqIMP)method_getImplementation(m);
    IMP newImp = imp_implementationWithBlock(^(id self, NSURLRequest *req, id cb) {
        return hookDataTaskWithRequest(self, sel, req, cb);
    });
    method_setImplementation(m, newImp);
    LOG(@"L0 hooked: NSURLSession dataTaskWithRequest");
}

/* ========== 关键词匹配 ========== */
static BOOL kwMatch(NSString *text) {
    if (!text.length) return NO;
    NSString *t = [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!t.length) return NO;

    NSString *s = [t stringByReplacingOccurrencesOfString:@" " withString:@""];
    if (s.length <= 2) {
        if ([s containsString:@"×"] || [s containsString:@"X"] || [s containsString:@"x"]) {
            return YES;
        }
        return NO;
    }

    static NSArray *kws;
    if (!kws) kws = @[@"跳过", @"关闭", @"Skip", @"Close", @"关闭广告", @"跳过广告"];
    for (NSString *kw in kws) {
        if ([t rangeOfString:kw].location != NSNotFound) return YES;
    }
    return NO;
}

/* ========== L4: 触摸合成（进程内 UITouch+UIEvent） ========== */
static void synthesizeTapAtPoint(CGPoint point, UIWindow *window) {
    if (!window) return;
    UIView *hitView = [window hitTest:point withEvent:nil];
    if (!hitView) return;

    @try {
        UITouch *touch = [[UITouch alloc] init];
        [touch setValue:@(UITouchPhaseBegan) forKey:@"phase"];
        [touch setValue:[NSValue valueWithCGPoint:point] forKey:@"_locationInWindow"];
        [touch setValue:[NSValue valueWithCGPoint:point] forKey:@"_previousLocationInWindow"];
        [touch setValue:window forKey:@"_window"];
        [touch setValue:hitView forKey:@"_view"];
        [touch setValue:@(1) forKey:@"tapCount"];
        [touch setValue:@(CACurrentMediaTime()) forKey:@"_timestamp"];
        [touch setValue:@(YES) forKey:@"_isTap"];

        UIEvent *event = [[UIEvent alloc] init];
        [event setValue:@(0) forKey:@"_type"];
        NSSet *touches = [NSSet setWithObject:touch];

        [hitView touchesBegan:touches withEvent:event];
        [touch setValue:@(UITouchPhaseEnded) forKey:@"phase"];
        [hitView touchesEnded:touches withEvent:event];
        logMsg(@"SKIP HIT: synthesized tap at (%.0f,%.0f) on %@",
               point.x, point.y, NSStringFromClass(hitView.class));
    } @catch (NSException *e) {
    }
}

static void synthesizeTapOnView(UIView *view, UIWindow *window) {
    CGRect f = view.frame;
    CGPoint center = CGPointMake(CGRectGetMidX(f), CGRectGetMidY(f));
    CGPoint winPoint = [view convertPoint:center toView:window];
    synthesizeTapAtPoint(winPoint, window);
}

/* ========== L2: WebView JS 注入 ========== */
static BOOL injectSkipScript(WKWebView *webView) {
    NSString *js =
        @"(function(){"
         "var kws=['跳过','关闭','Skip','Close','跳过广告','关闭广告'];"
         "var els=document.querySelectorAll('*');"
         "for(var i=0;i<els.length;i++){"
         "var el=els[i];var t=(el.textContent||'').trim();"
         "if(t.length>0&&t.length<24&&el.offsetParent!==null){"
         "for(var j=0;j<kws.length;j++){"
         "if(t.indexOf(kws[j])>=0){el.click();return 'skip:'+t;}}}}}"
         "return '';})()";

    __block NSString *result = @"";
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    dispatch_async(dispatch_get_main_queue(), ^{
        [webView evaluateJavaScript:js completionHandler:^(id r, NSError *e) {
            result = [r isKindOfClass:[NSString class]] ? r : @"";
            dispatch_semaphore_signal(sem);
        }];
    });
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 1 * NSEC_PER_SEC));
    return result.length > 0;
}

/* ========== 手势触发 ========== */
static BOOL triggerTapGesture(UIView *view) {
    UIView *cur = view;
    int guard = 0;
    while (cur && guard++ < 6) {
        for (UIGestureRecognizer *g in cur.gestureRecognizers) {
            if ([g isKindOfClass:[UITapGestureRecognizer class]] && g.enabled) {
                @try {
                    [g setValue:@(UIGestureRecognizerStateRecognized) forKey:@"state"];
                    return YES;
                } @catch (NSException *e) {
                    return NO;
                }
            }
        }
        cur = cur.superview;
    }
    return NO;
}

/* ========== 点击增强 ========== */
static void fireButtonClick(UIButton *btn) {
    if (!btn.isEnabled) {
        btn.enabled = YES;
    }
    [btn sendActionsForControlEvents:UIControlEventTouchUpInside];

    NSSet *targets = btn.allTargets;
    for (id target in targets) {
        NSArray *actions = [btn actionsForTarget:target forControlEvent:UIControlEventTouchUpInside];
        for (NSString *selName in actions) {
            SEL sel = NSSelectorFromString(selName);
            if (sel) {
                ((void (*)(id, SEL, id))objc_msgSend)(target, sel, btn);
            }
        }
    }
}

/* ========== L3: accessibility 扫描 ========== */
static BOOL scanAccessibilityOfView(UIView *view) {
    NSArray *elements = view.accessibilityElements;
    if (!elements.count) return NO;

    for (id el in elements) {
        NSString *label = nil;
        if ([el isKindOfClass:[UIAccessibilityElement class]]) {
            label = ((UIAccessibilityElement *)el).accessibilityLabel;
        } else if ([el isKindOfClass:[UIView class]]) {
            label = ((UIView *)el).accessibilityLabel;
        }
        if (label.length && kwMatch(label)) {
            if ([el respondsToSelector:@selector(accessibilityActivate)]) {
                if ([el accessibilityActivate]) {
                    logMsg(@"SKIP HIT: accessibility activate [%@]", label);
                    return YES;
                }
            }
            CGRect af = [el accessibilityFrame];
            CGPoint c = CGPointMake(CGRectGetMidX(af), CGRectGetMidY(af));
            UIWindow *w = view.window;
            if (w) {
                synthesizeTapAtPoint(c, w);
                logMsg(@"SKIP HIT: accessibility synthesized tap [%@]", label);
                return YES;
            }
        }
    }
    return NO;
}

/* ========== L5: 广告窗口关闭（v1.1 已禁用——误杀严重，等 v1.3 严格版） ========== */
static BOOL closeAdWindow(UIWindow *win) {
    return NO;   /* v1.1 禁用 */
}

/* ========== L7: OCR 兜底（截图 + Vision 识别跳过文字 → 合成点击） ========== */
static BOOL gOcrCooldown = NO;   /* 防 OCR 频繁触发 */
static int  gOcrCount = 0;

static BOOL ocrFindAndTap(UIWindow *window) {
    if (!window || window.hidden) return NO;
    if (gOcrCooldown) return NO;
    if (gOcrCount >= 6) return NO;   /* 窗口期最多 6 次 */
    gOcrCooldown = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 0.5 * NSEC_PER_SEC),
                   dispatch_get_main_queue(), ^{ gOcrCooldown = NO; });

    UIGraphicsImageRenderer *renderer =
        [[UIGraphicsImageRenderer alloc] initWithSize:window.bounds.size];
    UIImage *img = [renderer imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        [window drawViewHierarchyInRect:window.bounds afterScreenUpdates:NO];
    }];
    if (!img) return NO;

    __block BOOL hit = NO;
    VNRecognizeTextRequest *req = [[VNRecognizeTextRequest alloc] initWithCompletionHandler:^(VNRequest *request, NSError *error) {
        for (VNRecognizedTextObservation *obs in request.results) {
            VNRecognizedText *top = [obs topCandidates:1].firstObject;
            if (!top) continue;
            if (kwMatch(top.string)) {
                CGRect bbox = obs.boundingBox;   /* 归一化，左下原点 */
                CGFloat w = window.bounds.size.width;
                CGFloat h = window.bounds.size.height;
                CGFloat x = bbox.origin.x * w;
                CGFloat y = (1.0 - bbox.origin.y - bbox.size.height) * h;
                CGPoint p = CGPointMake(x + bbox.size.width * w / 2,
                                        y + bbox.size.height * h / 2);
                synthesizeTapAtPoint(p, window);
                logMsg(@"SKIP HIT: OCR [%@] -> tap (%.0f,%.0f)", top.string, p.x, p.y);
                hit = YES;
                break;
            }
        }
    }];
    req.recognitionLevel = VNRequestTextRecognitionLevelFast;
    req.recognitionLanguages = @[@"zh-Hans", @"en"];

    VNImageRequestHandler *handler = [[VNImageRequestHandler alloc] initWithCGImage:img.CGImage options:@{}];
    NSError *err = nil;
    [handler performRequests:@[req] error:&err];
    if (hit) gOcrCount++;
    return hit;
}

/* ========== 递归扫描视图树 ========== */
static BOOL scanViewRecursive(UIView *view, int depth) {
    if (!view || depth > 25) return NO;
    if (view.hidden || view.alpha < 0.05) return NO;

    /* L2: WebView 广告 */
    if ([view isKindOfClass:[WKWebView class]]) {
        if (injectSkipScript((WKWebView *)view)) {
            logMsg(@"SKIP HIT: webview js clicked");
            return YES;
        }
    }

    /* L1: UIButton */
    if ([view isKindOfClass:[UIButton class]]) {
        UIButton *btn = (UIButton *)view;
        NSString *t = btn.currentTitle;
        if (!t.length) t = btn.titleLabel.text;
        if (!t.length) t = btn.titleLabel.attributedText.string;
        if (!t.length) t = btn.accessibilityLabel;
        if (kwMatch(t)) {
            fireButtonClick(btn);
            if (btn.window) synthesizeTapOnView(btn, btn.window);
            logMsg(@"SKIP HIT: clicked button [%@]", t);
            return YES;
        }
    }

    /* L1: UILabel + 手势 */
    if ([view isKindOfClass:[UILabel class]]) {
        UILabel *lbl = (UILabel *)view;
        NSString *t = lbl.text.length ? lbl.text : lbl.attributedText.string;
        if (kwMatch(t)) {
            if (triggerTapGesture(lbl)) {
                logMsg(@"SKIP HIT: triggered gesture on label [%@]", t);
                return YES;
            }
            if (lbl.window) {
                synthesizeTapOnView(lbl, lbl.window);
                logMsg(@"SKIP HIT: synthesized tap on label [%@]", t);
                return YES;
            }
        }
    } else if (view.accessibilityLabel.length && kwMatch(view.accessibilityLabel)) {
        if (triggerTapGesture(view)) {
            logMsg(@"SKIP HIT: triggered gesture on [%@]", view.accessibilityLabel);
            return YES;
        }
        if (view.window) {
            synthesizeTapOnView(view, view.window);
            logMsg(@"SKIP HIT: synthesized tap on [%@]", view.accessibilityLabel);
            return YES;
        }
    }

    /* L3: accessibility 树 */
    if (scanAccessibilityOfView(view)) return YES;

    for (UIView *sub in view.subviews) {
        @try {
            if (scanViewRecursive(sub, depth + 1)) return YES;
        } @catch (NSException *e) {
        }
    }
    return NO;
}

/* ========== 扫描所有 window ========== */
static BOOL scanAllWindows(void) {
    NSSet *scenes = [UIApplication sharedApplication].connectedScenes;
    for (UIScene *scene in scenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        UIWindowScene *ws = (UIWindowScene *)scene;
        for (UIWindow *win in ws.windows) {
            @try {
                /* L5 已禁用（v1.1） */
                if (scanViewRecursive(win, 0)) return YES;
            } @catch (NSException *e) {
            }
        }
    }
    /* L7: OCR 兜底 */
    for (UIScene *scene in scenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        UIWindowScene *ws = (UIWindowScene *)scene;
        UIWindow *mainWin = nil;
        for (UIWindow *win in ws.windows) {
            if (win.windowLevel <= UIWindowLevelNormal && !win.hidden) {
                mainWin = win;
                break;
            }
        }
        if (mainWin && ocrFindAndTap(mainWin)) return YES;
    }
    return NO;
}

/* ========== L6: 拦截加速度计 ========== */
static void hookCMMotionManager(void) {
    Class cls = NSClassFromString(@"CMMotionManager");
    if (!cls) return;

    @try {
        SEL sel1 = NSSelectorFromString(@"startAccelerometerUpdates");
        Method m1 = class_getInstanceMethod(cls, sel1);
        if (m1) {
            method_setImplementation(m1, imp_implementationWithBlock(^(id self) {}));
            LOG(@"L6 hooked: CMMotionManager startAccelerometerUpdates");
        }
        SEL sel2 = NSSelectorFromString(@"startAccelerometerUpdatesToQueue:withHandler:");
        Method m2 = class_getInstanceMethod(cls, sel2);
        if (m2) {
            method_setImplementation(m2, imp_implementationWithBlock(^(id self, id q, id h) {}));
            LOG(@"L6 hooked: CMMotionManager startAccelerometerUpdatesToQueue");
        }
        SEL sel3 = NSSelectorFromString(@"startDeviceMotionUpdates");
        Method m3 = class_getInstanceMethod(cls, sel3);
        if (m3) {
            method_setImplementation(m3, imp_implementationWithBlock(^(id self) {}));
            LOG(@"L6 hooked: CMMotionManager startDeviceMotionUpdates");
        }
        SEL sel4 = NSSelectorFromString(@"startGyroUpdates");
        Method m4 = class_getInstanceMethod(cls, sel4);
        if (m4) {
            method_setImplementation(m4, imp_implementationWithBlock(^(id self) {}));
            LOG(@"L6 hooked: CMMotionManager startGyroUpdates");
        }
    } @catch (NSException *e) {
        LOGF("L6 hook failed: %s", e.name.UTF8String ?: "?");
    }
}

/* ========== 命中弹窗（Debug 验证用） ========== */
static void showHitAlert(void) {
    if (!UI_VISIBLE) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *win = nil;
        NSSet *scenes = [UIApplication sharedApplication].connectedScenes;
        for (UIScene *scene in scenes) {
            if ([scene isKindOfClass:[UIWindowScene class]]) {
                win = [(UIWindowScene *)scene windows].firstObject;
                if (win) break;
            }
        }
        UIViewController *vc = win.rootViewController;
        if (!vc) return;
        while (vc.presentedViewController) vc = vc.presentedViewController;

        UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"SkipAd"
                                                                    message:@"已跳过广告（插件生效）"
                                                             preferredStyle:UIAlertControllerStyleAlert];
        [vc presentViewController:ac animated:NO completion:^{
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1.5 * NSEC_PER_SEC),
                           dispatch_get_main_queue(), ^{
                [ac dismissViewControllerAnimated:NO completion:nil];
            });
        }];
    });
}

/* ========== 窗口期扫描（防重） ==========
 * v1.1：命中后不立即停——广告 SDK 可能二次拉起（百度网盘实测），最多 3 次 */
static BOOL gScanRunning = NO;

static void startScanWindow(int maxSeconds) {
    if (gScanRunning) return;
    gScanRunning = YES;

    dispatch_async(dispatch_get_main_queue(), ^{
        __block int attempts = 0;
        __block int hitCount = 0;
        const int maxAttempts = maxSeconds * 5;
        LOG(@"SCAN START (window=%ds)", maxSeconds);

        NSTimer *timer = [NSTimer scheduledTimerWithTimeInterval:0.2 repeats:YES block:^(NSTimer *tm) {
            if (scanAllWindows()) {
                hitCount++;
                if (hitCount == 1) {
                    showHitAlert();
                }
                LOG(@"SCAN HIT #%d (watching for re-show)", hitCount);
                if (hitCount >= 3) {
                    [tm invalidate];
                    gScanRunning = NO;
                    LOG(@"SCAN END (3 hits, stop)");
                }
                return;
            }
            if (++attempts >= maxAttempts) {
                [tm invalidate];
                gScanRunning = NO;
                LOG(@"SCAN END (window expired, hits=%d)", hitCount);
            }
        }];
        [timer setFireDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
    });
}

/* ========== 通知回调（热启动补充） ========== */
static void on_active(CFNotificationCenterRef center, void *observer,
                      CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    startScanWindow(5);
}

/* ========== 入口 ========== */
__attribute__((constructor))
static void init(void) {
    LOGF("PLUGIN LOADED");

    /* L0 网络层 + L6 传感器：constructor 后主线程安装 */
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 0.1 * NSEC_PER_SEC),
                   dispatch_get_main_queue(), ^{
        LOG(@"PLUGIN LOADED (main)");
        hookNSURLSession();
        hookCMMotionManager();
    });

    /* 冷启动扫描：0.3s 启动 */
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 0.3 * NSEC_PER_SEC),
                   dispatch_get_main_queue(), ^{
        startScanWindow(12);
    });

    /* 热启动 */
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                    NULL, on_active,
                                    CFSTR("UIApplicationDidBecomeActiveNotification"),
                                    NULL, CFNotificationSuspensionBehaviorDeliverImmediately);

    LOGF("constructor done, waiting for app launch");
}
