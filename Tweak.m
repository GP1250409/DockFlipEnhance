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
@property (nonatomic, strong) UIPanGestureRecognizer *pan;
@property (nonatomic, strong) CALayer *listMask;
@property (nonatomic, assign) CGRect platterRect;
@property (nonatomic, assign) CGRect platterInList;
@property (nonatomic, assign) double platterRadius;
- (double)travel;
- (void)applyProgress;
- (void)stopSpring;
- (void)springTo:(double)target velocity:(double)velocity;
- (void)updateListMaskForShift:(double)shift list:(UIView *)list;
- (void)rebuildPageWithList:(UIView *)list;
- (double)progressForDragFrom:(double)start translation:(double)translation;
- (double)targetForProgress:(double)progress velocity:(double)velocity;
- (void)tick:(CADisplayLink *)link;
- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gestureRecognizer;
- (void)handlePan:(UIPanGestureRecognizer *)pan;
@end

static BOOL DFEIsVerticalDock(DockFlipController *ctrl) {
    UIView *ref = ctrl.page ?: ctrl.dock;
    if (!ref) return NO;
    CGRect b = ref.bounds;
    return (b.size.height > b.size.width + 20.0);
}

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

static const void *kDFENativeIconKey = &kDFENativeIconKey;
static const void *kDFEIsDockFlipIconKey = &kDFEIsDockFlipIconKey;

static void DFEDisableEditingLongPressOnIconView(UIView *iconView) {
    if (!iconView) return;
    @try {
        SEL editGrSel = NSSelectorFromString(@"editingModeGestureRecognizer");
        if ([iconView respondsToSelector:editGrSel]) {
            UIGestureRecognizer *gr = ((id (*)(id, SEL))objc_msgSend)(iconView, editGrSel);
            if ([gr isKindOfClass:[UIGestureRecognizer class]]) {
                gr.enabled = NO;
            }
        }
        Ivar ivar = class_getInstanceVariable(object_getClass(iconView), "_editingModeGestureRecognizer");
        if (ivar) {
            id obj = object_getIvar(iconView, ivar);
            if ([obj isKindOfClass:[UIGestureRecognizer class]]) {
                ((UIGestureRecognizer *)obj).enabled = NO;
            }
        }
    } @catch (__unused NSException *ex) {}
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

        // 6. Disable drag-out & forbid editing mode on DockFlip extra-page SBIconView
        for (id<UIInteraction> inter in iconView.interactions) {
            if ([inter isKindOfClass:[UIDragInteraction class]]) {
                ((UIDragInteraction *)inter).enabled = NO;
            }
        }
        objc_setAssociatedObject(iconView, kDFEIsDockFlipIconKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        SEL forbidSel = NSSelectorFromString(@"startForbiddingEditingModeWithReason:");
        if ([iconView respondsToSelector:forbidSel]) {
            ((void (*)(id, SEL, id))objc_msgSend)(iconView, forbidSel, @"DockFlipEnhance");
        }
        DFEDisableEditingLongPressOnIconView(iconView);

        return iconView;
    } @catch (NSException *ex) {
        os_log_error(DFELog(), "Failed creating SBIconView for %{public}@: %{public}@", bundleID, ex.reason);
        return nil;
    }
}

static void (*orig_editingModeGestureRecognizerDidFire)(id, SEL, id);
static void hook_editingModeGestureRecognizerDidFire(id self, SEL _cmd, id recognizer) {
    if (objc_getAssociatedObject(self, kDFEIsDockFlipIconKey)) {
        return;
    }
    if (orig_editingModeGestureRecognizerDidFire) {
        orig_editingModeGestureRecognizerDidFire(self, _cmd, recognizer);
    }
}

static void (*orig_handleEditingModeGesture)(id, SEL, id);
static void hook_handleEditingModeGesture(id self, SEL _cmd, id recognizer) {
    if (objc_getAssociatedObject(self, kDFEIsDockFlipIconKey)) {
        return;
    }
    if (orig_handleEditingModeGesture) {
        orig_handleEditingModeGesture(self, _cmd, recognizer);
    }
}

