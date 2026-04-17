// WCMHQDebugPanel.m
// 朋友圈高画质 - 压缩链路调试浮层实现

#import "WCMHQDebugPanel.h"

#pragma mark - 穿透 Window

@interface _WCMHQPassThroughWindow : UIWindow
@end

@implementation _WCMHQPassThroughWindow

// 面板外的点击穿透到下层（微信 UI）
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    if (hit == self) return nil;
    if (self.rootViewController && hit == self.rootViewController.view) return nil;
    return hit;
}

@end

#pragma mark - 空 RootVC（支持旋转）

@interface _WCMHQPassThroughRootVC : UIViewController
@end

@implementation _WCMHQPassThroughRootVC

- (void)loadView {
    UIView *v = [[UIView alloc] init];
    v.backgroundColor = [UIColor clearColor];
    v.userInteractionEnabled = YES;
    self.view = v;
}

- (BOOL)shouldAutorotate { return YES; }
- (UIInterfaceOrientationMask)supportedInterfaceOrientations { return UIInterfaceOrientationMaskAll; }
- (UIStatusBarStyle)preferredStatusBarStyle { return UIStatusBarStyleDefault; }
- (BOOL)prefersStatusBarHidden { return NO; }

@end

#pragma mark - 浮层单例

@interface WCMHQDebugPanel () <UITextViewDelegate>
@property (nonatomic, strong) _WCMHQPassThroughWindow *window;
@property (nonatomic, strong) UIView                  *container;     // 主面板
@property (nonatomic, strong) UIView                  *titleBar;
@property (nonatomic, strong) UILabel                 *titleLabel;
@property (nonatomic, strong) UITextView              *textView;
@property (nonatomic, strong) UIView                  *ballView;      // 最小化态小球
@property (nonatomic, strong) UILabel                 *ballLabel;
@property (nonatomic, strong) NSMutableString         *logBuffer;
@property (nonatomic, assign) BOOL                     minimized;
@property (nonatomic, assign) BOOL                     visible;
@property (nonatomic, assign) NSUInteger               pendingFlushCount;
@end

@implementation WCMHQDebugPanel

+ (instancetype)sharedPanel {
    static WCMHQDebugPanel *p = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        p = [[WCMHQDebugPanel alloc] init];
    });
    return p;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _logBuffer = [NSMutableString string];
    }
    return self;
}

#pragma mark - 公开 API

+ (void)show {
    dispatch_async(dispatch_get_main_queue(), ^{
        [[WCMHQDebugPanel sharedPanel] _show];
    });
}

+ (void)hide {
    dispatch_async(dispatch_get_main_queue(), ^{
        [[WCMHQDebugPanel sharedPanel] _hide];
    });
}

+ (void)toggle {
    dispatch_async(dispatch_get_main_queue(), ^{
        WCMHQDebugPanel *p = [WCMHQDebugPanel sharedPanel];
        if (p.visible) [p _hide]; else [p _show];
    });
}

+ (BOOL)isVisible {
    return [WCMHQDebugPanel sharedPanel].visible;
}

+ (void)log:(NSString *)line {
    if (!line.length) return;
    [[WCMHQDebugPanel sharedPanel] _appendLine:line];
}

+ (void)logFormat:(NSString *)fmt, ... {
    if (!fmt) return;
    va_list args;
    va_start(args, fmt);
    NSString *line = [[NSString alloc] initWithFormat:fmt arguments:args];
    va_end(args);
    [[WCMHQDebugPanel sharedPanel] _appendLine:line];
}

+ (void)clearLogs {
    dispatch_async(dispatch_get_main_queue(), ^{
        WCMHQDebugPanel *p = [WCMHQDebugPanel sharedPanel];
        [p.logBuffer setString:@""];
        p.textView.text = @"";
    });
}

+ (void)copyAllLogs {
    dispatch_async(dispatch_get_main_queue(), ^{
        WCMHQDebugPanel *p = [WCMHQDebugPanel sharedPanel];
        NSString *text = [p.logBuffer copy] ?: @"";
        [UIPasteboard generalPasteboard].string = text;
        // toast
        [p _flashToast:[NSString stringWithFormat:@"已复制 %lu 行", (unsigned long)[[text componentsSeparatedByString:@"\n"] count]]];
    });
}

