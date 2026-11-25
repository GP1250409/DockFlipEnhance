#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <substrate.h>
#import <math.h>
#import <os/log.h>

// ============================================================================
// Runtime Forward Declarations (No Private Headers Required)
// ============================================================================

@interface DockFlipController : NSObject
@property (nonatomic, weak) UIView *dock;
@property (nonatomic, weak) UIView *iconList;
@property (nonatomic, strong) UIView *clip;
@property (nonatomic, strong) UIView *page;
@property (nonatomic, strong) CADisplayLink *link;
@property (nonatomic, copy) NSArray<NSString *> *bundleIDs;
@property (nonatomic, assign) double progress;
@property (nonatomic, assign) double target;
@property (nonatomic, assign) double velocity;
@property (nonatomic, assign) double panStartProgress;
@property (nonatomic, assign) double lastTimestamp;
@property (nonatomic, assign) double flightMin;
@property (nonatomic, assign) double flightMax;
@property (nonatomic, assign) BOOL listFaded;
- (double)travel;
- (void)applyProgress;
- (void)stopSpring;
- (void)updateListMaskForShift:(double)shift list:(UIView *)list;
- (void)rebuildPageWithList:(UIView *)list;
- (double)progressForDragFrom:(double)start translation:(double)translation;
- (double)targetForProgress:(double)progress velocity:(double)velocity;
- (void)tick:(CADisplayLink *)link;
@end

// ============================================================================
// Logging
// ============================================================================

static os_log_t DFELog(void) {
    static os_log_t log = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        log = os_log_create("cc.gonepaul.dockflipenhance", "tweak");
    });
    return log;
}

// ============================================================================
// SpringBoard SBIcon / SBIconView Helpers
// ============================================================================

static id DFEIconManager(void) {
    Class iconCtrlCls = NSClassFromString(@"SBIconController");
    if (!iconCtrlCls || ![iconCtrlCls respondsToSelector:@selector(sharedInstance)]) return nil;
    id iconCtrl = ((id (*)(id, SEL))objc_msgSend)(iconCtrlCls, @selector(sharedInstance));
    if (!iconCtrl) return nil;
    SEL mgrSel = NSSelectorFromString(@"iconManager");
    if ([iconCtrl respondsToSelector:mgrSel]) {
        return ((id (*)(id, SEL))objc_msgSend)(iconCtrl, mgrSel);
    }
    return nil;
}

static id DFEFindSBIconForBundleID(NSString *bundleID) {
    if (bundleID.length == 0) return nil;
    Class iconCtrlCls = NSClassFromString(@"SBIconController");
    if (!iconCtrlCls || ![iconCtrlCls respondsToSelector:@selector(sharedInstance)]) return nil;
    id iconCtrl = ((id (*)(id, SEL))objc_msgSend)(iconCtrlCls, @selector(sharedInstance));
    if (!iconCtrl) return nil;

    id iconModel = nil;
    SEL modelSel = NSSelectorFromString(@"model");
    SEL iconModelSel = NSSelectorFromString(@"iconModel");
    SEL iconManagerSel = NSSelectorFromString(@"iconManager");
    if ([iconCtrl respondsToSelector:modelSel]) {
        iconModel = ((id (*)(id, SEL))objc_msgSend)(iconCtrl, modelSel);
    } else if ([iconCtrl respondsToSelector:iconModelSel]) {
        iconModel = ((id (*)(id, SEL))objc_msgSend)(iconCtrl, iconModelSel);
    } else if ([iconCtrl respondsToSelector:iconManagerSel]) {
        id mgr = ((id (*)(id, SEL))objc_msgSend)(iconCtrl, iconManagerSel);
        if (mgr && [mgr respondsToSelector:iconModelSel]) {
            iconModel = ((id (*)(id, SEL))objc_msgSend)(mgr, iconModelSel);
        }
    }
    if (!iconModel) return nil;

    SEL expectedSel = NSSelectorFromString(@"expectedIconForDisplayIdentifier:");
    if ([iconModel respondsToSelector:expectedSel]) {
        id icon = ((id (*)(id, SEL, id))objc_msgSend)(iconModel, expectedSel, bundleID);
        if (icon) return icon;
    }
    SEL appIconSel = NSSelectorFromString(@"applicationIconForBundleIdentifier:");
    if ([iconModel respondsToSelector:appIconSel]) {
        id icon = ((id (*)(id, SEL, id))objc_msgSend)(iconModel, appIconSel, bundleID);
        if (icon) return icon;
    }
    SEL leafSel = NSSelectorFromString(@"leafIconForIdentifier:");
    if ([iconModel respondsToSelector:leafSel]) {
        id icon = ((id (*)(id, SEL, id))objc_msgSend)(iconModel, leafSel, bundleID);
        if (icon) return icon;
    }
    return nil;
}

