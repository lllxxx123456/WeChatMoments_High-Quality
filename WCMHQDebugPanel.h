// WCMHQDebugPanel.h
// 朋友圈高画质 - 压缩链路调试浮层
//
// 用法：
//   [WCMHQDebugPanel toggle];                // 显示/隐藏
//   [WCMHQDebugPanel log:@"..."];            // 追加一行日志
//   WCMHQDebugLog(@"fmt %@", arg);           // 宏版本，支持 format
//
// 浮层特性：
//   - 独立 UIWindow，等级高于所有微信 VC
//   - 面板外区域点击穿透（不挡微信操作）
//   - 标题栏可拖动；按钮：复制 / 清除 / 最小化 / 关闭
//   - 最小化后变为可拖动小球，点击小球还原
//   - 文本可选可复制

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface WCMHQDebugPanel : NSObject

+ (void)show;
+ (void)hide;
+ (void)toggle;
+ (BOOL)isVisible;

+ (void)log:(NSString *)line;
+ (void)logFormat:(NSString *)fmt, ... NS_FORMAT_FUNCTION(1, 2);

+ (void)clearLogs;
+ (void)copyAllLogs;

@end

// 便捷宏：非生产路径使用
#define WCMHQDebugLog(fmt, ...) [WCMHQDebugPanel logFormat:(fmt), ##__VA_ARGS__]

NS_ASSUME_NONNULL_END
