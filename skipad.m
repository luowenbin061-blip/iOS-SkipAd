/*
 * skipad.m — 通用开屏广告跳过插件（v0.4：视图层 + WebView JS + Accessibility + 时序优化）
 *
 * 注入方式：TrollFools，目标：任何带开屏广告的 App（已实测生效：电影猎手等）
 * 机制：dylib 加载后直接轮询所有 window，三层识别：
 *   L1 视图树：UIButton（sendActions + target-action 兜底）/ UILabel+手势
 *   L2 WebView：WKWebView 注入 JS，DOM 匹配"跳过/关闭"并 click（覆盖 H5 广告）
 *   L3 Accessibility：遍历 accessibility 树，匹配后 accessibilityActivate
 *
 * v0.4 改动（针对短倒计时广告 54321/321 错过时机）：
 *   - 扫描启动提前：1.0s -> 0.3s
 *   - 轮询间隔缩短：0.5s -> 0.2s，首轮 0.1s
 *   - 广告一出现（倒计时刚开始）就能抓到按钮立即点
 *
 * v0.3 改动：去加载弹窗、加 WebView JS 注入、加 Accessibility 扫描
 *
 * 工程规则（trollfools-inject-dev skill）：
 *   - constructor 只做日志 + dispatch，不碰 UIKit/objc runtime（SIGILL）
 *   - 全部 UI 操作在主线程、App 启动后执行
 */

#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>
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
         "if(t.indexOf(kws[j])>=0){el.click();return 'skip:'+t;}}}}"
         "return '';})()";

    __block NSString *result = @"";
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    dispatch_async(dispatch_get_main_queue(), ^{
        [webView evaluateJavaScript:js completionHandler:^(id r, NSError *e) {
            result = [r isKindOfClass:[NSString class]] ? r : @"";
            dispatch_semaphore_signal(sem);
        }];
    });
    /* 最多等 1 秒（JS 执行 + 返回），不阻塞太久 */
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

/* ========== L3: 当前 view 的 accessibility 元素扫描 ========== */
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
                [el accessibilityActivate];
                logMsg(@"SKIP HIT: accessibility activate [%@]", label);
                return YES;
            }
        }
    }
    return NO;
}

/* ========== 递归扫描视图树 ========== */
static BOOL scanViewRecursive(UIView *view, int depth) {
    if (!view || depth > 25) return NO;
    if (view.hidden || view.alpha < 0.05) return NO;

    /* L2: WebView 广告（H5 渲染，视图树内无按钮） */
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
            logMsg(@"SKIP HIT: clicked button [%@]", t);
            return YES;
        }
    }

    /* L1: UILabel + 手势 */
    if ([view isKindOfClass:[UILabel class]]) {
        UILabel *lbl = (UILabel *)view;
        NSString *t = lbl.text.length ? lbl.text : lbl.attributedText.string;
        if (kwMatch(t) && triggerTapGesture(lbl)) {
            logMsg(@"SKIP HIT: triggered gesture on label [%@]", t);
            return YES;
        }
    } else if (view.accessibilityLabel.length && kwMatch(view.accessibilityLabel)) {
        if (triggerTapGesture(view)) {
            logMsg(@"SKIP HIT: triggered gesture on [%@]", view.accessibilityLabel);
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
                if (scanViewRecursive(win, 0)) return YES;
            } @catch (NSException *e) {
            }
        }
    }
    return NO;
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
 * v0.4 时序优化：0.3s 启动 + 0.2s 轮询，短倒计时广告（3 2 1）也能第一时间抓到 */
static BOOL gScanRunning = NO;

static void startScanWindow(int maxSeconds) {
    if (gScanRunning) return;
    gScanRunning = YES;

    dispatch_async(dispatch_get_main_queue(), ^{
        __block int attempts = 0;
        const int maxAttempts = maxSeconds * 5;   /* 0.2s 间隔 */
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
        /* 首次执行等 0.1s */
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

    /* 全部延迟到主线程执行（constructor 阶段禁止碰 UIKit/objc runtime）。
     * v0.4：0.3s 就启动扫描（原 1.0s），短广告不晚点 */
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 0.3 * NSEC_PER_SEC),
                   dispatch_get_main_queue(), ^{
        /* 冷启动扫描：直接驱动，不依赖系统通知 */
        startScanWindow(12);
    });

    /* 热启动（回前台弹开屏的 App） */
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                    NULL, on_active,
                                    CFSTR("UIApplicationDidBecomeActiveNotification"),
                                    NULL, CFNotificationSuspensionBehaviorDeliverImmediately);

    LOGF("constructor done, waiting for app launch");
}