static BOOL (*orig_canBeginDrags)(id, SEL);
static BOOL hook_canBeginDrags(id self, SEL _cmd) {
    if (objc_getAssociatedObject(self, kDFEIsDockFlipIconKey)) {
        return NO;
    }
    return orig_canBeginDrags ? orig_canBeginDrags(self, _cmd) : NO;
}

static BOOL (*orig_allowDragAfterDismiss)(id, SEL, id);
static BOOL hook_allowDragAfterDismiss(id self, SEL _cmd, id interaction) {
    if (objc_getAssociatedObject(self, kDFEIsDockFlipIconKey)) {
        return NO;
    }
    return orig_allowDragAfterDismiss ? orig_allowDragAfterDismiss(self, _cmd, interaction) : NO;
}

static BOOL (*orig_mgr_iconViewEditingFired)(id, SEL, id, id);
static BOOL hook_mgr_iconViewEditingFired(id self, SEL _cmd, id iconView, id recognizer) {
    if (iconView && objc_getAssociatedObject(iconView, kDFEIsDockFlipIconKey)) {
        return NO;
    }
    return orig_mgr_iconViewEditingFired ? orig_mgr_iconViewEditingFired(self, _cmd, iconView, recognizer) : NO;
}

static BOOL gDockFlipTouchActive = NO;
static BOOL gDockFlipContextMenuOpen = NO;
static CFAbsoluteTime gLastDockFlipContextMenuEndTime = 0.0;
static CFAbsoluteTime gAllowExplicitEditMenuUntil = 0.0;

static BOOL DFEShouldBlockEditingMode(void) {
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (now < gAllowExplicitEditMenuUntil) {
        return NO;
    }
    if (gDockFlipTouchActive || gDockFlipContextMenuOpen) {
        return YES;
    }
    if ((now - gLastDockFlipContextMenuEndTime) < 0.5) {
        return YES;
    }
    return NO;
}

static void (*orig_touchesBegan)(id, SEL, id, id);
static void hook_touchesBegan(id self, SEL _cmd, id touches, id event) {
    if (objc_getAssociatedObject(self, kDFEIsDockFlipIconKey)) {
        gDockFlipTouchActive = YES;
    }
    if (orig_touchesBegan) {
        orig_touchesBegan(self, _cmd, touches, event);
    }
}

static void (*orig_touchesEnded)(id, SEL, id, id);
static void hook_touchesEnded(id self, SEL _cmd, id touches, id event) {
    if (objc_getAssociatedObject(self, kDFEIsDockFlipIconKey)) {
        gDockFlipTouchActive = NO;
    }
    if (orig_touchesEnded) {
        orig_touchesEnded(self, _cmd, touches, event);
    }
}

static void (*orig_touchesCancelled)(id, SEL, id, id);
static void hook_touchesCancelled(id self, SEL _cmd, id touches, id event) {
    if (objc_getAssociatedObject(self, kDFEIsDockFlipIconKey)) {
        gDockFlipTouchActive = NO;
    }
    if (orig_touchesCancelled) {
        orig_touchesCancelled(self, _cmd, touches, event);
    }
}

static id (*orig_ctxConfig)(id, SEL, id, CGPoint);
static id hook_ctxConfig(id self, SEL _cmd, id interaction, CGPoint location) {
    if (objc_getAssociatedObject(self, kDFEIsDockFlipIconKey)) {
        gDockFlipContextMenuOpen = YES;
    }
    return orig_ctxConfig ? orig_ctxConfig(self, _cmd, interaction, location) : nil;
}

static void (*orig_ctxWillDisplay)(id, SEL, id, id, id);
static void hook_ctxWillDisplay(id self, SEL _cmd, id interaction, id config, id animator) {
    if (objc_getAssociatedObject(self, kDFEIsDockFlipIconKey)) {
        gDockFlipContextMenuOpen = YES;
    }
    if (orig_ctxWillDisplay) {
        orig_ctxWillDisplay(self, _cmd, interaction, config, animator);
    }
}

static void (*orig_ctxWillEnd)(id, SEL, id, id, id);
static void hook_ctxWillEnd(id self, SEL _cmd, id interaction, id config, id animator) {
    if (objc_getAssociatedObject(self, kDFEIsDockFlipIconKey)) {
        gDockFlipContextMenuOpen = NO;
        gDockFlipTouchActive = NO;
        gLastDockFlipContextMenuEndTime = CFAbsoluteTimeGetCurrent();
    }
    if (orig_ctxWillEnd) {
        orig_ctxWillEnd(self, _cmd, interaction, config, animator);
    }
}

