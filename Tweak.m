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

@interface UIView (DFEPrivate)
- (UIViewController *)_viewControllerForAncestor;
@end

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
@property (nonatomic, assign) BOOL listFaded;
- (double)travel;
- (void)applyProgress;
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
// SpringBoard / AppData / Quick Actions Helpers
// ============================================================================

static UIViewController *DFETopPresenterForView(UIView *sourceView) {
    UIViewController *vc = nil;
    if ([sourceView respondsToSelector:@selector(_viewControllerForAncestor)]) {
        vc = [sourceView _viewControllerForAncestor];
    }
    if (!vc) {
        vc = sourceView.window.rootViewController;
    }
    if (!vc) {
        for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if (![scene isKindOfClass:[UIWindowScene class]]) continue;
            UIWindowScene *ws = (UIWindowScene *)scene;
            for (UIWindow *w in ws.windows) {
                if (w.isKeyWindow && w.rootViewController) {
                    vc = w.rootViewController;
                    break;
                }
            }
            if (vc) break;
        }
    }
    while (vc.presentedViewController && !vc.presentedViewController.isBeingDismissed) {
        vc = vc.presentedViewController;
    }
    return vc;
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

static UIView *DFEFindSBIconViewForBundleID(NSString *bundleID) {
    id icon = DFEFindSBIconForBundleID(bundleID);
    if (!icon) return nil;
    Class iconCtrlCls = NSClassFromString(@"SBIconController");
    if (!iconCtrlCls || ![iconCtrlCls respondsToSelector:@selector(sharedInstance)]) return nil;
    id iconCtrl = ((id (*)(id, SEL))objc_msgSend)(iconCtrlCls, @selector(sharedInstance));
    SEL iconManagerSel = NSSelectorFromString(@"iconManager");
    if (!iconCtrl || ![iconCtrl respondsToSelector:iconManagerSel]) return nil;
    id mgr = ((id (*)(id, SEL))objc_msgSend)(iconCtrl, iconManagerSel);
    if (!mgr) return nil;

    SEL displayedSel = NSSelectorFromString(@"displayedIconViewForIcon:");
    if ([mgr respondsToSelector:displayedSel]) {
        id v = ((id (*)(id, SEL, id))objc_msgSend)(mgr, displayedSel, icon);
        if ([v isKindOfClass:[UIView class]]) return (UIView *)v;
    }
    SEL firstSel = NSSelectorFromString(@"firstIconViewForIcon:");
    if ([mgr respondsToSelector:firstSel]) {
        id v = ((id (*)(id, SEL, id))objc_msgSend)(mgr, firstSel, icon);
        if ([v isKindOfClass:[UIView class]]) return (UIView *)v;
    }
    return nil;
}

static NSString *DFEAppDisplayName(NSString *bundleID) {
    if (bundleID.length == 0) return @"";
    id icon = DFEFindSBIconForBundleID(bundleID);
    if (icon && [icon respondsToSelector:@selector(displayName)]) {
        NSString *name = ((id (*)(id, SEL))objc_msgSend)(icon, @selector(displayName));
        if (name.length > 0) return name;
    }
    Class proxyCls = NSClassFromString(@"LSApplicationProxy");
    SEL proxySel = NSSelectorFromString(@"applicationProxyForIdentifier:");
    if (proxyCls && [proxyCls respondsToSelector:proxySel]) {
        id proxy = ((id (*)(id, SEL, id))objc_msgSend)(proxyCls, proxySel, bundleID);
        SEL locNameSel = NSSelectorFromString(@"localizedName");
        if (proxy && [proxy respondsToSelector:locNameSel]) {
            NSString *name = ((id (*)(id, SEL))objc_msgSend)(proxy, locNameSel);
            if (name.length > 0) return name;
        }
    }
    return bundleID;
}

static void DFEOpenApplication(NSString *bundleID) {
    if (bundleID.length == 0) return;
    Class wsCls = NSClassFromString(@"LSApplicationWorkspace");
    SEL defaultSel = NSSelectorFromString(@"defaultWorkspace");
    SEL openSel = NSSelectorFromString(@"openApplicationWithBundleID:");
    if (wsCls && [wsCls respondsToSelector:defaultSel]) {
        id ws = ((id (*)(id, SEL))objc_msgSend)(wsCls, defaultSel);
        if (ws && [ws respondsToSelector:openSel]) {
            BOOL ok = ((BOOL (*)(id, SEL, id))objc_msgSend)(ws, openSel, bundleID);
            if (ok) return;
        }
    }
    UIApplication *app = [UIApplication sharedApplication];
    SEL launchSel = NSSelectorFromString(@"launchApplicationWithIdentifier:suspended:");
    if ([app respondsToSelector:launchSel]) {
        ((void (*)(id, SEL, id, BOOL))objc_msgSend)(app, launchSel, bundleID, NO);
    }
}

