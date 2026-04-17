// WCMHQManager.m
// 朋友圈高画质 - 配置管理与首次提示

#import "WCMHQManager.h"

static NSString *const kWCMHQEnabledKey       = @"WCMHQEnabled";
static NSString *const kWCMHQHasShownAlertKey = @"WCMHQHasShownAlert";
static NSString *const kWCMHQSuiteName        = @"com.wcmhq.prefs";

// 开关变化监听状态（静态变量）
static BOOL gWCMHQObservingStarted = NO;
static BOOL gWCMHQLastKnownEnabled = NO;

// 独立 suite NSUserDefaults：作为权威存储源，避免被微信 plist 或 WCPluginsMgr 覆盖
static NSUserDefaults *WCMHQ_suiteDefaults(void) {
    static NSUserDefaults *suite = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        suite = [[NSUserDefaults alloc] initWithSuiteName:kWCMHQSuiteName];
        if (!suite) suite = [NSUserDefaults standardUserDefaults];
    });
    return suite;
}

@implementation WCMHQManager

#pragma mark - 开关读写

+ (BOOL)isEnabled {
    NSUserDefaults *suite = WCMHQ_suiteDefaults();
    // suite 有值 → 以 suite 为准（权威源）
    if ([suite objectForKey:kWCMHQEnabledKey] != nil) {
        return [suite boolForKey:kWCMHQEnabledKey];
    }
    // suite 没值 → 迁移 standardUserDefaults 的旧值过来
    BOOL legacy = [[NSUserDefaults standardUserDefaults] boolForKey:kWCMHQEnabledKey];
    [suite setBool:legacy forKey:kWCMHQEnabledKey];
    return legacy;
}

+ (void)setEnabled:(BOOL)enabled {
    // 权威源：suite
    [WCMHQ_suiteDefaults() setBool:enabled forKey:kWCMHQEnabledKey];
    // 同步 standard：供 WCPluginsMgr / 第三方脚本读取到正确状态
    NSUserDefaults *def = [NSUserDefaults standardUserDefaults];
    [def setBool:enabled forKey:kWCMHQEnabledKey];
    [def synchronize];
}

// 供 %ctor 调用：把 suite 里的权威值强制写回 standard
// 用于对抗 WCPluginsMgr registerSwitch 时可能把 key 重置为 default
+ (void)syncAuthoritativeValueToStandard {
    BOOL on = [self isEnabled];
    [[NSUserDefaults standardUserDefaults] setBool:on forKey:kWCMHQEnabledKey];
}

#pragma mark - 开关变化监听（插件收纳器等外部来源）

+ (void)startObservingSwitchChanges {
    if (gWCMHQObservingStarted) return;
    gWCMHQObservingStarted = YES;
    gWCMHQLastKnownEnabled = [self isEnabled];
    // 使用 NSUserDefaultsDidChangeNotification 兼容性最好，不依赖 KVO
    [[NSNotificationCenter defaultCenter] addObserver:(id)self
                                             selector:@selector(_wcmhq_userDefaultsDidChange:)
                                                 name:NSUserDefaultsDidChangeNotification
                                               object:nil];
}

+ (void)_wcmhq_userDefaultsDidChange:(NSNotification *)note {
    // 外部（WCPluginsMgr / 插件菜单）改写 standard 时，同步到 suite 作为权威源
    NSUserDefaults *stdDef = [NSUserDefaults standardUserDefaults];
    BOOL stdOn  = [stdDef boolForKey:kWCMHQEnabledKey];
    NSUserDefaults *suite = WCMHQ_suiteDefaults();
    BOOL suiteOn = [suite boolForKey:kWCMHQEnabledKey];
    if (stdOn != suiteOn) {
        // 以 standard 的新值为用户意图（因为外部组件通常写 standard）
        [suite setBool:stdOn forKey:kWCMHQEnabledKey];
    }

    BOOL newOn = [self isEnabled];
    if (newOn == gWCMHQLastKnownEnabled) return;
    gWCMHQLastKnownEnabled = newOn;
    // 仅在开启时弹提示，关闭时静默（不打扰用户）
    if (!newOn) return;
    // 延迟到 actionSheet / 收纳器页面完全收起后再弹窗，
    // 避免与正在消失的 presenter 冲突导致弹窗一闪而过
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.45 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [WCMHQManager showFirstTimeAlertIfNeededInController:nil];
    });
}

#pragma mark - 首次开启提示

