// Tweak.xm
//
// 功能：
//   1) 在朋友圈相机/上传菜单注入"朋友圈高画质"开关项（点击切换 ON/OFF）
//   2) 开启状态下额外注入"从手机相册选择（高画质）"入口
//   3) 通过该入口选图发布时，全链路绕过微信对图片/视频的二次压缩与降级
//   4) 走"从手机相册选择"原始入口不受影响
//
// 设计要点：
//   - 默认关闭（NSUserDefaults: WCMHQEnabled），首次开启弹出说明 + bug 提示
//   - 会话标志（kWCMHQSessionPending）从插件菜单点击启动，发布完成 6 秒后自动重置
//   - 视频源尺寸 / 源码率从 AVAssetTrack 读取，覆盖微信硬编码的 720×960 / 1500kbps

#import "WeChatHeaders.h"
#import "WCMHQManager.h"

#import <objc/runtime.h>
#import <objc/message.h>
#import <AVFoundation/AVFoundation.h>
#import <Photos/Photos.h>
#import <UIKit/UIKit.h>

#pragma mark - 第三方"WCPluginsMgr"插件收纳器前向声明

// 仅作编译期识别用，实际实现由 WCPluginsMgr 自身插件提供
// 运行时通过 NSClassFromString 判断是否存在，未安装时 %ctor 跳过注册
@interface WCPluginsMgr : NSObject
+ (instancetype)sharedInstance;
- (void)registerSwitchWithTitle:(NSString *)title key:(NSString *)key;
@end

#pragma mark - 全局会话状态

static NSString *kWCMHQAlbumMenuTitle = @"从手机相册选择（高画质）";
static char     kWCMHQForcePickerKey;

// 当前是否处于"朋友圈高画质"会话中（仅由插件菜单触发）
static BOOL  kWCMHQSessionPending      = NO;
// 当前会话视频的真实展示尺寸（旋转后），从 AVAssetTrack.naturalSize × preferredTransform 算出
static float kWCMHQTargetWidth         = 0.0f;
static float kWCMHQTargetHeight        = 0.0f;
// 当前会话视频的源码率（kbps），从 AVAssetTrack.estimatedDataRate 读出
static float kWCMHQTargetBitrateKbps   = 0.0f;

#pragma mark - 通用工具

static BOOL WCMHQ_enabled(void) {
    return [WCMHQManager isEnabled];
}

static BOOL WCMHQ_isPickerOptionObj(id obj) {
    if (!obj) return NO;
    Class cls = objc_getClass("MMImagePickerManagerOptionObj");
    return cls && [obj isKindOfClass:cls];
}

static BOOL WCMHQ_sheetContainsTitle(WCActionSheet *sheet, NSString *title) {
    if (!sheet || title.length == 0) return NO;
    @try {
        unsigned long long count = [sheet numberOfButtons];
        for (unsigned long long i = 0; i < count; i++) {
            id t = [sheet buttonTitleAtIndex:(long long)i];
            if ([t isKindOfClass:[NSString class]]
                && [(NSString *)t isEqualToString:title]) {
                return YES;
            }
        }
    } @catch (NSException *e) {}
    return NO;
}

static BOOL WCMHQ_sheetContainsSubstring(WCActionSheet *sheet, NSString *sub) {
    if (!sheet || sub.length == 0) return NO;
    @try {
        unsigned long long count = [sheet numberOfButtons];
        for (unsigned long long i = 0; i < count; i++) {
            id t = [sheet buttonTitleAtIndex:(long long)i];
            if ([t isKindOfClass:[NSString class]]
                && [(NSString *)t containsString:sub]) {
                return YES;
            }
        }
    } @catch (NSException *e) {}
    return NO;
}