static void (*orig_activateShortcut)(id, SEL, id, id, id);
static void hook_activateShortcut(id self, SEL _cmd, id item, id bundleID, id iconView) {
    // If user explicitly taps "Edit Home Screen" / rearrange shortcut inside the menu, allow editing mode
    @try {
        SEL typeSel = NSSelectorFromString(@"type");
        if (item && [item respondsToSelector:typeSel]) {
            NSString *type = ((id (*)(id, SEL))objc_msgSend)(item, typeSel);
            if ([type isKindOfClass:[NSString class]] &&
                ([type rangeOfString:@"rearrange" options:NSCaseInsensitiveSearch].location != NSNotFound ||
                 [type rangeOfString:@"edit" options:NSCaseInsensitiveSearch].location != NSNotFound)) {
                gAllowExplicitEditMenuUntil = CFAbsoluteTimeGetCurrent() + 2.0;
            }
        }
    } @catch (__unused NSException *ex) {}
    if (orig_activateShortcut) {
        orig_activateShortcut(self, _cmd, item, bundleID, iconView);
    }
}

static void (*orig_mgr_folderShouldBeginEditing)(id, SEL, id, BOOL);
static void hook_mgr_folderShouldBeginEditing(id self, SEL _cmd, id folderController, BOOL withHaptic) {
    if (DFEShouldBlockEditingMode()) {
        return;
    }
    if (orig_mgr_folderShouldBeginEditing) {
        orig_mgr_folderShouldBeginEditing(self, _cmd, folderController, withHaptic);
    }
}

static void (*orig_mgr_setEditing)(id, SEL, BOOL);
static void hook_mgr_setEditing(id self, SEL _cmd, BOOL editing) {
    if (editing && DFEShouldBlockEditingMode()) {
        return;
    }
    if (orig_mgr_setEditing) {
        orig_mgr_setEditing(self, _cmd, editing);
    }
}

static void (*orig_mgr_setEditingFromIconView)(id, SEL, BOOL, id);
static void hook_mgr_setEditingFromIconView(id self, SEL _cmd, BOOL editing, id iconView) {
    if (editing && (DFEShouldBlockEditingMode() || (iconView && objc_getAssociatedObject(iconView, kDFEIsDockFlipIconKey) && CFAbsoluteTimeGetCurrent() >= gAllowExplicitEditMenuUntil))) {
        return;
    }
    if (orig_mgr_setEditingFromIconView) {
        orig_mgr_setEditingFromIconView(self, _cmd, editing, iconView);
    }
}

static void (*orig_mgr_setEditingWithFeedback)(id, SEL, BOOL, id);
static void hook_mgr_setEditingWithFeedback(id self, SEL _cmd, BOOL editing, id feedback) {
    if (editing && DFEShouldBlockEditingMode()) {
        return;
    }
    if (orig_mgr_setEditingWithFeedback) {
        orig_mgr_setEditingWithFeedback(self, _cmd, editing, feedback);
    }
}

