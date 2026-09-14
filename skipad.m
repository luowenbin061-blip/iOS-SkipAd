/*
 * skipad.m — 通用开屏广告跳过插件（第一版 MVP：视图层）
 *
 * 注入方式：TrollFools，目标：任何带开屏广告的 App（首个测试对象：电影猎手）
 * 机制：启动后窗口期内定时扫描所有 window 的视图树，匹配"跳过/关闭/X"等关键词，
 *       找到后触发点击（UIButton 强制 enabled + sendActions；手势视图触发 gesture）。
 *
 * 工程规则（来自 trollfools-inject-dev skill 的经验，必须遵守）：
 *   1. constructor 只做日志 + 注册通知观察者，禁止调用 objc runtime / UIKit API（SIGILL）
 *   2. 全部实际逻辑在启动完成通知回调内、dispatch 到主线程执行
 *   3. 可见验证：命中"跳过"并点击成功后弹窗 1.5 秒（weak 加载失败静默无痕，必须可见验证）
 *   4. 分层信号：PLUGIN LOADED（dylib 加载）→ SCAN START（扫描启动）
 *      → SKIP HIT（真实命中并点击）→ SCAN END（窗口期结束）
 *
 * 已知局限（第二版再补）：
 *   - 只覆盖 UIKit 原生控件（UIButton / UILabel+手势）；Flutter/Unity/WebView 内广告走后续层
 *   - 关键词匹配为简易版，未做位置/尺寸加权评分（后续加，防误点）
 *   - 倒计时按钮处理：强制 enabled=YES 后 sendActions
 */

#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <dispatch/dispatch.h>

#define PLUGIN_TAG "SkipAd"

/* ========== 诊断开关 ========== */
/* Debug 构建弹窗（可见验证）；Release 构建去掉 -DENABLE_DEBUG_UI 即可关闭 */
#ifdef ENABLE_DEBUG_UI
#define UI_VISIBLE 1
#else
#define UI_VISIBLE 0
#endif

/* ========== 基础日志（constructor 阶段只能用 fprintf，避免 objc runtime） ========== */
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

    /* 纯符号/短标题（"X"、"×"）：要求去掉空白后长度 <= 2，避免误匹配"XX商城" */
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

/* ========== 手势触发（UILabel/自定义视图的跳过区域） ========== */
static BOOL triggerTapGesture(UIView *view) {
    UIView *cur = view;
    int guard = 0;
    while (cur && guard++ < 6) {
        for (UIGestureRecognizer *g in cur.gestureRecognizers) {
            if ([g isKindOfClass:[UITapGestureRecognizer class]] && g.enabled) {
                /* 强制把手势置为 recognized，触发其 target/action */
                @try {
                    [g setValue:@(UIGestureRecognizerStateRecognized) forKey:@"state"];
                    return YES;
                } @catch (NSException *e) {
                    /* state 只读：MVP 阶段放弃该手势视图，第二版用触摸合成处理 */
                    return NO;
                }
            }
        }
        cur = cur.superview;
    }
    return NO;
}

/* ========== 递归扫描视图树 ========== */
static BOOL scanViewRecursive(UIView *view, int depth) {
    if (!view || depth > 25) return NO;
    if (view.hidden || view.alpha < 0.05) return NO;

    /* 1) UIButton：currentTitle / titleLabel.text / accessibilityLabel */
    if ([view isKindOfClass:[UIButton class]]) {
        UIButton *btn = (UIButton *)view;
        NSString *t = btn.currentTitle;
        if (!t.length) t = btn.titleLabel.text;
        if (!t.length) t = btn.titleLabel.attributedText.string;
        if (!t.length) t = btn.accessibilityLabel;
        if (kwMatch(t)) {
            /* 倒计时禁用按钮：强制 enabled 再发事件 */
            if (!btn.isEnabled) {
                btn.enabled = YES;
            }
            [btn sendActionsForControlEvents:UIControlEventTouchUpInside];
            logMsg(@"SKIP HIT: clicked button [%@]", t);
            return YES;
        }
    }

    /* 2) UILabel：文本匹配 + 手势 */
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

    /* 递归子视图（@try 保护枚举期视图树变动） */
    for (UIView *sub in view.subviews) {
        @try {
            if (scanViewRecursive(sub, depth + 1)) return YES;
        } @catch (NSException *e) {
            /* 视图树遍历期间被修改，跳过该分支 */
        }
    }
    return NO;
}

/* ========== 扫描所有 window（keyWindow 已废弃，必须走 connectedScenes） ========== */
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

/* ========== 可见验证弹窗（UIAlertController，主线程调用，1.5 秒自动消失） ========== */
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

/* ========== 窗口期扫描（0.5s 间隔，冷启动 10s / 热启动 5s） ========== */
static void startScanWindow(int maxSeconds) {
    dispatch_async(dispatch_get_main_queue(), ^{
        __block int attempts = 0;
        const int maxAttempts = maxSeconds * 2;
        logMsg(@"SCAN START (window=%ds)", maxSeconds);

        NSTimer *timer = [NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES block:^(NSTimer *tm) {
            if (scanAllWindows()) {
                [tm invalidate];
                showHitAlert();
                logMsg(@"SCAN END (hit)");
                return;
            }
            if (++attempts >= maxAttempts) {
                [tm invalidate];
                logMsg(@"SCAN END (window expired, no hit)");
            }
        }];
        /* 首次执行等 0.3s，给 App 启动渲染留时间 */
        [timer setFireDate:[NSDate dateWithTimeIntervalSinceNow:0.3]];
    });
}

/* ========== 通知回调 ========== */
/* Darwin 通知中心回调不保证主线程，内部必须 dispatch 主线程 */
static void on_launch(CFNotificationCenterRef center, void *observer,
                      CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    startScanWindow(10);
}

static void on_active(CFNotificationCenterRef center, void *observer,
                      CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    /* 热启动（回前台）：也开一个短窗口，覆盖"回前台弹开屏"的 App */
    startScanWindow(5);
}

/* ========== 入口 ========== */
__attribute__((constructor))
static void init(void) {
    LOGF("PLUGIN LOADED");

    /* 只注册通知观察者（CoreFoundation API，constructor 阶段安全） */
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                    NULL, on_launch,
                                    CFSTR("UIApplicationDidFinishLaunchingNotification"),
                                    NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                    NULL, on_active,
                                    CFSTR("UIApplicationDidBecomeActiveNotification"),
                                    NULL, CFNotificationSuspensionBehaviorDeliverImmediately);

    LOGF("constructor done, waiting for app launch");
}
