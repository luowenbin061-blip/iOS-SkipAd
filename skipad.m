/*
 * skipad.m — 通用开屏广告跳过插件（v0.2 诊断版：视图层）
 *
 * 注入方式：TrollFools，目标：任何带开屏广告的 App（首个测试对象：电影猎手）
 * 机制：dylib 加载后直接轮询所有 window 视图树，匹配"跳过/关闭/X"等关键词，
 *       找到后触发点击（UIButton 强制 enabled + sendActions + target-action 兜底）。
 *
 * v0.2 改动（针对"完全没效果"的诊断）：
 *   - 可见验证分两层：启动 1s 弹"插件已加载"（确认 dylib 是否加载）；
 *     命中跳过弹"已跳过广告"（确认点击生效）——一次测试就能区分卡在哪层
 *   - 扫描不再依赖 Darwin 通知（部分 App 收不到），constructor 直接 dispatch 轮询
 *   - 通知保留作热启动补充，加防重
 *   - 点击加 target-action 兜底（部分 SDK 按钮 sendActions 不触发）
 *
 * 工程规则（trollfools-inject-dev skill）：
 *   - constructor 只做日志 + dispatch，不碰 UIKit/objc runtime（SIGILL）
 *   - 全部 UI 操作在主线程、App 启动后执行
 *
 * 已知局限（第三版再补）：
 *   - 只覆盖 UIKit 原生控件；Flutter/Unity/WebView 内广告走后续层
 *   - 关键词简易匹配，未做位置/尺寸加权评分
 */

#import <UIKit/UIKit.h>
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

    /* 纯符号/短标题（"X"、"×"）：要求去掉空白后长度 <= 2 */
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

/* ========== 手势触发（UILabel/自定义视图） ========== */
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

/* ========== 点击增强：sendActions + target-action 兜底 ========== */
static void fireButtonClick(UIButton *btn) {
    if (!btn.isEnabled) {
        btn.enabled = YES;
    }
    [btn sendActionsForControlEvents:UIControlEventTouchUpInside];

    /* 兜底：部分广告 SDK 的按钮 sendActions 不触发，直接调注册的 target-action */
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

/* ========== 递归扫描视图树 ========== */
static BOOL scanViewRecursive(UIView *view, int depth) {
    if (!view || depth > 25) return NO;
    if (view.hidden || view.alpha < 0.05) return NO;

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

/* ========== 弹窗工具 ========== */
static void showAlert(NSString *msg) {
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
                                                                    message:msg
                                                             preferredStyle:UIAlertControllerStyleAlert];
        [vc presentViewController:ac animated:NO completion:^{
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1.8 * NSEC_PER_SEC),
                           dispatch_get_main_queue(), ^{
                [ac dismissViewControllerAnimated:NO completion:nil];
            });
        }];
    });
}

static void showLoadedAlert(void) {
    logMsg(@"PLUGIN LOADED visible check");
    showAlert(@"插件已加载（等待开屏广告…）");
}

static void showHitAlert(void) {
    logMsg(@"SKIP HIT visible check");
    showAlert(@"已跳过广告（插件生效）");
}

/* ========== 窗口期扫描（防重） ========== */
static BOOL gScanRunning = NO;

static void startScanWindow(int maxSeconds) {
    if (gScanRunning) return;
    gScanRunning = YES;

    dispatch_async(dispatch_get_main_queue(), ^{
        __block int attempts = 0;
        const int maxAttempts = maxSeconds * 2;
        logMsg(@"SCAN START (window=%ds)", maxSeconds);

        NSTimer *timer = [NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES block:^(NSTimer *tm) {
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
        [timer setFireDate:[NSDate dateWithTimeIntervalSinceNow:0.3]];
    });
}

/* ========== 通知回调（热启动补充；冷启动由 constructor 直接驱动） ========== */
static void on_active(CFNotificationCenterRef center, void *observer,
                      CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    startScanWindow(5);
}

/* ========== 入口 ========== */
__attribute__((constructor))
static void init(void) {
    LOGF("PLUGIN LOADED");

    /* 全部延迟到主线程执行（constructor 阶段禁止碰 UIKit/objc runtime） */
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1.0 * NSEC_PER_SEC),
                   dispatch_get_main_queue(), ^{
        /* 可见验证 1：确认 dylib 加载 */
        showLoadedAlert();
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
