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

    NSString *title = @"朋友圈高画质 已开启";

    // 文案：段落之间用 \n\n 空行，列表每项单独一行，视觉更清晰
    NSString *highlight = @"（可能会比官方画质高一丢丢）";
    NSString *msg =
        @"【使用方式】\n"
        @"开启后，朋友圈相机菜单将多出一项\n"
        @"「从手机相册选择（高画质）」\n"
        @"从该项进入选图发布即走高画质流程\n"
        @"可能会比官方画质高一丢丢\n"
        @"走官方「从手机相册选择」不受影响\n\n"
        @"【重要提示】\n"
        @"如出现以下任一异常：\n"
        @"• 微信崩溃 / 闪退\n"
        @"• 朋友圈发布失败 / 卡死\n"
        @"• 视频画面拉伸 / 播放异常\n"
        @"• 图片显示错误\n\n"
        @"请立即关闭本插件开关"
        @"或直接卸载本插件以恢复正常使用。";

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
                                                                   message:msg
                                                            preferredStyle:UIAlertControllerStyleAlert];


    @try {
        NSMutableAttributedString *attr =
            [[NSMutableAttributedString alloc] initWithString:msg];
        NSMutableParagraphStyle *ps = [[NSMutableParagraphStyle alloc] init];
        ps.alignment = NSTextAlignmentLeft; // 多行列表项用左对齐视觉更整齐
        ps.lineSpacing = 3;
        ps.paragraphSpacing = 4;
        [attr addAttribute:NSParagraphStyleAttributeName
                     value:ps
                     range:NSMakeRange(0, attr.length)];
        [attr addAttribute:NSFontAttributeName
                     value:[UIFont systemFontOfSize:13]
                     range:NSMakeRange(0, attr.length)];
        NSRange redRange = [msg rangeOfString:highlight];
        if (redRange.location != NSNotFound) {
            [attr addAttribute:NSForegroundColorAttributeName
                         value:[UIColor systemRedColor]
                         range:redRange];
            [attr addAttribute:NSFontAttributeName
                         value:[UIFont boldSystemFontOfSize:13]
                         range:redRange];
        }
        [alert setValue:attr forKey:@"attributedMessage"];
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