static BOOL DFEIsAppDataAvailable(void) {
    return (NSClassFromString(@"ADAppData") != nil && NSClassFromString(@"ADDataViewController") != nil);
}

static void DFEPresentAppData(NSString *bundleID, UIImage *iconImage, UIView *sourceView, BOOL fromContextMenu) {
    if (bundleID.length == 0 || !DFEIsAppDataAvailable()) return;

    void (^presentBlock)(void) = ^{
        @try {
            Class adAppDataCls = NSClassFromString(@"ADAppData");
            Class adVCCLS = NSClassFromString(@"ADDataViewController");
            SEL makeSel = NSSelectorFromString(@"appDataForBundleIdentifier:iconImage:");
            SEL initSel = NSSelectorFromString(@"initWithAppData:");
            if (![adAppDataCls respondsToSelector:makeSel]) return;

            id appData = ((id (*)(id, SEL, id, id))objc_msgSend)(adAppDataCls, makeSel, bundleID, iconImage);
            if (!appData) return;

            UIView *realIconView = DFEFindSBIconViewForBundleID(bundleID);
            SEL setIconViewSel = NSSelectorFromString(@"setIconView:");
            if (realIconView && [appData respondsToSelector:setIconViewSel]) {
                ((void (*)(id, SEL, id))objc_msgSend)(appData, setIconViewSel, realIconView);
            }

            UISelectionFeedbackGenerator *feedback = [[UISelectionFeedbackGenerator alloc] init];
            [feedback selectionChanged];

            UIViewController *adVC = ((id (*)(id, SEL, id))objc_msgSend)([adVCCLS alloc], initSel, appData);
            if (!adVC) return;

            UIViewController *presenter = DFETopPresenterForView(sourceView);
            if (presenter) {
                [presenter presentViewController:adVC animated:YES completion:nil];
            } else {
                os_log_error(DFELog(), "No presenter found for AppData (%{public}@)", bundleID);
            }
        } @catch (NSException *ex) {
            os_log_error(DFELog(), "AppData presentation failed for %{public}@: %{public}@", bundleID, ex.reason);
        }
    };

    if (fromContextMenu) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.18 * NSEC_PER_SEC)), dispatch_get_main_queue(), presentBlock);
    } else {
        dispatch_async(dispatch_get_main_queue(), presentBlock);
    }
}

// ============================================================================
// Quick Action Activation (Native SpringBoard Shortcut Execution)
// ============================================================================

static void DFEActivateShortcutItem(id sbsShortcutItem, NSString *bundleID) {
    if (!sbsShortcutItem || bundleID.length == 0) {
        DFEOpenApplication(bundleID);
        return;
    }

    @try {
        // Path 1: Native SBIconView +activateShortcut:withBundleIdentifier:forIconView:
        Class sbIconViewCls = NSClassFromString(@"SBIconView");
        SEL activateSel = NSSelectorFromString(@"activateShortcut:withBundleIdentifier:forIconView:");
        UIView *realIconView = DFEFindSBIconViewForBundleID(bundleID);
        if (sbIconViewCls && realIconView && [sbIconViewCls respondsToSelector:activateSel]) {
            ((void (*)(id, SEL, id, id, id))objc_msgSend)(sbIconViewCls, activateSel, sbsShortcutItem, bundleID, realIconView);
            return;
        }

        // Path 2: Launch via FBSSystemService with UIApplicationShortcutAction
        Class actionCls = NSClassFromString(@"UIApplicationShortcutAction");
        SEL initWithItemSel = NSSelectorFromString(@"initWithShortcutItem:");
        id action = nil;
        if (actionCls && [actionCls instancesRespondToSelector:initWithItemSel]) {
            action = ((id (*)(id, SEL, id))objc_msgSend)([actionCls alloc], initWithItemSel, sbsShortcutItem);
        }

        Class fbsCls = NSClassFromString(@"FBSSystemService");
        SEL sharedSvcSel = NSSelectorFromString(@"sharedService");
        SEL openAppSel = NSSelectorFromString(@"openApplication:options:withResult:");
        if (action && fbsCls && [fbsCls respondsToSelector:sharedSvcSel]) {
            id svc = ((id (*)(id, SEL))objc_msgSend)(fbsCls, sharedSvcSel);
            if (svc && [svc respondsToSelector:openAppSel]) {
                NSDictionary *options = @{
                    @"__Actions": @[action],
                    @"__ActivateSuspended": @NO
                };
                void (^resultBlock)(NSError *) = ^(NSError *err) {
                    if (err) {
                        os_log_error(DFELog(), "FBSSystemService shortcut open failed: %{public}@", err);
                    }
                };
                ((void (*)(id, SEL, id, id, id))objc_msgSend)(svc, openAppSel, bundleID, options, resultBlock);
                return;
            }
        }

        // Path 3: Call SBIconView +activateShortcut:withBundleIdentifier:forIconView: with nil iconView
        if (sbIconViewCls && [sbIconViewCls respondsToSelector:activateSel]) {
            ((void (*)(id, SEL, id, id, id))objc_msgSend)(sbIconViewCls, activateSel, sbsShortcutItem, bundleID, nil);
            return;
        }
    } @catch (NSException *ex) {
        os_log_error(DFELog(), "Shortcut activation exception for %{public}@: %{public}@", bundleID, ex.reason);
    }

    DFEOpenApplication(bundleID);
}

