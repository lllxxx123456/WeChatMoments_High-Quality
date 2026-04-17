// WCMHQManager.m
// 朋友圈高画质 - 配置管理与首次提示

#import "WCMHQManager.h"

static NSString *const kWCMHQEnabledKey       = @"WCMHQEnabled";
static NSString *const kWCMHQHasShownAlertKey = @"WCMHQHasShownAlert";

// 开关变化监听状态（静态变量）
static BOOL gWCMHQObservingStarted = NO;
static BOOL gWCMHQLastKnownEnabled = NO;

@implementation WCMHQManager

#pragma mark - 开关读写

+ (BOOL)isEnabled {
    return [[NSUserDefaults standardUserDefaults] boolForKey:kWCMHQEnabledKey];
}

+ (void)setEnabled:(BOOL)enabled {
    NSUserDefaults *def = [NSUserDefaults standardUserDefaults];
    [def setBool:enabled forKey:kWCMHQEnabledKey];
    [def synchronize];
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
    BOOL newOn = [self isEnabled];
    if (newOn == gWCMHQLastKnownEnabled) return;
    gWCMHQLastKnownEnabled = newOn;
    // 仅在开启时弹提示，关闭时静默（不打扰用户）
    if (!newOn) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        [WCMHQManager showFirstTimeAlertIfNeededInController:nil];
    });
}

#pragma mark - 首次开启提示

+ (void)showFirstTimeAlertIfNeededInController:(UIViewController *)vc {
    NSUserDefaults *def = [NSUserDefaults standardUserDefaults];
    BOOL hasShown = [def boolForKey:kWCMHQHasShownAlertKey];

    NSString *title;
    NSString *msg;

    if (hasShown) {
        // 后续开启的简短提示
        title = @"朋友圈高画质 已开启";
        msg = @"功能已开启。\n\n"
              @"下次发布朋友圈时，菜单中点击「从手机相册选择（高画质）」即可走高画质流程。\n\n"
              @"如遇任何异常请及时关闭本插件开关，或直接卸载本插件即可恢复正常。";
    } else {
        // 首次开启的完整说明
        title = @"朋友圈高画质 已开启";
        msg = @"【使用方式】\n"
              @"开启后，朋友圈相机菜单将多出一项「从手机相册选择（高画质）」，"
              @"从该项进入选图发布即走高画质流程（可能会比官方画质高一丢丢）"
              @"走原「从手机相册选择」不受影响。\n\n"
              @"【重要提示】\n"
              @"如出现以下任一异常：\n"
              @"• 微信崩溃 / 闪退\n"
              @"• 朋友圈发布失败 / 卡死\n"
              @"• 视频画面拉伸 / 播放异常\n"
              @"• 图片显示错误\n"
              @"请立即关闭本插件开关，"
              @"或直接卸载本插件以恢复正常使用。";
    }

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
                                                                   message:msg
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"我知道了"
                                              style:UIAlertActionStyleDefault
                                            handler:nil]];

    UIViewController *presenter = vc ?: [self topViewController];
    if (presenter) {
        [presenter presentViewController:alert animated:YES completion:nil];
    }

    if (!hasShown) {
        [def setBool:YES forKey:kWCMHQHasShownAlertKey];
        [def synchronize];
    }
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
