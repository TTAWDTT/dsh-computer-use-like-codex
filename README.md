# dsh-computer-use-like-codex

为 DSH 提供 macOS 后台窗口观察、点击、文字输入、快捷键、滚动和拖拽。插件使用自己编写的 Swift 驱动，不需要 Codex、ChatGPT 或 CuaDriver，也不调用它们的服务。

当前交付版本为 0.1.0，要求 DSH 0.2.2-rc.1 或兼容的 0.2 版本，安装包包含 Apple Silicon 驱动。macOS 最低部署版本为 14.4，实际验证环境见 [VERIFICATION.md](VERIFICATION.md)。

## 安装到 DSH

从 [v0.1.0 Release](https://github.com/TTAWDTT/dsh-computer-use-like-codex/releases/tag/v0.1.0) 下载 `dsh-computer-use-like-codex-0.1.0.tgz`。将终端切到下载目录，再通过 DSH 的插件管理器安装：

```sh
dsh plugin --profile desktop add ./dsh-computer-use-like-codex-0.1.0.tgz
```

安装后，在 DSH 中调用 `like_codex_status`。`accessibility` 和 `screen_recording` 表示当前驱动宿主的权限状态。按 [PERMISSIONS.md](PERMISSIONS.md) 配置缺少的权限，然后重新加载插件。

## 操作一个窗口

1. 调用 `like_codex_apps`，选择你要操作的窗口，并取得 `pid` 与 `window_id`。
2. 调用 `like_codex_observe`，传入这两个数值。它返回 AX 元素、截图和 `snapshot_id`。模型不支持图片时，传 `include_image: false`。
3. 点击时传该 `snapshot_id` 和元素编号，或截图中的 `x`、`y`。输入文字时传 `text`，必要时指定输入框元素。
4. 检查操作返回的新界面。下一次输入使用新 `snapshot_id`。

快照过期、窗口移动、操作失败或操作被取消后，重新观察。不要直接重复结果不确定的点击或输入。

插件只选择已运行应用的精确名称、bundle ID 或 PID，不按模糊名称猜测目标。多窗口应用需要指定 `window_id`。最小化和离屏窗口会被拒绝，插件不会自动还原窗口或切换 Space。同一前台进程的另一个窗口也会被拒绝输入。

## 从源码构建和验证

需要 Node.js 22.18 或更高版本，以及 Xcode Command Line Tools。在源码目录执行：

```sh
npm run build
npm test
npm run test:live
npm run test:dsh
npm pack
```

`test:live` 创建临时红色目标和绿色见证窗口，并短暂切换它们来校准观察器。它还故意让目标取得焦点，以验证中止和恢复路径。它实际发送输入、采样屏幕与键盘焦点，并在临时目录保存证据。测试时保持这几个窗口不被手动移动。非零退出表示失败或测量被外部操作中断，不能计为通过。

`test:dsh` 在临时 DSH_HOME 中安装包并验证工具注册、SDK 参数校验、驱动状态和真实图片附件，不调用模型。它不会安装到你的 desktop profile。需要已安装的 `dsh` 命令。

工具和配置的完整参数见 [API.md](API.md)，实现范围见 [ARCHITECTURE.md](ARCHITECTURE.md)。
