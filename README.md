# CloakRecorder 录屏隐身

基于 [ScreenCaptureKit](https://developer.apple.com/documentation/screencapturekit) 的 macOS 屏幕录制工具。录制时可以把指定的窗口（或某个 App 的全部窗口）**排除**在画面之外——它们在视频里会变成透明，露出后面的桌面，实现「隐身」效果。

## 功能

- 🎥 录制整个显示器，输出 H.264 / AAC 的 `.mov`
- 👻 排除指定窗口 / 指定 App：被排除的内容不出现在录屏里
- 🎚️ 分辨率（原画 / 1440p / 1080p / 720p）、帧率（24 / 30 / 60）、码率、系统声音均可调
- ⏭️ 续录：选中一条历史记录，接着它继续录制并自动拼接到原视频之后
- 🔄 应用内「检查更新」：对比 GitHub Releases 的最新版本，提示并直达下载

## 系统要求

- macOS 13.0 及以上（Intel 与 Apple Silicon 均支持，产物为 universal 二进制）
- 需要授予「屏幕录制」权限（首次使用在 系统设置 → 隐私与安全性 → 录屏与系统录音 中授权）

## 安装

在 [Releases](https://github.com/wjlin0/CloakRecorder/releases) 页面下载最新的 `.dmg`，打开后把 `CloakRecorder.app` 拖入「应用程序」。

> 应用目前为 ad-hoc 签名（未做 Apple 公证）。首次打开如果被拦截，右键点击 App →「打开」，或在终端执行：
>
> ```sh
> xattr -cr "/Applications/CloakRecorder.app"
> ```

## 从源码构建

```sh
./build-recorder.sh   # 生成 dist/CloakRecorder.app
./make-dmg.sh         # 打包成 dist/CloakRecorder-<版本>.dmg
```

构建依赖 macOS 自带的 Xcode 命令行工具（`swiftc`、`sips`、`iconutil`、`codesign`、`lipo`），无需第三方依赖。

## 使用

1. 打开 App，授予录屏权限。
2. 在「录制」页选择显示器与画质，并在右侧「排除窗口」列表勾选要隐身的窗口 / App。
3. 点击「开始录制」，再次点击「停止录制」即可保存。
4. 「录制记录」页可回看、在访达中显示、续录或删除历史记录。

## 目录结构

```
recorder/             应用源码（SwiftUI + ScreenCaptureKit）
  RecorderEngine.swift   录屏引擎
  ContentView.swift      UI 与 ViewModel
  CloakRecorderApp.swift 入口
dev/make-icon.swift   应用图标绘制脚本
build-recorder.sh     构建 .app
make-icon.sh          生成 AppIcon.icns
make-dmg.sh           打包 DMG
.github/workflows/     GitHub Actions 自动构建并发布 DMG
```

## 更新与发布

仓库的 GitHub Actions 会在推送 `v*` 标签时自动构建并发布一个含 DMG 的 Release。发版步骤：

1. 修改 `build-recorder.sh` 顶部的 `VERSION`；
2. 更新 `CHANGELOG.md`；
3. 提交并打标签推送：`git tag v<版本> && git push origin v<版本>`。

## 许可

[MIT License](LICENSE)