static void DFERelayoutPageVerticallyIfNeeded(DockFlipController *ctrl, UIView *list) {
    if (!DFEIsVerticalDock(ctrl)) return;
    UIView *page = ctrl.page;
    if (!page) return;

    NSMutableArray<UIImageView *> *pageIcons = [NSMutableArray array];
    for (UIView *sub in page.subviews) {
        if ([sub isKindOfClass:[UIImageView class]] && sub.accessibilityIdentifier.length > 0) {
            [pageIcons addObject:(UIImageView *)sub];
        }
    }
    if (pageIcons.count == 0) return;
    [pageIcons sortUsingComparator:^NSComparisonResult(UIImageView *a, UIImageView *b) {
        if (a.tag < b.tag) return NSOrderedAscending;
        if (a.tag > b.tag) return NSOrderedDescending;
        return NSOrderedSame;
    }];

    // Collect native vertical Dock SBIconViews sorted top-to-bottom
    NSMutableArray<UIView *> *nativeIcons = [NSMutableArray array];
    Class sbIconViewCls = NSClassFromString(@"SBIconView");
    UIView *iconList = list ?: ctrl.iconList;
    if (iconList && sbIconViewCls) {
        for (UIView *sub in iconList.subviews) {
            if ([sub isKindOfClass:sbIconViewCls] && !sub.isHidden) {
                [nativeIcons addObject:sub];
            }
        }
    }
    [nativeIcons sortUsingComparator:^NSComparisonResult(UIView *a, UIView *b) {
        CGFloat ya = CGRectGetMidY(a.frame);
        CGFloat yb = CGRectGetMidY(b.frame);
        if (ya < yb) return NSOrderedAscending;
        if (ya > yb) return NSOrderedDescending;
        return NSOrderedSame;
    }];

    CGFloat iconSize = 60.0;
    CGFloat w = page.bounds.size.width;
    CGFloat h = page.bounds.size.height;
    CGFloat midX = CGRectGetMidX(page.bounds);
    CGFloat firstMidY = 0.0;
    CGFloat lastMidY = 0.0;
    BOOL haveNativeRange = NO;

    if (nativeIcons.count > 0) {
        UIView *first = nativeIcons.firstObject;
        UIView *last = nativeIcons.lastObject;
        SEL imgFrameSel = NSSelectorFromString(@"iconImageFrame");

        // Compute centers purely in untransformed iconList coordinates (immune to sublayerTransform!)
        CGRect f1 = first.frame;
        CGRect f2 = last.frame;
        CGFloat y1 = CGRectGetMidY(f1);
        CGFloat y2 = CGRectGetMidY(f2);
        CGFloat x1 = CGRectGetMidX(f1);

        if ([first respondsToSelector:imgFrameSel]) {
            CGRect imgF = ((CGRect (*)(id, SEL))objc_msgSend)(first, imgFrameSel);
            if (imgF.size.width > 1.0) {
                iconSize = imgF.size.width;
                x1 = f1.origin.x + CGRectGetMidX(imgF);
                y1 = f1.origin.y + CGRectGetMidY(imgF);
            }
        } else if (f1.size.width > 1.0) {
            iconSize = MIN(f1.size.width, f1.size.height);
        }
        if ([last respondsToSelector:imgFrameSel]) {
            CGRect imgF = ((CGRect (*)(id, SEL))objc_msgSend)(last, imgFrameSel);
            if (imgF.size.width > 1.0) {
                y2 = f2.origin.y + CGRectGetMidY(imgF);
            }
        }

        CGRect platterInList = ctrl.platterInList;
        CGFloat px = x1 - platterInList.origin.x;
        CGFloat py1 = y1 - platterInList.origin.y;
        CGFloat py2 = y2 - platterInList.origin.y;

        if (px > 0.0 && px < w) {
            midX = px;
        }
        if (py1 > 0.0 && py2 > py1 + 10.0 && py2 < h) {
            firstMidY = py1;
            lastMidY = py2;
            haveNativeRange = YES;
        }
    }

    if (!haveNativeRange) {
        CGFloat pad = MIN(h * 0.25, iconSize * 0.75);
        firstMidY = pad;
        lastMidY = MAX(pad, h - pad);
    }

    NSUInteger n = pageIcons.count;
    for (NSUInteger i = 0; i < n; i++) {
        UIImageView *iv = pageIcons[i];
        CGFloat cy = (n == 1)
            ? (firstMidY + lastMidY) * 0.5
            : firstMidY + (lastMidY - firstMidY) * ((CGFloat)i / (CGFloat)(n - 1));
        iv.frame = CGRectMake(round(midX - iconSize * 0.5), round(cy - iconSize * 0.5), iconSize, iconSize);
    }
}

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

static double (*orig_travel)(DockFlipController *, SEL);
static double (*orig_progressForDragFrom_translation)(DockFlipController *, SEL, double, double);
static double (*orig_targetForProgress_velocity)(DockFlipController *, SEL, double, double);
static void   (*orig_applyProgress)(DockFlipController *, SEL);
static void   (*orig_tick)(DockFlipController *, SEL, CADisplayLink *);
static void   (*orig_rebuildPageWithList)(DockFlipController *, SEL, UIView *);
static BOOL   (*orig_gestureShouldBegin)(DockFlipController *, SEL, UIGestureRecognizer *);
static BOOL   (*orig_shouldBeRequiredToFail)(DockFlipController *, SEL, UIGestureRecognizer *, UIGestureRecognizer *);
static void   (*orig_handlePan)(DockFlipController *, SEL, UIPanGestureRecognizer *);