static UIImage *DFEImageForSBSShortcutItem(id sbsItem) {
    if (!sbsItem) return nil;
    @try {
        SEL iconSel = NSSelectorFromString(@"icon");
        if (![sbsItem respondsToSelector:iconSel]) return nil;
        id iconObj = ((id (*)(id, SEL))objc_msgSend)(sbsItem, iconSel);
        if (!iconObj) return nil;

        SEL sysImgSel = NSSelectorFromString(@"systemImageName");
        if ([iconObj respondsToSelector:sysImgSel]) {
            NSString *sym = ((id (*)(id, SEL))objc_msgSend)(iconObj, sysImgSel);
            if (sym.length > 0) {
                UIImage *img = [UIImage systemImageNamed:sym];
                if (img) return img;
            }
        }
        SEL nameSel = NSSelectorFromString(@"name");
        if ([iconObj respondsToSelector:nameSel]) {
            NSString *sym = ((id (*)(id, SEL))objc_msgSend)(iconObj, nameSel);
            if (sym.length > 0) {
                UIImage *img = [UIImage systemImageNamed:sym];
                if (img) return img;
            }
        }
    } @catch (__unused NSException *ex) {}
    return [UIImage systemImageNamed:@"arrow.up.forward.app"];
}

// ============================================================================
// Per-Icon Interaction Delegate (Swipe Up -> AppData, Long Press -> Context Menu)
// ============================================================================

@interface DFEIconInteractionHandler : NSObject <UIContextMenuInteractionDelegate, UIGestureRecognizerDelegate>
@property (nonatomic, copy) NSString *bundleID;
@property (nonatomic, weak) UIImageView *iconView;
@property (nonatomic, strong) UIContextMenuInteraction *contextMenuInteraction;
@property (nonatomic, strong) UISwipeGestureRecognizer *swipeUpGesture;
@end

@implementation DFEIconInteractionHandler

- (void)handleSwipeUp:(UISwipeGestureRecognizer *)gesture {
    if (gesture.state != UIGestureRecognizerStateEnded) return;
    if (!self.iconView || self.bundleID.length == 0) return;
    DFEPresentAppData(self.bundleID, self.iconView.image, self.iconView, NO);
}