#pragma mark - 日志追加

- (void)_appendLine:(NSString *)line {
    // 时间戳前缀
    static NSDateFormatter *fmt = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        fmt = [[NSDateFormatter alloc] init];
        fmt.dateFormat = @"HH:mm:ss.SSS";
    });
    NSString *prefix = [fmt stringFromDate:[NSDate date]];
    NSString *full = [NSString stringWithFormat:@"[%@] %@\n", prefix, line];

    @synchronized (self.logBuffer) {
        [self.logBuffer appendString:full];
        // 限制最多 2000 行，避免 buffer 无限增长
        NSUInteger maxLen = 80 * 2000;
        if (self.logBuffer.length > maxLen) {
            NSUInteger excess = self.logBuffer.length - maxLen;
            NSRange r = [self.logBuffer rangeOfString:@"\n"
                                             options:0
                                               range:NSMakeRange(excess, self.logBuffer.length - excess)];
            if (r.location != NSNotFound) {
                [self.logBuffer deleteCharactersInRange:NSMakeRange(0, r.location + 1)];
            }
        }
    }

    // 合并刷新：短时间内多次 append 合并到一次主线程写入
    self.pendingFlushCount++;
    NSUInteger myIdx = self.pendingFlushCount;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.08 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (myIdx != self.pendingFlushCount) return; // 已经有更晚的任务会刷新
        [self _flushToTextView];
    });
}

- (void)_flushToTextView {
    if (!self.textView) return;
    NSString *snapshot;
    @synchronized (self.logBuffer) { snapshot = [self.logBuffer copy]; }
    self.textView.text = snapshot;
    // 滚动到底部
    if (snapshot.length > 0) {
        NSRange r = NSMakeRange(snapshot.length - 1, 1);
        [self.textView scrollRangeToVisible:r];
    }

    // 最小化态时更新小球计数
    if (self.minimized) {
        NSUInteger lines = [[snapshot componentsSeparatedByString:@"\n"] count];
        if (lines > 0) lines--; // 末尾空字符串
        self.ballLabel.text = lines > 999
            ? @"999+"
            : [NSString stringWithFormat:@"%lu", (unsigned long)lines];
    }
}

#pragma mark - 显隐

- (void)_show {
    if (self.visible) {
        [self.window makeKeyAndVisible];
        return;
    }
    [self _buildUIIfNeeded];
    self.window.hidden = NO;
    self.visible = YES;
    [self _flushToTextView];
}

- (void)_hide {
    if (!self.visible) return;
    self.window.hidden = YES;
    self.visible = NO;
}

#pragma mark - UI 构建