static NSInteger WCMHQ_albumIndex(WCActionSheet *sheet) {
    if (!sheet) return NSNotFound;
    NSInteger fallback = NSNotFound;
    @try {
        unsigned long long count = [sheet numberOfButtons];
        for (unsigned long long i = 0; i < count; i++) {
            id t = [sheet buttonTitleAtIndex:(long long)i];
            if ([t isKindOfClass:[NSString class]]) {
                NSString *title = (NSString *)t;
                if ([title isEqualToString:@"从手机相册选择"]) return (NSInteger)i;
                if (fallback == NSNotFound
                    && [title containsString:@"从手机相册选择"]
                    && ![title containsString:@"高画质"]) {
                    fallback = (NSInteger)i;
                }
            }
        }
    } @catch (NSException *e) {}
    return fallback;
}

static void WCMHQ_markForceFor(UIViewController *vc, BOOL on) {
    if (!vc) return;
    objc_setAssociatedObject(vc, &kWCMHQForcePickerKey,
                             on ? @YES : nil,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static BOOL WCMHQ_shouldForceFor(UIViewController *vc) {
    if (!vc) return NO;
    NSNumber *flag = objc_getAssociatedObject(vc, &kWCMHQForcePickerKey);
    return flag && [flag boolValue];
}

static void WCMHQ_applyPickerOptions(MMImagePickerManagerOptionObj *opt) {
    if (!opt) return;
    opt.canSendOriginalImage   = YES;
    opt.forceSendOriginalImage = YES;
    opt.hideOriginButton       = YES;
    opt.isOpenSendOriginVideo  = YES;
    opt.isWAVideoCompressed    = NO;
    opt.videoQualityType       = 1; // 0=低 1=高
}

static void WCMHQ_prepareInfosForPicker(MMAssetPickerController *picker) {
    if (!picker) return;
    @try {
        picker.isOriginSelected = YES;
        @try { [picker setValue:@YES forKey:@"_isOriginalImageForSend"]; } @catch (NSException *e) {}
        if ([picker respondsToSelector:@selector(onOriginImageCheckChanged)]) {
            [picker onOriginImageCheckChanged];
        }
        if ([picker respondsToSelector:@selector(updateSelectTotalSize)]) {
            [picker updateSelectTotalSize];
        }
        NSArray *infos = picker.selectedAssetInfos;
        if (![infos isKindOfClass:[NSArray class]]) return;
        for (id info in infos) {
            if ([info respondsToSelector:@selector(setIsHDImage:)]) {
                [info setIsHDImage:YES];
            }
            if ([info respondsToSelector:@selector(asset)]) {
                MMAsset *a = [info asset];
                if (a && [a respondsToSelector:@selector(setM_isNeedOriginImage:)]) {
                    a.m_isNeedOriginImage = YES;
                }
            }
        }
    } @catch (NSException *e) {}
}

// 安全地对 id 目标调用 setter:BOOL 参数
static void WCMHQ_safeSetBoolProperty(id target, SEL sel, BOOL value) {
    if (!target || !sel) return;
    if (![target respondsToSelector:sel]) return;
    @try {
        NSMethodSignature *sig = [target methodSignatureForSelector:sel];
        if (!sig || sig.numberOfArguments < 3) return;
        const char *t = [sig getArgumentTypeAtIndex:2];
        if (!t) return;
        NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
        [inv setSelector:sel];
        [inv setTarget:target];
        if (t[0] == 'c' || t[0] == 'B') {
            BOOL v = value;
            [inv setArgument:&v atIndex:2];
        } else if (t[0] == 'i') {
            int v = value ? 1 : 0;
            [inv setArgument:&v atIndex:2];
        } else if (t[0] == 'q' || t[0] == 'l') {
            long long v = value ? 1 : 0;
            [inv setArgument:&v atIndex:2];
        } else {
            BOOL v = value;
            [inv setArgument:&v atIndex:2];
        }
        [inv invoke];
    } @catch (NSException *e) {}
}

static void WCMHQ_applyToUploadTask(id task) {
    if (!task) return;
    @try {
        WCMHQ_safeSetBoolProperty(task, @selector(setOriginal:), YES);
        @try {
            NSArray *medias = [task valueForKey:@"mediaList"];
            if ([medias isKindOfClass:[NSArray class]]) {
                for (id media in medias) {
                    WCMHQ_safeSetBoolProperty(media, @selector(setSkipCompress:), YES);
                }
            }
        } @catch (NSException *e) {}
    } @catch (NSException *e) {}
}

// 递归隐藏"制作视频"按钮，避免遮挡高画质文件大小提示
static void WCMHQ_hideMakeVideoBtn(UIView *view) {
    if (!view) return;
    for (UIView *sub in view.subviews) {
        if ([sub isKindOfClass:[UIButton class]]) {
            UIButton *btn = (UIButton *)sub;
            NSString *title = [btn titleForState:UIControlStateNormal];
            if (title && [title containsString:@"制作视频"]) {
                btn.hidden = YES;
                continue;
            }
            NSString *cls = NSStringFromClass([btn class]);
            if ([cls containsString:@"Template"] || [cls containsString:@"Composing"]) {
                btn.hidden = YES;
                continue;
            }
        }
        if ([sub isKindOfClass:[UILabel class]]) {
            UILabel *l = (UILabel *)sub;
            if (l.text && [l.text containsString:@"制作视频"]) {
                sub.superview.hidden = YES;
                continue;
            }
        }
        WCMHQ_hideMakeVideoBtn(sub);
    }
}

#pragma mark - 朋友圈菜单注入

// 在朋友圈相机/上传菜单内注入：
//   (a) 朋友圈高画质 开关条目
//   (b) 当开启时再注入 "从手机相册选择（高画质）" 入口
static void WCMHQ_injectMomentsMenu(WCTimeLineViewController *vc) {
    if (!vc) return;
    Class sheetCls = objc_getClass("WCActionSheet");
    if (!sheetCls) return;
    WCActionSheet *sheet = [sheetCls getCurrentShowingActionSheet];
    if (!sheet) return;

    BOOL enabled = WCMHQ_enabled();

    // (a) 开关条目：仅当未安装"WCPluginsMgr"插件收纳器时才注入
    //     已安装收纳器时，用户统一在收纳器里管理开关，避免重复入口
    BOOL hasPluginsMgr = (NSClassFromString(@"WCPluginsMgr") != nil);
    if (!hasPluginsMgr
        && !WCMHQ_sheetContainsSubstring(sheet, @"朋友圈高画质")) {
        NSString *toggleTitle = enabled
            ? @"朋友圈高画质：已开启（点击关闭）"
            : @"朋友圈高画质：未开启（点击开启）";
        [sheet addButtonWithTitle:toggleTitle eventAction:^{
            BOOL newOn = ![WCMHQManager isEnabled];
            [WCMHQManager setEnabled:newOn];
            // 弹窗统一由 WCMHQManager 的 NSUserDefaults 变化监听回调触发，
            // 这里不再手动弹窗，避免重复弹出
        }];
    }

    // (b) 高画质入口（仅开启时注入）
    if (enabled && !WCMHQ_sheetContainsTitle(sheet, kWCMHQAlbumMenuTitle)) {
        NSInteger albumIdx = WCMHQ_albumIndex(sheet);
        if (albumIdx != NSNotFound) {
            __weak WCTimeLineViewController *weakVC = vc;
            __weak WCActionSheet *weakSheet = sheet;
            [sheet addButtonWithTitle:kWCMHQAlbumMenuTitle eventAction:^{
                WCTimeLineViewController *strongVC = weakVC;
                WCActionSheet *strongSheet = weakSheet
                    ?: [objc_getClass("WCActionSheet") getCurrentShowingActionSheet];
                if (!strongVC || !strongSheet) return;
                WCMHQ_markForceFor((UIViewController *)strongVC, YES);
                @try {
                    NSInteger ti = WCMHQ_albumIndex(strongSheet);
                    if (ti == NSNotFound) ti = albumIdx;
                    [strongVC actionSheet:strongSheet clickedButtonAtIndex:(long long)ti];
                } @catch (NSException *e) {
                    WCMHQ_markForceFor((UIViewController *)strongVC, NO);
                }
            }];
        }
    }

    [sheet reloadInnerView];
}

#pragma mark - WCTimeLineViewController：注入入口

%hook WCTimeLineViewController

- (void)showPhotoAlert:(id)arg1 {
    %orig;
    dispatch_async(dispatch_get_main_queue(), ^{
        WCMHQ_injectMomentsMenu(self);
    });
}

- (void)showUploadOption:(id)arg1 {
    %orig;
    dispatch_async(dispatch_get_main_queue(), ^{
        WCMHQ_injectMomentsMenu(self);
    });
}

%end

#pragma mark - WCNewCommitViewController：发布前强制原图标志

%hook WCNewCommitViewController

- (void)viewWillDisappear:(BOOL)animated {
    %orig;
    // 离开发布页延迟 6 秒重置会话，确保所有压缩 hook 还来得及执行
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(6.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        kWCMHQSessionPending = NO;
    });
}

- (void)processUploadTask:(id)task {
    if (WCMHQ_enabled() && kWCMHQSessionPending) {
        WCMHQ_applyToUploadTask(task);
    }
    %orig;
}

- (void)commonUpdateWCUploadTask:(id)task {
    %orig;
    if (WCMHQ_enabled() && kWCMHQSessionPending) {
        WCMHQ_applyToUploadTask(task);
    }
}

%end

#pragma mark - WCUploadTask：兜底强制原图标志

%hook WCUploadTask

- (void)setOriginal:(BOOL)original {
    if (WCMHQ_enabled() && kWCMHQSessionPending) {
        %orig(YES);
    } else {
        %orig;
    }
}

%end

#pragma mark - WCUploadMedia：兜底跳过压缩

%hook WCUploadMedia

- (void)setSkipCompress:(BOOL)skipCompress {
    if (WCMHQ_enabled() && kWCMHQSessionPending) {
        %orig(YES);
    } else {
        %orig;
    }
}

%end

#pragma mark - VideoEncodeParams：替换编码参数

%hook VideoEncodeParams

- (void)adjustIfNeeded {
    %orig;
    if (WCMHQ_enabled() && kWCMHQSessionPending) {
        @try { [self setValue:@YES forKey:@"skipVideoCompress"]; } @catch (NSException *e) {}
    }
}

- (void)_adjustSizeToStandardForMoments {
    // 关键：不能跳过 %orig，否则微信内部宽高比对齐逻辑缺失会导致服务器拉伸画面
    %orig;
    if (WCMHQ_enabled() && kWCMHQSessionPending) {
        float afterW = 0, afterH = 0;
        @try {
            afterW = [[self valueForKey:@"width"]  floatValue];
            afterH = [[self valueForKey:@"height"] floatValue];
        } @catch (NSException *e) {}
        if (kWCMHQTargetWidth > 0 && kWCMHQTargetHeight > 0
            && (afterW + 1.0f < kWCMHQTargetWidth
                || afterH + 1.0f < kWCMHQTargetHeight)) {
            @try {
                [self setValue:@(kWCMHQTargetWidth)  forKey:@"width"];
                [self setValue:@(kWCMHQTargetHeight) forKey:@"height"];
            } @catch (NSException *e) {}
        }
        @try { [self setValue:@YES forKey:@"skipVideoCompress"]; } @catch (NSException *e) {}
    }
}

- (void)setWidth:(float)width {
    if (WCMHQ_enabled() && kWCMHQSessionPending
        && kWCMHQTargetWidth > 0
        && width > 0 && width <= 720
        && kWCMHQTargetWidth > width + 1.0f) {
        %orig(kWCMHQTargetWidth);
        return;
    }
    %orig;
}

- (void)setHeight:(float)height {
    if (WCMHQ_enabled() && kWCMHQSessionPending
        && kWCMHQTargetHeight > 0
        && height > 0 && height <= 960
        && kWCMHQTargetHeight > height + 1.0f) {
        %orig(kWCMHQTargetHeight);
        return;
    }
    %orig;
}

- (void)setVideoBitrate:(float)bitrate {
    if (WCMHQ_enabled() && kWCMHQSessionPending
        && kWCMHQTargetBitrateKbps > 0
        && bitrate > 0
        && kWCMHQTargetBitrateKbps > bitrate + 500.0f) {
        %orig(kWCMHQTargetBitrateKbps);
        return;
    }
    %orig;
}

%end

#pragma mark - WCSightVideoCompositor：合成入口读源信息

%hook WCSightVideoCompositor

+ (void)startWithTask:(id)task resultBlock:(id)resultBlock {
    BOOL active = WCMHQ_enabled() && kWCMHQSessionPending;
    // 每次合成前清空，避免上一会话残留
    kWCMHQTargetWidth        = 0.0f;
    kWCMHQTargetHeight       = 0.0f;
    kWCMHQTargetBitrateKbps  = 0.0f;
    if (active && task) {
        @try {
            id urlObj = nil;
            @try { urlObj = [task valueForKey:@"cachedEditedAssetFileURL"]; } @catch (NSException *e) {}
            if ([urlObj isKindOfClass:[NSURL class]]) {
                NSURL *url = (NSURL *)urlObj;
                AVURLAsset *avAsset = [AVURLAsset URLAssetWithURL:url options:nil];
                NSArray *tracks = [avAsset tracksWithMediaType:AVMediaTypeVideo];
                if (tracks.count > 0) {
                    AVAssetTrack *track = tracks[0];
                    CGSize natural = track.naturalSize;
                    CGAffineTransform tf = track.preferredTransform;
                    // 应用 transform，得到旋转后的真实展示尺寸
                    CGRect box = CGRectApplyAffineTransform(
                        CGRectMake(0, 0, natural.width, natural.height), tf);
                    float w = fabsf((float)CGRectGetWidth(box));
                    float h = fabsf((float)CGRectGetHeight(box));
                    if (w > 0 && h > 0) {
                        kWCMHQTargetWidth  = w;
                        kWCMHQTargetHeight = h;
                    }
                    // estimatedDataRate 单位 bps，换算 kbps
                    float kbps = track.estimatedDataRate / 1000.0f;
                    if (kbps > 0) {
                        kWCMHQTargetBitrateKbps = kbps;
                    }
                }
            }
        } @catch (NSException *e) {}
        @try {
            id params = nil;
            if ([task respondsToSelector:@selector(params)]) {
                params = [task performSelector:@selector(params)];
            }
            if (params) {
                @try { [params setValue:@YES forKey:@"skipVideoCompress"]; } @catch (NSException *e) {}
            }
        } @catch (NSException *e) {}
    }
    %orig;
}

%end

#pragma mark - AVAssetExportSession：拦截 preset 降级

%hook AVAssetExportSession

// 注意：参数用 id 而不是 AVAsset *，避免 Logos 生成方法签名时类型未声明
- (id)initWithAsset:(id)asset presetName:(NSString *)presetName {
    if (WCMHQ_enabled() && kWCMHQSessionPending
        && [presetName isKindOfClass:[NSString class]]) {
        static NSSet *downgradePresets = nil;
        static dispatch_once_t once;
        dispatch_once(&once, ^{
            downgradePresets = [NSSet setWithArray:@[
                @"AVAssetExportPresetLowQuality",
                @"AVAssetExportPresetMediumQuality",
                @"AVAssetExportPreset640x480",
                @"AVAssetExportPreset960x540",
                @"AVAssetExportPreset1280x720",
            ]];
        });
        if ([downgradePresets containsObject:presetName]) {
            return %orig(asset, AVAssetExportPresetHighestQuality);
        }
    }
    return %orig;
}

%end

#pragma mark - VideoEncodeTask：导出前再次确保跳过压缩

%hook VideoEncodeTask

- (void)exportAsynchronouslyWithCompletionHandler:(id)handler {
    if (WCMHQ_enabled() && kWCMHQSessionPending) {
        @try {
            id params = [self respondsToSelector:@selector(params)]
                ? [self performSelector:@selector(params)] : nil;
            if (params) {
                @try { [params setValue:@YES forKey:@"skipVideoCompress"]; } @catch (NSException *e) {}
            }
        } @catch (NSException *e) {}
    }
    %orig;
}

%end

#pragma mark - MMImagePickerManager：仅插件菜单触发的会话才启用高画质

%hook MMImagePickerManager

+ (void)showWithOptionObj:(id)arg1 inViewController:(id)arg2 {
    if (WCMHQ_enabled()
        && WCMHQ_isPickerOptionObj(arg1)
        && [arg2 isKindOfClass:[UIViewController class]]) {
        UIViewController *vc = (UIViewController *)arg2;
        if (WCMHQ_shouldForceFor(vc)) {
            kWCMHQSessionPending = YES;
            WCMHQ_applyPickerOptions((MMImagePickerManagerOptionObj *)arg1);
            WCMHQ_markForceFor(vc, NO);
        }
    }
    %orig;
}

- (void)showWithOptionObj:(id)arg1 inViewController:(id)arg2 delegate:(id)arg3 {
    if (WCMHQ_enabled()
        && WCMHQ_isPickerOptionObj(arg1)
        && [arg2 isKindOfClass:[UIViewController class]]) {
        UIViewController *vc = (UIViewController *)arg2;
        if (WCMHQ_shouldForceFor(vc)) {
            kWCMHQSessionPending = YES;
            WCMHQ_applyPickerOptions((MMImagePickerManagerOptionObj *)arg1);
            WCMHQ_markForceFor(vc, NO);
        }
    }
    %orig;
}

%end

#pragma mark - MMAssetPickerController：picker 行为微调

%hook MMAssetPickerController

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    if (kWCMHQSessionPending) {
        WCMHQ_prepareInfosForPicker(self);
        @try { [self setValue:@YES forKey:@"_isOriginalImageForSend"]; } @catch (NSException *e) {}
        @try {
            UIButton *btn = [self valueForKey:@"_templateComposingButton"];
            if (btn) btn.hidden = YES;
        } @catch (NSException *e) {}
        __weak __typeof(self) ws = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            __strong __typeof(ws) ss = ws;
            if (ss) WCMHQ_hideMakeVideoBtn(ss.view);
        });
    }
}