- (UIContextMenuConfiguration *)contextMenuInteraction:(UIContextMenuInteraction *)interaction
                        configurationForMenuAtLocation:(CGPoint)location {
    NSString *bundleID = [self.bundleID copy];
    __weak UIImageView *weakIconView = self.iconView;
    if (bundleID.length == 0) return nil;

    return [UIContextMenuConfiguration configurationWithIdentifier:bundleID
                                                   previewProvider:nil
                                                    actionProvider:^UIMenu * _Nullable(NSArray<UIMenuElement *> * _Nonnull suggestedActions) {
        NSMutableArray<UIMenuElement *> *elements = [NSMutableArray array];

        // 1. Dynamic + Static native Quick Actions via SBSApplicationShortcutService
        UIDeferredMenuElement *shortcutSection = [UIDeferredMenuElement elementWithUncachedProvider:^(void (^ _Nonnull completion)(NSArray<UIMenuElement *> * _Nonnull)) {
            Class svcCls = NSClassFromString(@"SBSApplicationShortcutService");
            SEL fetchSel = NSSelectorFromString(@"fetchApplicationShortcutItemsOfTypes:forBundleIdentifier:withCompletionHandler:");
            if (!svcCls || ![svcCls instancesRespondToSelector:fetchSel]) {
                completion(@[]);
                return;
            }

            @try {
                id svc = [[svcCls alloc] init];
                // types = 0x3 (static + dynamic)
                void (^handler)(id) = ^(id result) {
                    NSMutableArray<id> *items = [NSMutableArray array];
                    if ([result isKindOfClass:[NSArray class]]) {
                        [items addObjectsFromArray:(NSArray *)result];
                    } else if (result) {
                        SEL staticSel = NSSelectorFromString(@"applicationShortcutItems");
                        SEL dynSel = NSSelectorFromString(@"dynamicApplicationShortcutItems");
                        SEL bestStaticSel = NSSelectorFromString(@"bestStaticApplicationShortcutItems");
                        if ([result respondsToSelector:bestStaticSel]) {
                            NSArray *a = ((id (*)(id, SEL))objc_msgSend)(result, bestStaticSel);
                            if ([a isKindOfClass:[NSArray class]]) [items addObjectsFromArray:a];
                        } else if ([result respondsToSelector:staticSel]) {
                            NSArray *a = ((id (*)(id, SEL))objc_msgSend)(result, staticSel);
                            if ([a isKindOfClass:[NSArray class]]) [items addObjectsFromArray:a];
                        }
                        if ([result respondsToSelector:dynSel]) {
                            NSArray *a = ((id (*)(id, SEL))objc_msgSend)(result, dynSel);
                            if ([a isKindOfClass:[NSArray class]]) [items addObjectsFromArray:a];
                        }
                    }

                    NSMutableArray<UIMenuElement *> *actions = [NSMutableArray array];
                    NSMutableSet<NSString *> *seen = [NSMutableSet set];
                    SEL titleSel = NSSelectorFromString(@"localizedTitle");
                    SEL subtitleSel = NSSelectorFromString(@"localizedSubtitle");
                    SEL typeSel = NSSelectorFromString(@"type");

                    for (id item in items) {
                        NSString *title = [item respondsToSelector:titleSel]
                            ? ((id (*)(id, SEL))objc_msgSend)(item, titleSel)
                            : nil;
                        if (title.length == 0) continue;
                        NSString *typeStr = [item respondsToSelector:typeSel]
                            ? (((id (*)(id, SEL))objc_msgSend)(item, typeSel) ?: @"")
                            : @"";
                        NSString *dedupKey = [NSString stringWithFormat:@"%@|%@", typeStr, title];
                        if ([seen containsObject:dedupKey]) continue;
                        [seen addObject:dedupKey];

                        UIImage *img = DFEImageForSBSShortcutItem(item);
                        UIAction *act = [UIAction actionWithTitle:title
                                                            image:img
                                                       identifier:nil
                                                          handler:^(__kindof UIAction * _Nonnull action) {
                            DFEActivateShortcutItem(item, bundleID);
                        }];
                        if ([item respondsToSelector:subtitleSel]) {
                            NSString *sub = ((id (*)(id, SEL))objc_msgSend)(item, subtitleSel);
                            if (sub.length > 0 && [act respondsToSelector:@selector(setDiscoverabilityTitle:)]) {
                                act.discoverabilityTitle = sub;
                            }
                        }
                        [actions addObject:act];
                    }

                    dispatch_async(dispatch_get_main_queue(), ^{
                        completion(actions);
                    });
                };

                ((void (*)(id, SEL, NSUInteger, id, id))objc_msgSend)(svc, fetchSel, 3, bundleID, handler);
            } @catch (NSException *ex) {
                os_log_error(DFELog(), "Failed fetching shortcuts for %{public}@: %{public}@", bundleID, ex.reason);
                dispatch_async(dispatch_get_main_queue(), ^{
                    completion(@[]);
                });
            }
        }];
        [elements addObject:shortcutSection];

        // 2. AppData action (when AppData tweak is installed)
        if (DFEIsAppDataAvailable()) {
            UIAction *appDataAction = [UIAction actionWithTitle:@"AppData"
                                                          image:[UIImage systemImageNamed:@"info.circle"]
                                                     identifier:nil
                                                        handler:^(__kindof UIAction * _Nonnull action) {
                UIImageView *iv = weakIconView;
                DFEPresentAppData(bundleID, iv.image, iv, YES);
            }];
            [elements addObject:appDataAction];
        }

        // 3. Fallback Open App action so menu is never empty even if app has no shortcuts & no AppData
        UIAction *openAction = [UIAction actionWithTitle:@"打开 App"
                                                   image:[UIImage systemImageNamed:@"arrow.up.forward.square"]
                                              identifier:nil
                                                 handler:^(__kindof UIAction * _Nonnull action) {
            DFEOpenApplication(bundleID);
        }];
        [elements addObject:openAction];

        NSString *appName = DFEAppDisplayName(bundleID);
        return [UIMenu menuWithTitle:appName children:elements];
    }];
}