- (void)_buildUIIfNeeded {
    if (self.window) return;

    // Window
    UIWindow *keyWin = nil;
    if (@available(iOS 13.0, *)) {
        for (UIScene *s in UIApplication.sharedApplication.connectedScenes) {
            if ([s isKindOfClass:[UIWindowScene class]]
                && s.activationState == UISceneActivationStateForegroundActive) {
                _WCMHQPassThroughWindow *w =
                    [[_WCMHQPassThroughWindow alloc] initWithWindowScene:(UIWindowScene *)s];
                w.frame = ((UIWindowScene *)s).coordinateSpace.bounds;
                self.window = w;
                break;
            }
        }
    }
    if (!self.window) {
        self.window = [[_WCMHQPassThroughWindow alloc]
            initWithFrame:[UIScreen mainScreen].bounds];
        (void)keyWin;
    }
    self.window.windowLevel = UIWindowLevelAlert + 10;
    self.window.backgroundColor = [UIColor clearColor];
    self.window.rootViewController = [[_WCMHQPassThroughRootVC alloc] init];

    UIView *root = self.window.rootViewController.view;

    // 主容器（居右下，初始 320×420）
    CGRect sb = [UIScreen mainScreen].bounds;
    CGFloat cw = MIN(340, sb.size.width - 20);
    CGFloat ch = MIN(440, sb.size.height - 160);
    CGFloat cx = sb.size.width - cw - 12;
    CGFloat cy = sb.size.height - ch - 60;
    UIView *container = [[UIView alloc] initWithFrame:CGRectMake(cx, cy, cw, ch)];
    container.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.82];
    container.layer.cornerRadius  = 10;
    container.layer.borderColor   = [UIColor colorWithWhite:1 alpha:0.25].CGColor;
    container.layer.borderWidth   = 0.5;
    container.clipsToBounds       = YES;
    [root addSubview:container];
    self.container = container;

    // 标题栏
    UIView *titleBar = [[UIView alloc] initWithFrame:CGRectMake(0, 0, cw, 36)];
    titleBar.backgroundColor = [[UIColor colorWithRed:0.15 green:0.55 blue:1.0 alpha:0.95] colorWithAlphaComponent:0.9];
    [container addSubview:titleBar];
    self.titleBar = titleBar;

    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(12, 0, cw - 24, 36)];
    title.text = @"WCMHQ 压缩调试";
    title.textColor = [UIColor whiteColor];
    title.font = [UIFont boldSystemFontOfSize:13];
    [titleBar addSubview:title];
    self.titleLabel = title;

    // 按钮栏（标题栏下方一行按钮）
    UIView *btnBar = [[UIView alloc] initWithFrame:CGRectMake(0, 36, cw, 32)];
    btnBar.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.5];
    [container addSubview:btnBar];

    NSArray<NSString *> *titles = @[@"复制", @"清除", @"最小化", @"关闭"];
    NSArray<NSString *> *sels   = @[@"_onCopy", @"_onClear", @"_onMinimize", @"_onClose"];
    CGFloat bw = cw / titles.count;
    for (NSUInteger i = 0; i < titles.count; i++) {
        UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
        b.frame = CGRectMake(i * bw, 0, bw, 32);
        [b setTitle:titles[i] forState:UIControlStateNormal];
        b.titleLabel.font = [UIFont systemFontOfSize:13];
        [b setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        [b addTarget:self action:NSSelectorFromString(sels[i])
            forControlEvents:UIControlEventTouchUpInside];
        if (i > 0) {
            UIView *sep = [[UIView alloc] initWithFrame:CGRectMake(i * bw, 6, 0.5, 20)];
            sep.backgroundColor = [UIColor colorWithWhite:1 alpha:0.2];
            [btnBar addSubview:sep];
        }
        [btnBar addSubview:b];
    }

    // 日志文本（可选、可复制、滚动）
    CGFloat textY = 68;
    UITextView *tv = [[UITextView alloc] initWithFrame:CGRectMake(0, textY, cw, ch - textY)];
    tv.editable = NO;
    tv.selectable = YES;
    tv.backgroundColor = [UIColor clearColor];
    tv.textColor = [UIColor colorWithRed:0.85 green:0.95 blue:0.75 alpha:1];
    tv.font = [UIFont fontWithName:@"Menlo" size:10] ?: [UIFont systemFontOfSize:10];
    tv.textContainerInset = UIEdgeInsetsMake(6, 8, 6, 8);
    tv.showsVerticalScrollIndicator = YES;
    tv.alwaysBounceVertical = YES;
    tv.dataDetectorTypes = UIDataDetectorTypeNone;
    [container addSubview:tv];
    self.textView = tv;

    // 标题栏拖动
    UIPanGestureRecognizer *pan =
        [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(_onPanContainer:)];
    [titleBar addGestureRecognizer:pan];

    // 小球（最小化态）
    CGFloat bs = 56;
    UIView *ball = [[UIView alloc] initWithFrame:CGRectMake(sb.size.width - bs - 12,
                                                            sb.size.height - bs - 120,
                                                            bs, bs)];
    ball.backgroundColor = [[UIColor colorWithRed:0.15 green:0.55 blue:1.0 alpha:1] colorWithAlphaComponent:0.9];
    ball.layer.cornerRadius = bs / 2;
    ball.layer.borderColor = [UIColor whiteColor].CGColor;
    ball.layer.borderWidth = 1.5;
    ball.layer.shadowColor = [UIColor blackColor].CGColor;
    ball.layer.shadowOffset = CGSizeMake(0, 1);
    ball.layer.shadowRadius = 4;
    ball.layer.shadowOpacity = 0.3;
    ball.hidden = YES;
    [root addSubview:ball];
    self.ballView = ball;

    UILabel *ballLab = [[UILabel alloc] initWithFrame:ball.bounds];
    ballLab.textColor = [UIColor whiteColor];
    ballLab.textAlignment = NSTextAlignmentCenter;
    ballLab.font = [UIFont boldSystemFontOfSize:14];
    ballLab.text = @"LOG";
    ballLab.numberOfLines = 2;
    [ball addSubview:ballLab];
    self.ballLabel = ballLab;

    UITapGestureRecognizer *tap =
        [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(_onTapBall)];
    [ball addGestureRecognizer:tap];
    UIPanGestureRecognizer *ballPan =
        [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(_onPanBall:)];
    [ball addGestureRecognizer:ballPan];
}

