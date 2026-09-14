/*
 * skipad.m — 通用开屏广告跳过插件（v1.0 全盘版）
 *
 * 全谱系覆盖：
 *   L1 视图树点击   —— 标准/倒计时跳过按钮（UIButton sendActions + target-action / UILabel+手势）
 *   L2 WebView JS   —— H5 广告 DOM 匹配 click
 *   L3 Accessibility —— SwiftUI/自绘/部分 Flutter（activate + frame 合成触摸）
 *   L4 触摸合成     —— 环形计时等自绘控件（进程内 UITouch+UIEvent，走 hitTest 链路）
 *   L5 广告窗口关闭 —— 高层级非主窗口（独立广告窗口）直接隐藏
 *   L6 传感器拦截   —— hook 加速度计，摇一摇/反转跳转广告失效
 *   L7 OCR 兜底     —— 截图 + Vision 识别"跳过/关闭"文字坐标 → 合成点击（图片按钮/自绘文字）
 *
 * 时序：0.3s 启动扫描 + 0.2s 轮询（短倒计时广告第一时间抓）
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
    if (!kws) kws = @[@"跳过", @"关闭", @"Skip", @"Close", @"关闭广告", @"跳过广告", @"广告"];
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
         "var kws=['跳过','关闭','Skip','Close','跳过广告','关闭广告','广告'];"
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

/* ========== L5: 广告窗口直接关闭（高层级非主窗口） ========== */
static BOOL closeAdWindow(UIWindow *win) {
    if (win.windowLevel <= UIWindowLevelNormal) return NO;
    NSString *cls = NSStringFromClass(win.class);
    /* 排除键盘/系统浮层 */
    if ([cls containsString:@"Keyboard"] || [cls containsString:@"TextEffect"]
        || [cls containsString:@"Editing"] || [cls containsString:@"CalloutBar"]) {
        return NO;
    }
    @try {
        win.hidden = YES;
        logMsg(@"SKIP HIT: closed ad window %@ (level=%.0f)", cls, (double)win.windowLevel);
        return YES;
    } @catch (NSException *e) {
        return NO;
    }
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
                /* L5: 独立广告窗口直接关闭 */
                if (closeAdWindow(win)) return YES;
                /* L1-L4: 视图树/WebView/Accessibility/触摸合成 */
                if (scanViewRecursive(win, 0)) return YES;
            } @catch (NSException *e) {
            }
        }
    }
    /* L7: OCR 兜底（L1-L5 全失败时，用主 window 截图识别） */
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

/* ========== L6: 拦截加速度计（摇一摇/反转跳转广告失效） ========== */
static void hookCMMotionManager(void) {
    Class cls = NSClassFromString(@"CMMotionManager");
    if (!cls) return;

    @try {
        /* startAccelerometerUpdates: 置空 */
        SEL sel1 = NSSelectorFromString(@"startAccelerometerUpdates");
        Method m1 = class_getInstanceMethod(cls, sel1);
        if (m1) {
            method_setImplementation(m1, imp_implementationWithBlock(^(id self) {}));
            logMsg(@"L6 hooked: CMMotionManager startAccelerometerUpdates");
        }
        /* startAccelerometerUpdatesToQueue:withHandler: 置空 */
        SEL sel2 = NSSelectorFromString(@"startAccelerometerUpdatesToQueue:withHandler:");
        Method m2 = class_getInstanceMethod(cls, sel2);
        if (m2) {
            method_setImplementation(m2, imp_implementationWithBlock(^(id self, id q, id h) {}));
            logMsg(@"L6 hooked: CMMotionManager startAccelerometerUpdatesToQueue");
        }
        /* startDeviceMotionUpdates: 置空（部分 SDK 用这个） */
        SEL sel3 = NSSelectorFromString(@"startDeviceMotionUpdates");
        Method m3 = class_getInstanceMethod(cls, sel3);
        if (m3) {
            method_setImplementation(m3, imp_implementationWithBlock(^(id self) {}));
            logMsg(@"L6 hooked: CMMotionManager startDeviceMotionUpdates");
        }
        /* startGyroUpdates: 置空 */
        SEL sel4 = NSSelectorFromString(@"startGyroUpdates");
        Method m4 = class_getInstanceMethod(cls, sel4);
        if (m4) {
            method_setImplementation(m4, imp_implementationWithBlock(^(id self) {}));
            logMsg(@"L6 hooked: CMMotionManager startGyroUpdates");
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

/* ========== 窗口期扫描（防重） ========== */
static BOOL gScanRunning = NO;

static void startScanWindow(int maxSeconds) {
    if (gScanRunning) return;
    gScanRunning = YES;

    dispatch_async(dispatch_get_main_queue(), ^{
        __block int attempts = 0;
        const int maxAttempts = maxSeconds * 5;
        logMsg(@"SCAN START (window=%ds)", maxSeconds);

        NSTimer *timer = [NSTimer scheduledTimerWithTimeInterval:0.2 repeats:YES block:^(NSTimer *tm) {
            if (scanAllWindows()) {
                [tm invalidate];
                gScanRunning = NO;
                showHitAlert();
                logMsg(@"SCAN END (hit)");
                return;
            }
            if (++attempts >= maxAttempts) {
                [tm invalidate];
                gScanRunning = NO;
                logMsg(@"SCAN END (window expired, no hit)");
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

    /* L6 传感器拦截：constructor 后主线程安装（CMMotionManager hook 用 runtime，安全） */
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 0.1 * NSEC_PER_SEC),
                   dispatch_get_main_queue(), ^{
        hookCMMotionManager();
    });

    /* 冷启动扫描：0.3s 启动，直接驱动不依赖通知 */
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