static UIView *DFEFindTemplateDockIconView(DockFlipController *ctrl) {
    UIView *list = ctrl.iconList;
    if (!list) return nil;
    Class sbIconViewCls = NSClassFromString(@"SBIconView");
    if (!sbIconViewCls) return nil;
    for (UIView *sub in list.subviews) {
        if ([sub isKindOfClass:sbIconViewCls]) {
            return sub;
        }
    }
    return nil;
}

static UIView *DFECreateNativeIconView(NSString *bundleID, CGRect targetBounds, UIView *templateIconView) {
    Class sbIconViewCls = NSClassFromString(@"SBIconView");
    if (!sbIconViewCls) return nil;

    id sbIcon = DFEFindSBIconForBundleID(bundleID);
    if (!sbIcon) return nil;

    @try {
        UIView *iconView = nil;

        // 1. Initialize using same configurationOptions as native Dock SBIconView
        SEL cfgOptsSel = NSSelectorFromString(@"configurationOptions");
        SEL initCfgSel = NSSelectorFromString(@"initWithConfigurationOptions:");
        if ([sbIconViewCls instancesRespondToSelector:initCfgSel]) {
            NSUInteger opts = 0;
            if (templateIconView && [templateIconView respondsToSelector:cfgOptsSel]) {
                opts = ((NSUInteger (*)(id, SEL))objc_msgSend)(templateIconView, cfgOptsSel);
            }
            iconView = ((id (*)(id, SEL, NSUInteger))objc_msgSend)([sbIconViewCls alloc], initCfgSel, opts);
        }
        if (!iconView) {
            iconView = [[sbIconViewCls alloc] initWithFrame:targetBounds];
        }
        if (!iconView) return nil;

        // 2. Copy delegate (SBHIconManager), location (SBIconLocationDock), and listLayoutProvider
        id delegate = nil;
        SEL delegateSel = NSSelectorFromString(@"delegate");
        SEL setDelegateSel = NSSelectorFromString(@"setDelegate:");
        if (templateIconView && [templateIconView respondsToSelector:delegateSel]) {
            delegate = ((id (*)(id, SEL))objc_msgSend)(templateIconView, delegateSel);
        }
        if (!delegate) {
            delegate = DFEIconManager();
        }
        if (delegate && [iconView respondsToSelector:setDelegateSel]) {
            ((void (*)(id, SEL, id))objc_msgSend)(iconView, setDelegateSel, delegate);
        }

        SEL listLayoutProvSel = NSSelectorFromString(@"listLayoutProvider");
        SEL setListLayoutProvSel = NSSelectorFromString(@"setListLayoutProvider:");
        if (templateIconView && [templateIconView respondsToSelector:listLayoutProvSel] && [iconView respondsToSelector:setListLayoutProvSel]) {
            id prov = ((id (*)(id, SEL))objc_msgSend)(templateIconView, listLayoutProvSel);
            if (prov) {
                ((void (*)(id, SEL, id))objc_msgSend)(iconView, setListLayoutProvSel, prov);
            }
        }

        SEL locSel = NSSelectorFromString(@"location");
        SEL setLocSel = NSSelectorFromString(@"setLocation:");
        NSString *loc = @"SBIconLocationDock";
        if (templateIconView && [templateIconView respondsToSelector:locSel]) {
            id tLoc = ((id (*)(id, SEL))objc_msgSend)(templateIconView, locSel);
            if ([tLoc isKindOfClass:[NSString class]] && ((NSString *)tLoc).length > 0) {
                loc = (NSString *)tLoc;
            }
        }
        if ([iconView respondsToSelector:setLocSel]) {
            ((void (*)(id, SEL, id))objc_msgSend)(iconView, setLocSel, loc);
        }

        // 3. Configure dock appearance (no label; no duplicate badge so DockFlipBadge stays authoritative)
        SEL setAllowsLabelSel = NSSelectorFromString(@"setAllowsLabelArea:");
        if ([iconView respondsToSelector:setAllowsLabelSel]) {
            ((void (*)(id, SEL, BOOL))objc_msgSend)(iconView, setAllowsLabelSel, NO);
        }
        SEL setLabelHiddenSel = NSSelectorFromString(@"setLabelHidden:");
        if ([iconView respondsToSelector:setLabelHiddenSel]) {
            ((void (*)(id, SEL, BOOL))objc_msgSend)(iconView, setLabelHiddenSel, YES);
        }
        SEL setAllowsAccSel = NSSelectorFromString(@"setAllowsAccessoryView:");
        if ([iconView respondsToSelector:setAllowsAccSel]) {
            ((void (*)(id, SEL, BOOL))objc_msgSend)(iconView, setAllowsAccSel, NO);
        }
        SEL setAllowsCloseSel = NSSelectorFromString(@"setAllowsCloseBox:");
        if ([iconView respondsToSelector:setAllowsCloseSel]) {
            ((void (*)(id, SEL, BOOL))objc_msgSend)(iconView, setAllowsCloseSel, NO);
        }

        // 4. Bind the real SBApplicationIcon
        SEL setIconSel = NSSelectorFromString(@"setIcon:");
        if ([iconView respondsToSelector:setIconSel]) {
            ((void (*)(id, SEL, id))objc_msgSend)(iconView, setIconSel, sbIcon);
        }

        // 5. Align iconView frame so its iconImageFrame sits 1:1 over DockFlip's icon rect
        iconView.frame = targetBounds;
        [iconView layoutIfNeeded];
        SEL imgFrameSel = NSSelectorFromString(@"iconImageFrame");
        if ([iconView respondsToSelector:imgFrameSel]) {
            CGRect imgFrame = ((CGRect (*)(id, SEL))objc_msgSend)(iconView, imgFrameSel);
            if (imgFrame.size.width > 1.0 && imgFrame.size.height > 1.0) {
                CGFloat dx = CGRectGetMidX(targetBounds) - CGRectGetMidX(imgFrame);
                CGFloat dy = CGRectGetMidY(targetBounds) - CGRectGetMidY(imgFrame);
                if (fabs(dx) > 0.5 || fabs(dy) > 0.5) {
                    iconView.frame = CGRectOffset(iconView.frame, dx, dy);
                }
            }
        }

        // 6. Disable drag-out interaction on DockFlip extra page so dragging never detaches from non-list superview
        for (id<UIInteraction> inter in iconView.interactions) {
            if ([inter isKindOfClass:[UIDragInteraction class]]) {
                ((UIDragInteraction *)inter).enabled = NO;
            }
        }

        return iconView;
    } @catch (NSException *ex) {
        os_log_error(DFELog(), "Failed creating SBIconView for %{public}@: %{public}@", bundleID, ex.reason);
        return nil;
    }
}