#pragma mark - 按钮事件

- (void)_onCopy {
    [WCMHQDebugPanel copyAllLogs];
}

- (void)_onClear {
    [WCMHQDebugPanel clearLogs];
}

- (void)_onMinimize {
    self.minimized = YES;
    self.container.hidden = YES;
    self.ballView.hidden = NO;
    [self _flushToTextView]; // 更新小球计数
}

- (void)_onClose {
    [self _hide];
}

- (void)_onTapBall {
    self.minimized = NO;
    self.ballView.hidden = YES;
    self.container.hidden = NO;
    [self _flushToTextView];
}

#pragma mark - 拖动手势

- (void)_onPanContainer:(UIPanGestureRecognizer *)pan {
    if (pan.state == UIGestureRecognizerStateChanged) {
        CGPoint t = [pan translationInView:self.container.superview];
        CGRect f = self.container.frame;
        f.origin.x += t.x;
        f.origin.y += t.y;
        // 限制在屏幕可见范围内
        CGRect sb = self.window.bounds;
        if (f.origin.x < 0) f.origin.x = 0;
        if (f.origin.y < 0) f.origin.y = 0;
        if (CGRectGetMaxX(f) > sb.size.width)  f.origin.x = sb.size.width - f.size.width;
        if (CGRectGetMaxY(f) > sb.size.height) f.origin.y = sb.size.height - f.size.height;
        self.container.frame = f;
        [pan setTranslation:CGPointZero inView:self.container.superview];
    }
}

- (void)_onPanBall:(UIPanGestureRecognizer *)pan {
    if (pan.state == UIGestureRecognizerStateChanged) {
        CGPoint t = [pan translationInView:self.ballView.superview];
        CGRect f = self.ballView.frame;
        f.origin.x += t.x;
        f.origin.y += t.y;
        CGRect sb = self.window.bounds;
        if (f.origin.x < 0) f.origin.x = 0;
        if (f.origin.y < 0) f.origin.y = 0;
        if (CGRectGetMaxX(f) > sb.size.width)  f.origin.x = sb.size.width - f.size.width;
        if (CGRectGetMaxY(f) > sb.size.height) f.origin.y = sb.size.height - f.size.height;
        self.ballView.frame = f;
        [pan setTranslation:CGPointZero inView:self.ballView.superview];
    }
}

#pragma mark - Toast

- (void)_flashToast:(NSString *)msg {
    UIView *root = self.window.rootViewController.view;
    UILabel *l = [[UILabel alloc] init];
    l.text = msg;
    l.textColor = [UIColor whiteColor];
    l.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.8];
    l.textAlignment = NSTextAlignmentCenter;
    l.font = [UIFont systemFontOfSize:13];
    l.layer.cornerRadius = 8;
    l.clipsToBounds = YES;
    CGFloat w = 180, h = 32;
    l.frame = CGRectMake((root.bounds.size.width - w) / 2,
                         root.bounds.size.height / 2 - h / 2, w, h);
    [root addSubview:l];
    [UIView animateWithDuration:0.2 delay:0.9 options:0 animations:^{
        l.alpha = 0;
    } completion:^(BOOL finished) { [l removeFromSuperview]; }];
}

@end