- (void)viewDidLayoutSubviews {
    %orig;
    if (kWCMHQSessionPending) {
        @try {
            UIButton *btn = [self valueForKey:@"_templateComposingButton"];
            if (btn) btn.hidden = YES;
        } @catch (NSException *e) {}
    }
}

- (BOOL)getPickerWAVideoCompressedFromOptionObj {
    if (kWCMHQSessionPending) return NO;
    return %orig;
}

- (void)sendSelectedMedia {
    if (kWCMHQSessionPending) {
        WCMHQ_prepareInfosForPicker(self);
    }
    %orig;
}

- (void)OnCancel:(id)arg1 {
    // 用户取消选图：重置会话避免后续误命中
    kWCMHQSessionPending = NO;
    WCMHQ_markForceFor((UIViewController *)self, NO);
    %orig;
}

- (void)asyncGetAssetVideo:(id)asset compress:(BOOL)compress complete:(id)complete {
    if (WCMHQ_enabled() && kWCMHQSessionPending && compress) {
        %orig(asset, NO, complete);
        return;
    }
    %orig;
}

- (id)getVideoExportCallbackBlockWithAsset:(id)asset URL:(id)url
                                noCompress:(BOOL)noCompress
                               exifLogInfo:(id)exif {
    if (WCMHQ_enabled() && kWCMHQSessionPending && !noCompress) {
        return %orig(asset, url, YES, exif);
    }
    return %orig;
}

%end

#pragma mark - 构造函数：开关监听 + 插件收纳器适配

%ctor {
    @autoreleasepool {
        // 启动开关变化监听：任何来源切换 WCMHQEnabled 都会自动弹出首次/关闭提示
        [WCMHQManager startObservingSwitchChanges];

        // 适配"WCPluginsMgr"插件收纳器：只有一个开关，使用 registerSwitchWithTitle:key:
        if (NSClassFromString(@"WCPluginsMgr")) {
            @try {
                [[objc_getClass("WCPluginsMgr") sharedInstance]
                    registerSwitchWithTitle:@"朋友圈高画质"
                                        key:@"WCMHQEnabled"];
            } @catch (NSException *e) {}
        }
    }
}
