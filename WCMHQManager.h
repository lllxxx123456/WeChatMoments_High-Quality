// WCMHQManager.h
// 朋友圈高画质 - 配置管理与首次提示
//
// 作用：
//   1) 通过 NSUserDefaults 持久化"朋友圈高画质"开关状态（默认关闭）
//   2) 提供给 Tweak.xm 内 hook 检查开关是否开启
//   3) 用户首次开启时弹出功能介绍 + bug 提示
//   4) 监听开关变化，任意来源（插件收纳器 / 朋友圈菜单 / 外部）开启时都会弹提示；
//      关闭时静默，不打扰用户
//
// 已适配"WCPluginsMgr"插件收纳器：
//   [[objc_getClass("WCPluginsMgr") sharedInstance]
//       registerSwitchWithTitle:@"朋友圈高画质" key:@"WCMHQEnabled"];
//
// 第三方插件/脚本如要手动读写开关：
//   [WCMHQManager isEnabled]                  -> 读取当前状态
//   [WCMHQManager setEnabled:BOOL]            -> 写入状态
//   NSUserDefaults key:  WCMHQEnabled         -> 也可直接读写 NSUserDefaults

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface WCMHQManager : NSObject

// 开关读写（默认 NO）
+ (BOOL)isEnabled;
+ (void)setEnabled:(BOOL)enabled;

// 启动开关变化监听（幂等，重复调用安全）
// 开启后：任意来源（插件收纳器 / 朋友圈菜单 / 外部写入 NSUserDefaults）
// 将 WCMHQEnabled 切换为开启时，都会自动弹出首次/后续开启提示；关闭时静默
+ (void)startObservingSwitchChanges;

// 首次开启提示（内部已自带"是否首次"判断）
+ (void)showFirstTimeAlertIfNeededInController:(nullable UIViewController *)vc;

// 顶层 VC 工具方法（找到当前 keyWindow 上最顶部的 VC）
+ (nullable UIViewController *)topViewController;

@end

NS_ASSUME_NONNULL_END
