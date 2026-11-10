# 工具与配置

所有工具名以 `like_codex_` 开头。输入操作使用调用该工具的 DSH agent 最近一次取得的 `snapshot_id`，不同 agent 的快照不能混用。快照有效期为 60 秒。AX 标签最多返回 300 个字符，值最多返回 1000 个字符；`value_truncated` 标明值是否被截断。

| 工具 | 参数 | 返回内容 |
|---|---|---|
| `like_codex_status` | 无 | 版本、权限、私有接口可用性、当前前台和键盘焦点 PID |
| `like_codex_apps` | 无 | 应用普通窗口的 PID、window_id、标题、bundle ID、位置和可见状态 |
| `like_codex_observe` | `app` 精确名称或 bundle ID，或 `pid`；可选 `window_id`、`include_image`、`max_elements` | 新快照、AX 元素、窗口信息，可选图片 |
| `like_codex_screenshot` | `snapshot_id` | 目标窗口图片和新快照 |
| `like_codex_click` | `snapshot_id`；`element` 或 `x`、`y`；可选 `button`、`count` | 动作路径、焦点记录、操作后的新快照 |
| `like_codex_type` | `snapshot_id`、`text`；可选 `element` | Unicode 键盘事件投递结果和新快照 |
| `like_codex_key` | `snapshot_id`、`key` | 快捷键投递结果和新快照 |
| `like_codex_set_value` | `snapshot_id`、`element`、`text` | 完整 AX 值写入结果和新快照 |
| `like_codex_scroll` | `snapshot_id`；`element` 或 `x`、`y`；`delta_x`、`delta_y` 至少一个非零 | 像素滚动结果和新快照 |
| `like_codex_drag` | `snapshot_id`、`x`、`y`、`to_x`、`to_y`；可选 `duration_ms` | 拖拽结果和新快照 |

`click` 的 `button` 为 `left` 或 `right`，默认 `left`；`count` 为 1 至 3，默认 1。`drag` 时长为 50 至 5000 ms，默认 350 ms。滚动正 `delta_y` 向上，负值向下，单轴绝对值不超过 10000 像素。

`type` 每次最多接受 2000 个 UTF-16 单元，使用文字事件，不使用系统剪贴板。`set_value` 直接设置完整 AX 值，其应用语义与打字不同，两者不自动互相回退。安全输入框拒绝自动输入。

`key` 支持 `super`、`cmd`、`command`、`ctrl`、`control`、`alt`、`option`、`shift` 修饰键。例如 `super+a`、`ctrl+shift+z`、`Return`、`Left`、`Tab`、`Escape`。字母、数字和常见美式键位按物理键码投递；任意文字使用 `type`。

坐标以返回截图左上角为原点，单位为像素。DSH 附件存储发生缩放时，插件会同步转换元素边界和后续坐标。窗口位置、尺寸或快照内容改变后需要重新观察。

## 返回值

`ok` 表示本次工具调用是否完成，`result` 为模型可读文本，`data` 为结构化观察。图片通过 DSH 附件返回，不把 base64 塞进模型文本。

输入成功返回的 `data.action.route` 区分 `ax_AXPress`、`ax_AXPick`、`pid_mouse`、`pid_unicode_keyboard`、`pid_shortcut`、`ax_value`、`pid_scroll` 和 `pid_drag`。它表示投递方式，不代表业务目标已经达成。

`data.focus` 包括前后前台 PID、WindowServer 键盘焦点 PID、采样次数、最大采样间隔、观测到的变化和鼠标位置。`changed` 记录所有变化，`target_took_focus` 记录后台目标是否取得系统焦点；正常切换到第三个程序不会仅因 PID 改变而中断输入。采样有时间间隔，不能证明两个样本之间完全没有变化。

失败时，`action_may_have_executed: true` 表示输入可能已部分送达。插件不会自动重试。操作已送达但回读失败时，返回 `OBSERVATION_FAILED`，同样需要先观察。

常见错误为 `ACCESSIBILITY_REQUIRED`、`SCREEN_RECORDING_REQUIRED`、`STALE_SNAPSHOT`、`WINDOW_MINIMIZED`、`WINDOW_OFFSCREEN`、`AX_UNRESPONSIVE`、`SECURE_INPUT`、`FOCUS_CHANGED` 和 `UNSUPPORTED_BACKGROUND`。

## 配置

| 配置 | 默认值 | 含义 |
|---|---|---|
| `driverPath` | 包内当前 CPU 架构的驱动 | 可选的自建驱动绝对路径 |
| `requestTimeoutMs` | `30000` | 单次原生请求超时 |
| `includeImages` | `true` | 观察和操作后回读是否包含图片 |
| `maxElements` | `250` | AX 元素上限，范围 1 至 1000 |
| `allowedApps` | `[]` | 允许的 bundle ID 列表，空数组不限制 |

插件默认 patch 使用以上默认值，没有启用前台回退的配置项。