- (UITargetedPreview *)contextMenuInteraction:(UIContextMenuInteraction *)interaction
    previewForHighlightingMenuWithConfiguration:(UIContextMenuConfiguration *)configuration {
    UIImageView *iv = self.iconView;
    if (!iv || !iv.window) return nil;
    UIPreviewParameters *params = [[UIPreviewParameters alloc] init];
    params.backgroundColor = [UIColor clearColor];
    CGFloat radius = MIN(iv.bounds.size.width, iv.bounds.size.height) * 0.225;
    params.visiblePath = [UIBezierPath bezierPathWithRoundedRect:iv.bounds cornerRadius:radius];
    return [[UITargetedPreview alloc] initWithView:iv parameters:params];
}

@end

static const void *kDFEHandlerKey = &kDFEHandlerKey;

static void DFEEnhancePageIcons(DockFlipController *ctrl) {
    UIView *page = ctrl.page;
    if (!page) return;

    for (UIView *sub in page.subviews) {
        if (![sub isKindOfClass:[UIImageView class]]) continue;
        UIImageView *iv = (UIImageView *)sub;
        NSString *bundleID = iv.accessibilityIdentifier;
        if (bundleID.length == 0) continue;

        DFEIconInteractionHandler *existing = objc_getAssociatedObject(iv, kDFEHandlerKey);
        if (existing) {
            existing.bundleID = bundleID;
            continue;
        }

        iv.userInteractionEnabled = YES;

        DFEIconInteractionHandler *handler = [[DFEIconInteractionHandler alloc] init];
        handler.bundleID = bundleID;
        handler.iconView = iv;

        // 1. Swipe-up gesture -> AppData
        UISwipeGestureRecognizer *swipeUp = [[UISwipeGestureRecognizer alloc] initWithTarget:handler action:@selector(handleSwipeUp:)];
        swipeUp.direction = UISwipeGestureRecognizerDirectionUp;
        swipeUp.cancelsTouchesInView = YES;
        [iv addGestureRecognizer:swipeUp];
        handler.swipeUpGesture = swipeUp;

        // Prevent tap from firing when user swipes up
        for (UIGestureRecognizer *gr in iv.gestureRecognizers) {
            if ([gr isKindOfClass:[UITapGestureRecognizer class]]) {
                [gr requireGestureRecognizerToFail:swipeUp];
            }
        }

        // 2. Long-press context menu -> Quick Actions + AppData
        UIContextMenuInteraction *menuInteraction = [[UIContextMenuInteraction alloc] initWithDelegate:handler];
        [iv addInteraction:menuInteraction];
        handler.contextMenuInteraction = menuInteraction;

        objc_setAssociatedObject(iv, kDFEHandlerKey, handler, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

// ============================================================================
// DockFlipController Hooks (Bidirectional Infinite Loop + Icon Enhancement)
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
    // Cap to +/- 1 page per drag gesture so fast drags stay predictable
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

    // Cold-boot guard: if DockFlip built the page before our hook attached, enhance lazily on first reveal
    if (t > 0.01 && page.subviews.count > 0) {
        for (UIView *sub in page.subviews) {
            if ([sub isKindOfClass:[UIImageView class]] && sub.accessibilityIdentifier.length > 0) {
                if (!objc_getAssociatedObject(sub, kDFEHandlerKey)) {
                    DFEEnhancePageIcons(self);
                }
                break;
            }
        }
    }
}

// 4. Normalize settled progress back into {0.0, 1.0} once spring finishes
static void hook_tick(DockFlipController *self, SEL _cmd, CADisplayLink *link) {
    orig_tick(self, _cmd, link);

    if (self.link == nil) {
        double p = self.progress;
        if (p < -0.001 || p > 1.001) {
            long idx = lrint(p);
            double norm = (idx & 1) ? 1.0 : 0.0;
            self.progress = norm;
            self.target = norm;
            [self applyProgress];
        }
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

    os_log(DFELog(), "[DockFlipEnhance] hooked DockFlipController (loop + context menu + AppData)");
}

__attribute__((constructor))
static void DockFlipEnhanceInit(void) {
    os_log(DFELog(), "[DockFlipEnhance] initialized");
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
