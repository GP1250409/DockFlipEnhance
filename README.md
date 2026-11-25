# DockFlipEnhance

面向 **iOS 16.6 + Relaxin RootHide (`arm64e`)** 的 `DockFlip`（`wiki.qaq.dockflip`）独立增强补丁，与 `DockFlipBadge`（角标同步）完全独立、互不冲突。

## 功能特性

1. **Dock 双屏双向循环滑动**
   - Hook `DockFlipController` 的 `progressForDragFrom:translation:`、`targetForProgress:velocity:`、`applyProgress` 和 `tick:`。
   - 将原版 `[0, 1]` 边界阻尼模型改造为周期 `2` 的循环模型：无论在第一屏还是第二屏，向左滑或向右滑均可无缝循环切换至另一屏；弹簧动画停稳后自动将 `progress` 归一到 `0.0` / `1.0`，保持与 `iconTapped:` 及 `followHomePage` 的完全兼容。
2. **扩展页图标长按快捷菜单（Quick Actions）**
   - 在 `rebuildPageWithList:` 后为扩展页每个图标挂载 `UIContextMenuInteraction`，带原生圆角高亮预览。
   - 通过 `SBSApplicationShortcutService` 异步读取并展示该 App 的原生静态/动态快捷动作，点击后优先通过原生 `SBIconView +activateShortcut:withBundleIdentifier:forIconView:` 或 `FBSSystemService` 启动对应快捷动作。
3. **扩展页图标支持 `AppData`**
   - 为扩展页图标绑定向上滑动手势（`UISwipeGestureRecognizerDirectionUp`），并与原有单击手势互斥防误触；
   - 同时在长按快捷菜单中自动注入 **AppData** 菜单项（检测到 `ADDataViewController` 存在时自动显示）。

## 构建方式

### GitHub Actions 自动编译（推荐）
将本目录推送至 GitHub 仓库后，在 **Actions → Build DockFlipEnhance (RootHide arm64e)** 触发构建，即可在 Artifacts 中下载 `iphoneos-arm64e` RootHide `.deb`。

### 本地 Theos 编译
```bash
make package FINALPACKAGE=1 THEOS_PACKAGE_SCHEME=roothide
```