static double hook_travel(DockFlipController *self, SEL _cmd) {
    if (DFEIsVerticalDock(self)) {
        CGFloat h = CGRectGetHeight(self.platterRect);
        if (h <= 0.0 && self.page) h = CGRectGetHeight(self.page.bounds);
        if (h <= 0.0 && self.dock) h = CGRectGetHeight(self.dock.bounds);
        return fmax(h, 80.0);
    }
    return orig_travel ? orig_travel(self, _cmd) : 80.0;
}

static BOOL hook_gestureShouldBegin(DockFlipController *self, SEL _cmd, UIGestureRecognizer *gr) {
    if (gr == self.pan && DFEIsVerticalDock(self)) {
        UIView *dock = self.dock;
        if (!dock) return NO;
        CGPoint t = [self.pan translationInView:dock];
        CGPoint v = [self.pan velocityInView:dock];
        CGFloat ax = fabs(t.x) > 0.5 ? fabs(t.x) : fabs(v.x);
        CGFloat ay = fabs(t.y) > 0.5 ? fabs(t.y) : fabs(v.y);
        // Allow slight natural diagonal thumb arc on right-edge vertical dock
        return (ay >= ax * 0.65);
    }
    return orig_gestureShouldBegin ? orig_gestureShouldBegin(self, _cmd, gr) : YES;
}

static BOOL hook_shouldBeRequiredToFail(DockFlipController *self, SEL _cmd, UIGestureRecognizer *gr, UIGestureRecognizer *other) {
    if (gr == self.pan && DFEIsVerticalDock(self) && other) {
        if ([other isKindOfClass:[UIScreenEdgePanGestureRecognizer class]]) {
            return NO;
        }
        if ([other isKindOfClass:[UIPanGestureRecognizer class]] ||
            [other isKindOfClass:[UISwipeGestureRecognizer class]]) {
            return YES;
        }
    }
    return orig_shouldBeRequiredToFail ? orig_shouldBeRequiredToFail(self, _cmd, gr, other) : NO;
}