+ (void)showFirstTimeAlertIfNeededInController:(UIViewController *)vc {
    NSUserDefaults *def = [NSUserDefaults standardUserDefaults];
    // 仅首次开启弹一次，后续关再开不再提示
    if ([def boolForKey:kWCMHQHasShownAlertKey]) return;

    // 用空 message 占位，后面通过 attributedMessage 完全接管内容
    UIAlertController *alert =
        [UIAlertController alertControllerWithTitle:@""
                                            message:@""
                                     preferredStyle:UIAlertControllerStyleAlert];

    @try {
        // ── 标题富文本 ──
        NSMutableAttributedString *titleAttr = [[NSMutableAttributedString alloc] init];

        // 居中段落
        NSMutableParagraphStyle *centerPS = [[NSMutableParagraphStyle alloc] init];
        centerPS.alignment = NSTextAlignmentCenter;
        centerPS.lineSpacing = 2;

        NSDictionary *titleStyle = @{
            NSFontAttributeName:            [UIFont boldSystemFontOfSize:17],
            NSForegroundColorAttributeName: [UIColor labelColor],
            NSParagraphStyleAttributeName:  centerPS,
        };
        [titleAttr appendAttributedString:
            [[NSAttributedString alloc] initWithString:@"朋友圈高画质 已开启 ✅"
                                            attributes:titleStyle]];
        [alert setValue:titleAttr forKey:@"attributedTitle"];

        // ── 正文富文本 ──
        NSMutableAttributedString *body = [[NSMutableAttributedString alloc] init];

        // 基础样式
        UIFont *baseFont     = [UIFont systemFontOfSize:13];
        UIFont *boldFont     = [UIFont boldSystemFontOfSize:13];
        UIFont *smallFont    = [UIFont systemFontOfSize:12];
        UIColor *textColor   = [UIColor labelColor];
        UIColor *grayColor   = [UIColor secondaryLabelColor];
        UIColor *accentColor = [UIColor systemBlueColor];
        UIColor *redColor    = [UIColor systemRedColor];

        // 左对齐段落
        NSMutableParagraphStyle *leftPS = [[NSMutableParagraphStyle alloc] init];
        leftPS.alignment       = NSTextAlignmentLeft;
        leftPS.lineSpacing     = 4;
        leftPS.paragraphSpacing = 2;

        // 列表段落（带首行缩进）
        NSMutableParagraphStyle *listPS = [[NSMutableParagraphStyle alloc] init];
        listPS.alignment           = NSTextAlignmentLeft;
        listPS.lineSpacing         = 3;
        listPS.paragraphSpacing    = 1;
        listPS.headIndent          = 12;
        listPS.firstLineHeadIndent = 0;

        // 红色警告段落
        NSMutableParagraphStyle *warnPS = [[NSMutableParagraphStyle alloc] init];
        warnPS.alignment       = NSTextAlignmentCenter;
        warnPS.lineSpacing     = 4;
        warnPS.paragraphSpacing = 2;

        // ▎使用方式 标题
        [body appendAttributedString:
            [[NSAttributedString alloc] initWithString:@"使用方式\n"
                                            attributes:@{
                NSFontAttributeName:            boldFont,
                NSForegroundColorAttributeName: accentColor,
                NSParagraphStyleAttributeName:  leftPS,
            }]];

        // 使用方式内容
        [body appendAttributedString:
            [[NSAttributedString alloc] initWithString:
                @"开启后，朋友圈相机菜单将多出一项：\n"
                @"「从手机相册选择（高画质）」\n\n"
                @"从该入口选图/选视频发布\n"
                @"即走高画质流程\n\n"
                @"走官方「从手机相册选择」不受影响\n\n"
                                            attributes:@{
                NSFontAttributeName:            baseFont,
                NSForegroundColorAttributeName: textColor,
                NSParagraphStyleAttributeName:  leftPS,
            }]];

        // ▎注意事项 标题（红色）
        [body appendAttributedString:
            [[NSAttributedString alloc] initWithString:@"⚠️ 注意事项\n"
                                            attributes:@{
                NSFontAttributeName:            boldFont,
                NSForegroundColorAttributeName: redColor,
                NSParagraphStyleAttributeName:  leftPS,
            }]];

        // 异常列表
        [body appendAttributedString:
            [[NSAttributedString alloc] initWithString:
                @"如出现以下任一异常：\n"
                @"  · 微信崩溃 / 闪退\n"
                @"  · 朋友圈发布失败 / 卡死\n"
                @"  · 视频画面拉伸 / 播放异常\n"
                @"  · 图片显示错误\n\n"
                                            attributes:@{
                NSFontAttributeName:            smallFont,
                NSForegroundColorAttributeName: grayColor,
                NSParagraphStyleAttributeName:  listPS,
            }]];

        // 底部红色警告
        [body appendAttributedString:
            [[NSAttributedString alloc] initWithString:
                @"请立即关闭本插件开关\n或直接卸载本插件以恢复正常使用"
                                            attributes:@{
                NSFontAttributeName:            boldFont,
                NSForegroundColorAttributeName: redColor,
                NSParagraphStyleAttributeName:  warnPS,
            }]];

        [alert setValue:body forKey:@"attributedMessage"];
    } @catch (NSException *e) {}

    [alert addAction:[UIAlertAction actionWithTitle:@"我知道了"
                                              style:UIAlertActionStyleDefault
                                            handler:nil]];

    UIViewController *presenter = vc ?: [self topViewController];
    if (presenter) {
        [presenter presentViewController:alert animated:YES completion:nil];
    }

    [def setBool:YES forKey:kWCMHQHasShownAlertKey];
    [def synchronize];
}

#pragma mark - 顶层 VC 工具

+ (UIViewController *)topViewController {
    UIWindow *window = nil;
    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if ([scene isKindOfClass:[UIWindowScene class]]
                && scene.activationState == UISceneActivationStateForegroundActive) {
                UIWindowScene *ws = (UIWindowScene *)scene;
                for (UIWindow *w in ws.windows) {
                    if (w.isKeyWindow) { window = w; break; }
                }
                if (window) break;
            }
        }
    }
    if (!window) {
        window = UIApplication.sharedApplication.keyWindow;
    }
    if (!window) return nil;

    UIViewController *root = window.rootViewController;
    while (root.presentedViewController) {
        root = root.presentedViewController;
    }
    if ([root isKindOfClass:[UINavigationController class]]) {
        UIViewController *visible = ((UINavigationController *)root).visibleViewController;
        if (visible) root = visible;
    }
    if ([root isKindOfClass:[UITabBarController class]]) {
        UIViewController *selected = ((UITabBarController *)root).selectedViewController;
        if (selected) root = selected;
    }
    return root;
}

@end