static const void *kDFENativeIconKey = &kDFENativeIconKey;

static void DFEEnhancePageIcons(DockFlipController *ctrl) {
    UIView *page = ctrl.page;
    if (!page) return;

    UIView *templateIconView = DFEFindTemplateDockIconView(ctrl);

    for (UIView *sub in page.subviews) {
        if (![sub isKindOfClass:[UIImageView class]]) continue;
        UIImageView *iv = (UIImageView *)sub;
        NSString *bundleID = iv.accessibilityIdentifier;
        if (bundleID.length == 0) continue;

        UIView *existing = objc_getAssociatedObject(iv, kDFENativeIconKey);
        if (existing && existing.superview == iv) {
            continue;
        }

        UIView *sbIconView = DFECreateNativeIconView(bundleID, iv.bounds, templateIconView);
        if (!sbIconView) continue;

        iv.userInteractionEnabled = YES;
        iv.clipsToBounds = NO;

        // Insert at index 0 so DockFlipBadge subviews remain on top of SBIconView
        [iv insertSubview:sbIconView atIndex:0];

        // Clear DockFlip's static image so SBIconView renders cleanly without double-layering
        iv.image = nil;

        // Disable DockFlip's raw tap gesture so SBIconView handles native tap launch + context menu + AppData swipe
        for (UIGestureRecognizer *gr in iv.gestureRecognizers) {
            if ([gr isKindOfClass:[UITapGestureRecognizer class]]) {
                gr.enabled = NO;
            }
        }

        objc_setAssociatedObject(iv, kDFENativeIconKey, sbIconView, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

// ============================================================================
// DockFlipController Hooks (Bidirectional Infinite Loop + Native Icon Embedding)
// ============================================================================

static double (*orig_progressForDragFrom_translation)(DockFlipController *, SEL, double, double);
static double (*orig_targetForProgress_velocity)(DockFlipController *, SEL, double, double);
static void   (*orig_applyProgress)(DockFlipController *, SEL);
static void   (*orig_tick)(DockFlipController *, SEL, CADisplayLink *);
static void   (*orig_rebuildPageWithList)(DockFlipController *, SEL, UIView *);

// 1. Remove rubber-band clamping at 0 and 1 so user can swipe freely in either direction
static double hook_progressForDragFrom_translation(DockFlipController *self, SEL _cmd, double start, double translation) {
    double travel = [self travel];
    if (travel <= 1.0) {
        return orig_progressForDragFrom_translation(self, _cmd, start, translation);
    }
    double raw = start - (translation / travel);
    if (raw > start + 1.0) raw = start + 1.0;
    if (raw < start - 1.0) raw = start - 1.0;
    return raw;
}

// 2. Pick nearest integer page in [start-1, start+1] instead of hardcoding {0, 1}
static double hook_targetForProgress_velocity(DockFlipController *self, SEL _cmd, double progress, double velocity) {
    double start = round([self panStartProgress]);
    double projected = progress + velocity * 0.18;
    double target = round(projected);
    if (target > start + 1.0) target = start + 1.0;
    if (target < start - 1.0) target = start - 1.0;
    return target;
}

// 3. Period-2 cyclic layout: even = native dock page, odd = DockFlip extra page
static void hook_applyProgress(DockFlipController *self, SEL _cmd) {
    UIView *iconList = self.iconList;
    UIView *page = self.page;
    UIView *clip = self.clip;
    if (!iconList || !page) {
        orig_applyProgress(self, _cmd);
        return;
    }

    double p = self.progress;
    double travel = [self travel];

    // Fold progress into [0, 2)
    double phase = fmod(p, 2.0);
    if (phase < 0.0) phase += 2.0;

    double listShift = 0.0;
    double pageShift = 0.0;
    double t = 0.0; // 0 = full native dock, 1 = full extra page

    if (phase <= 1.0) {
        // 0 -> 1 (native exits left, extra enters from right)
        listShift = -phase * travel;
        pageShift = (1.0 - phase) * travel;
        t = phase;
    } else {
        // 1 -> 2 (extra exits left, native enters from right)
        // Equivalently 0 -> -1 (native exits right, extra enters from left)
        double u = phase - 1.0;
        listShift = (1.0 - u) * travel;
        pageShift = -u * travel;
        t = 1.0 - u;
    }

    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    iconList.layer.sublayerTransform = CATransform3DMakeTranslation(listShift, 0.0, 0.0);
    [self updateListMaskForShift:listShift list:iconList];
    [CATransaction commit];

    iconList.alpha = 1.0 - t;
    self.listFaded = (t > 0.001);

    page.transform = CGAffineTransformMakeTranslation(pageShift, 0.0);
    page.alpha = t;
    if (clip) {
        clip.hidden = (t < 0.001);
    }

    // Cold-boot guard: lazily attach SBIconView if DockFlip built the page before our hook attached
    if (t > 0.01 && page.subviews.count > 0) {
        for (UIView *sub in page.subviews) {
            if ([sub isKindOfClass:[UIImageView class]] && sub.accessibilityIdentifier.length > 0) {
                if (!objc_getAssociatedObject(sub, kDFENativeIconKey)) {
                    DFEEnhancePageIcons(self);
                }
                break;
            }
        }
    }
}

// 4. Replace tick: spring integration WITHOUT DockFlip's [-0.15, 1.15] hard clamp
static void hook_tick(DockFlipController *self, SEL _cmd, CADisplayLink *link) {
    if (!self.dock) {
        [self stopSpring];
        return;
    }

    CFTimeInterval now = link.timestamp;
    double dt = 0.0;
    double last = self.lastTimestamp;
    if (last > 0.0) {
        dt = now - last;
    } else {
        double next = link.targetTimestamp - now;
        if (next > 0.0) {
            dt = next;
        } else if (link.duration > 0.0) {
            dt = link.duration;
        } else {
            dt = 1.0 / 60.0;
        }
    }
    self.lastTimestamp = now;

    if (dt < 0.0) dt = 0.0;
    if (dt > 0.05) dt = 0.05;

    int steps = (int)ceil(dt / (1.0 / 240.0));
    if (steps < 1) steps = 1;
    double h = dt / (double)steps;

    double p = self.progress;
    double v = self.velocity;
    double target = self.target;

    // Exact spring constants from DockFlip.dylib
    static const double kDamping = -23.935944027350807;
    static const double kStiffness = -223.80055331268386;

    for (int i = 0; i < steps; i++) {
        double accel = (p - target) * kStiffness + v * kDamping;
        v += accel * h;
        p += v * h;
    }

    if (p < self.flightMin) self.flightMin = p;
    if (p > self.flightMax) self.flightMax = p;

    if (fabs(p - target) < 0.0005 && fabs(v) < 0.01) {
        long idx = lrint(target);
        double norm = (idx & 1) ? 1.0 : 0.0;
        self.progress = norm;
        self.target = norm;
        self.velocity = 0.0;
        [self stopSpring];
        [self applyProgress];
    } else {
        self.progress = p;
        self.velocity = v;
        [self applyProgress];
    }
}

// 5. Enhance extra-page icons whenever DockFlip rebuilds the page
static void hook_rebuildPageWithList(DockFlipController *self, SEL _cmd, UIView *list) {
    orig_rebuildPageWithList(self, _cmd, list);
    DFEEnhancePageIcons(self);
}

// ============================================================================
// Safe Delayed Hooking (Independent of Dylib Load Order)
// ============================================================================

static BOOL gHooked = NO;

static void TryHookDockFlipController(void) {
    if (gHooked) return;
    Class cls = objc_getClass("DockFlipController");
    if (!cls) return;

    gHooked = YES;
    MSHookMessageEx(cls, @selector(progressForDragFrom:translation:), (IMP)hook_progressForDragFrom_translation, (IMP *)&orig_progressForDragFrom_translation);
    MSHookMessageEx(cls, @selector(targetForProgress:velocity:), (IMP)hook_targetForProgress_velocity, (IMP *)&orig_targetForProgress_velocity);
    MSHookMessageEx(cls, @selector(applyProgress), (IMP)hook_applyProgress, (IMP *)&orig_applyProgress);
    MSHookMessageEx(cls, @selector(tick:), (IMP)hook_tick, (IMP *)&orig_tick);
    MSHookMessageEx(cls, @selector(rebuildPageWithList:), (IMP)hook_rebuildPageWithList, (IMP *)&orig_rebuildPageWithList);

    os_log(DFELog(), "[DockFlipEnhance] hooked DockFlipController (v0.2.0 unclamped loop + native SBIconView)");
}

__attribute__((constructor))
static void DockFlipEnhanceInit(void) {
    os_log(DFELog(), "[DockFlipEnhance] initialized (v0.2.0)");
    TryHookDockFlipController();

    if (!gHooked) {
        [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidFinishLaunchingNotification
                                                          object:nil
                                                           queue:[NSOperationQueue mainQueue]
                                                      usingBlock:^(__unused NSNotification *note) {
            TryHookDockFlipController();
        }];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            TryHookDockFlipController();
        });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            TryHookDockFlipController();
        });
    }
}