static void hook_handlePan(DockFlipController *self, SEL _cmd, UIPanGestureRecognizer *pan) {
    if (!DFEIsVerticalDock(self)) {
        if (orig_handlePan) orig_handlePan(self, _cmd, pan);
        return;
    }
    UIView *dock = self.dock;
    if (!dock) return;

    UIGestureRecognizerState st = pan.state;
    if (st == UIGestureRecognizerStateBegan) {
        [self stopSpring];
        self.panStartProgress = self.progress;
        CGPoint t = [pan translationInView:dock];
        self.progress = [self progressForDragFrom:self.panStartProgress translation:t.y];
        [self applyProgress];
    } else if (st == UIGestureRecognizerStateChanged) {
        CGPoint t = [pan translationInView:dock];
        self.progress = [self progressForDragFrom:self.panStartProgress translation:t.y];
        [self applyProgress];
    } else if (st == UIGestureRecognizerStateEnded) {
        CGPoint t = [pan translationInView:dock];
        self.progress = [self progressForDragFrom:self.panStartProgress translation:t.y];
        [self applyProgress];
        CGPoint v = [pan velocityInView:dock];
        double travel = [self travel];
        double velProg = (travel > 1.0) ? (-v.y / travel) : 0.0;
        double target = [self targetForProgress:self.progress velocity:velProg];
        [self springTo:target velocity:velProg];
    } else if (st == UIGestureRecognizerStateCancelled || st == UIGestureRecognizerStateFailed) {
        double target = round(self.panStartProgress);
        [self springTo:target velocity:0.0];
    }
}

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

    BOOL vertical = DFEIsVerticalDock(self);

    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    if (vertical) {
        iconList.layer.sublayerTransform = CATransform3DMakeTranslation(0.0, listShift, 0.0);
        if (fabs(listShift) > 0.5 && self.listMask) {
            self.listMask.frame = CGRectOffset(self.platterInList, 0.0, -listShift);
            self.listMask.cornerRadius = self.platterRadius;
            if (iconList.layer.mask != self.listMask) {
                iconList.layer.mask = self.listMask;
            }
        } else if (iconList.layer.mask == self.listMask) {
            iconList.layer.mask = nil;
        }
    } else {
        iconList.layer.sublayerTransform = CATransform3DMakeTranslation(listShift, 0.0, 0.0);
        [self updateListMaskForShift:listShift list:iconList];
    }
    [CATransaction commit];

    iconList.alpha = 1.0 - t;
    self.listFaded = (t > 0.001);

    page.transform = vertical
        ? CGAffineTransformMakeTranslation(0.0, pageShift)
        : CGAffineTransformMakeTranslation(pageShift, 0.0);
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
    DFERelayoutPageVerticallyIfNeeded(self, list);
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
    MSHookMessageEx(cls, @selector(travel), (IMP)hook_travel, (IMP *)&orig_travel);
    MSHookMessageEx(cls, @selector(gestureRecognizerShouldBegin:), (IMP)hook_gestureShouldBegin, (IMP *)&orig_gestureShouldBegin);
    MSHookMessageEx(cls, @selector(gestureRecognizer:shouldBeRequiredToFailByGestureRecognizer:), (IMP)hook_shouldBeRequiredToFail, (IMP *)&orig_shouldBeRequiredToFail);
    MSHookMessageEx(cls, @selector(handlePan:), (IMP)hook_handlePan, (IMP *)&orig_handlePan);
    MSHookMessageEx(cls, @selector(progressForDragFrom:translation:), (IMP)hook_progressForDragFrom_translation, (IMP *)&orig_progressForDragFrom_translation);
    MSHookMessageEx(cls, @selector(targetForProgress:velocity:), (IMP)hook_targetForProgress_velocity, (IMP *)&orig_targetForProgress_velocity);
    MSHookMessageEx(cls, @selector(applyProgress), (IMP)hook_applyProgress, (IMP *)&orig_applyProgress);
    MSHookMessageEx(cls, @selector(tick:), (IMP)hook_tick, (IMP *)&orig_tick);
    MSHookMessageEx(cls, @selector(rebuildPageWithList:), (IMP)hook_rebuildPageWithList, (IMP *)&orig_rebuildPageWithList);

    // Block long-hold jiggle/editing mode strictly for DockFlip extra-page SBIconView proxies
    Class sbIconViewCls = objc_getClass("SBIconView");
    if (sbIconViewCls) {
        SEL fireSel = NSSelectorFromString(@"editingModeGestureRecognizerDidFire:");
        if ([sbIconViewCls instancesRespondToSelector:fireSel]) {
            MSHookMessageEx(sbIconViewCls, fireSel, (IMP)hook_editingModeGestureRecognizerDidFire, (IMP *)&orig_editingModeGestureRecognizerDidFire);
        }
        SEL handleSel = NSSelectorFromString(@"_handleEditingModeGesture:");
        if ([sbIconViewCls instancesRespondToSelector:handleSel]) {
            MSHookMessageEx(sbIconViewCls, handleSel, (IMP)hook_handleEditingModeGesture, (IMP *)&orig_handleEditingModeGesture);
        }
        SEL canDragSel = NSSelectorFromString(@"canBeginDrags");
        if ([sbIconViewCls instancesRespondToSelector:canDragSel]) {
            MSHookMessageEx(sbIconViewCls, canDragSel, (IMP)hook_canBeginDrags, (IMP *)&orig_canBeginDrags);
        }
        SEL dragAfterSel = NSSelectorFromString(@"_contextMenuInteractionShouldAllowDragAfterDismiss:");
        if ([sbIconViewCls instancesRespondToSelector:dragAfterSel]) {
            MSHookMessageEx(sbIconViewCls, dragAfterSel, (IMP)hook_allowDragAfterDismiss, (IMP *)&orig_allowDragAfterDismiss);
        }
        MSHookMessageEx(sbIconViewCls, @selector(touchesBegan:withEvent:), (IMP)hook_touchesBegan, (IMP *)&orig_touchesBegan);
        MSHookMessageEx(sbIconViewCls, @selector(touchesEnded:withEvent:), (IMP)hook_touchesEnded, (IMP *)&orig_touchesEnded);
        MSHookMessageEx(sbIconViewCls, @selector(touchesCancelled:withEvent:), (IMP)hook_touchesCancelled, (IMP *)&orig_touchesCancelled);
        SEL ctxCfgSel = @selector(contextMenuInteraction:configurationForMenuAtLocation:);
        if ([sbIconViewCls instancesRespondToSelector:ctxCfgSel]) {
            MSHookMessageEx(sbIconViewCls, ctxCfgSel, (IMP)hook_ctxConfig, (IMP *)&orig_ctxConfig);
        }
        SEL ctxDispSel = @selector(contextMenuInteraction:willDisplayMenuForConfiguration:animator:);
        if ([sbIconViewCls instancesRespondToSelector:ctxDispSel]) {
            MSHookMessageEx(sbIconViewCls, ctxDispSel, (IMP)hook_ctxWillDisplay, (IMP *)&orig_ctxWillDisplay);
        }
        SEL ctxEndSel = @selector(contextMenuInteraction:willEndForConfiguration:animator:);
        if ([sbIconViewCls instancesRespondToSelector:ctxEndSel]) {
            MSHookMessageEx(sbIconViewCls, ctxEndSel, (IMP)hook_ctxWillEnd, (IMP *)&orig_ctxWillEnd);
        }
        SEL actShortSel = NSSelectorFromString(@"activateShortcut:withBundleIdentifier:forIconView:");
        if ([sbIconViewCls respondsToSelector:actShortSel]) {
            MSHookMessageEx(object_getClass(sbIconViewCls), actShortSel, (IMP)hook_activateShortcut, (IMP *)&orig_activateShortcut);
        }
    }

    Class iconMgrCls = objc_getClass("SBHIconManager");
    if (iconMgrCls) {
        SEL mgrFireSel = NSSelectorFromString(@"iconView:editingModeGestureRecognizerDidFire:");
        if ([iconMgrCls instancesRespondToSelector:mgrFireSel]) {
            MSHookMessageEx(iconMgrCls, mgrFireSel, (IMP)hook_mgr_iconViewEditingFired, (IMP *)&orig_mgr_iconViewEditingFired);
        }
        SEL folderEditSel = NSSelectorFromString(@"folderControllerShouldBeginEditing:withHaptic:");
        if ([iconMgrCls instancesRespondToSelector:folderEditSel]) {
            MSHookMessageEx(iconMgrCls, folderEditSel, (IMP)hook_mgr_folderShouldBeginEditing, (IMP *)&orig_mgr_folderShouldBeginEditing);
        }
        SEL setEditSel = NSSelectorFromString(@"setEditing:");
        if ([iconMgrCls instancesRespondToSelector:setEditSel]) {
            MSHookMessageEx(iconMgrCls, setEditSel, (IMP)hook_mgr_setEditing, (IMP *)&orig_mgr_setEditing);
        }
        SEL setEditFromSel = NSSelectorFromString(@"setEditing:fromIconView:");
        if ([iconMgrCls instancesRespondToSelector:setEditFromSel]) {
            MSHookMessageEx(iconMgrCls, setEditFromSel, (IMP)hook_mgr_setEditingFromIconView, (IMP *)&orig_mgr_setEditingFromIconView);
        }
        SEL setEditFbSel = NSSelectorFromString(@"setEditing:withFeedbackBehavior:");
        if ([iconMgrCls instancesRespondToSelector:setEditFbSel]) {
            MSHookMessageEx(iconMgrCls, setEditFbSel, (IMP)hook_mgr_setEditingWithFeedback, (IMP *)&orig_mgr_setEditingWithFeedback);
        }
    }

    os_log(DFELog(), "[DockFlipEnhance] hooked DockFlipController (v0.2.3 unclamped loop + native SBIconView + full setEditing guard)");
}

__attribute__((constructor))
static void DockFlipEnhanceInit(void) {
    os_log(DFELog(), "[DockFlipEnhance] initialized (v0.2.3)");
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
