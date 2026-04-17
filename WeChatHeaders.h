// WeChatHeaders.h
// 朋友圈高画质 - 微信内部类的最小声明集合
// 仅保留 hook 实际访问的属性与方法，避免无关声明引入额外编译告警。

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>

#pragma mark - 朋友圈弹窗

@interface WCActionSheet : UIView
+ (id)getCurrentShowingActionSheet;
- (long long)addButtonWithTitle:(id)a0 eventAction:(id /* block */)a1;
- (unsigned long long)numberOfButtons;
- (id)buttonTitleAtIndex:(long long)a0;
- (void)reloadInnerView;
@end

#pragma mark - 朋友圈时间线

@interface WCTimeLineViewController : UIViewController
- (void)showPhotoAlert:(id)a0;
- (void)showUploadOption:(id)a0;
- (void)actionSheet:(id)a0 clickedButtonAtIndex:(long long)a1;
@end

#pragma mark - 选图相关

@interface MMImagePickerManagerOptionObj : NSObject
@property (nonatomic) BOOL canSendOriginalImage;
@property (nonatomic) BOOL forceSendOriginalImage;
@property (nonatomic) BOOL hideOriginButton;
@property (nonatomic) BOOL isOpenSendOriginVideo;
@property (nonatomic) BOOL isWAVideoCompressed;
@property (nonatomic) long long videoQualityType;
@end

@interface MMImagePickerManager : NSObject
+ (void)showWithOptionObj:(id)a0 inViewController:(id)a1;
- (void)showWithOptionObj:(id)a0 inViewController:(id)a1 delegate:(id)a2;
@end

@interface MMAsset : NSObject
@property (nonatomic) BOOL m_isNeedOriginImage;
@end

@interface MMAssetInfo : NSObject
@property (readonly, nonatomic) MMAsset *asset;
@property (nonatomic) BOOL isHDImage;
@end

@interface MMAssetPickerController : UIViewController
@property (nonatomic) BOOL isOriginSelected;
@property (retain, nonatomic) NSMutableArray *selectedAssetInfos;
- (void)onOriginImageCheckChanged;
- (void)updateSelectTotalSize;
- (void)sendSelectedMedia;
- (void)sendVideoWithAsset:(id)a0;
- (void)asyncGetAssetVideo:(id)a0 compress:(BOOL)a1 complete:(id)a2;
- (id)getVideoExportCallbackBlockWithAsset:(id)a0 URL:(id)a1 noCompress:(BOOL)a2 exifLogInfo:(id)a3;
- (BOOL)getPickerWAVideoCompressedFromOptionObj;
@end

#pragma mark - 朋友圈上传任务

@interface WCUploadMedia : NSObject
@property (nonatomic) BOOL skipCompress;
@end

@interface WCUploadTask : NSObject
@property (retain, nonatomic) NSMutableArray *mediaList;
- (void)setOriginal:(BOOL)a0;
@end

@interface WCNewCommitViewController : UIViewController
- (void)processUploadTask:(id)a0;
- (void)commonUpdateWCUploadTask:(id)a0;
@end

#pragma mark - 视频编码

// 视频编码参数（发布阶段最底层压缩开关）
@interface VideoEncodeParams : NSObject
@property (nonatomic) BOOL skipVideoCompress;
@property (nonatomic) float width;
@property (nonatomic) float height;
@property (nonatomic) float videoBitrate;
- (void)adjustIfNeeded;
- (void)_adjustSizeToStandardForMoments;
@end

// 视频编码任务（chat / moments 通用）
@interface VideoEncodeTask : NSObject
- (void)exportAsynchronouslyWithCompletionHandler:(id /* block */)a0;
@end

// 朋友圈视频合成器（发布阶段视频入口）
@interface WCSightVideoCompositor : NSObject
+ (void)startWithTask:(id)a0 resultBlock:(id /* block */)a1;
@end
