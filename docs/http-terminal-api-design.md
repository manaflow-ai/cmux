# cmux 本地 HTTP 终端访问接口 — 技术设计文档

- 日期: 2026-05-28(2026-05-29 按多角色交叉验证评审结论修订)
- 状态: 已评审(VT / ghostty 集成 / API 安全 / 架构 四角色交叉验证),正文已按评审结论修订;详见 §16 附录
- 作者: 二次开发设计
- 范围: 给 cmux 增加一个本地 HTTP 接口，用于读取和写入特定终端 tab(surface)

---

## 1. 目标与动机

给 cmux 增加一个**本地 HTTP 接口**，让外部客户端能够：

1. **读取**指定终端 tab 的内容(可见画面、滚动历史、结构化 cell 网格、原始字节流)。
2. **写入**指定终端 tab(输入文本、按键、原始字节、粘贴)。
3. **订阅**指定终端 tab 的增量输出(流式)。

主要使用场景是**通用全都要**：既要服务 AI agent(只要"干净纯文本"和语义化输入)，也要服务脚本/自动化测试(可预测的结构化输出 + 精确输入控制)，还要能支撑外部 UI / 终端镜像(完整 cell 网格 + 颜色 + 属性 + 光标)。因此接口设计为**分层、按需选择表示形式**。

### 非目标

- 不实现远程/跨机访问。只绑定 `127.0.0.1`。
- 不取代现有 Unix socket / CLI 控制平面；HTTP 是新增的第二个 transport。
- 不在 v1 实现 cell 级别的**增量 diff** 流(见 §11 分期)。
- 不试图解析嵌套多路复用器(tmux/screen)内部的 pane 状态——对 cmux 而言 tmux 只是一个渲染输出的程序(见 §7.4)。

---

## 2. 关键背景与研究结论(避坑)

终端处理有大量历史遗留细节。以下结论来自对 VT/ECMA-48、各家终端工具、以及 ghostty 源码的二次确认，**直接决定了本设计的取舍**。

### 2.1 PTY 输出是带控制序列的字节流
程序写到 PTY 的是**原始字节流**：可打印字符 + 带内(in-band)控制数据(C0 `0x00–0x1F`、C1 `0x80–0x9F`、以及 `ESC` 引导的 CSI/OSC/DCS 转义序列)。终端模拟器是一个状态机，消费这个字节流并改变内存里的"屏幕模型"。

- **读原始流** = 拿到程序输出的全部字节(含光标移动、清屏等瞬态序列)，需要自己再实现一个 parser 才能还原语义。
- **读渲染后的网格** = 拿到所有移动/覆盖/清屏都应用完之后的最终 cell 状态，也就是人眼看到的内容。大多数自动化客户端要的是这个。
- 来源: [xterm ctlseqs](https://invisible-island.net/xterm/ctlseqs/ctlseqs.html), [console_codes(4)](https://man7.org/linux/man-pages/man4/console_codes.4.html)

### 2.2 双屏缓冲区 / 备用屏(alt screen)— vim/tmux 的核心坑
终端有**主屏**(带滚动历史 scrollback)和**备用屏**(固定大小，**没有 scrollback**)。DEC 私有模式:

- `?47h/l`: 最早的实现，切到备用屏，不保存/恢复光标，进入时不清屏。
- `?1047h/l`: 切到备用屏，退出(回主屏)时清空备用屏，不保存/恢复光标。
- `?1049h/l`: 现代组合模式——保存光标 + 切到备用屏 + **进入时清空**；退出时恢复主屏和光标。现代 terminfo(`xterm-256color`)用的就是这个，vim/less/tmux/htop 都发这个。

**推论(本设计必须遵守):**

- 全屏 TUI 跑在备用屏，备用屏没有 scrollback。**vim 打开时读 scrollback，拿到的是 vim 启动之前的 shell 历史，不是 vim 的内容。**
- **读 viewport(可见区域)拿到的是 vim 当前渲染的那一帧。**
- 所以读接口**必须把"读 viewport"和"读历史"做成显式选项**。
- 来源: [how less works](https://jameshfisher.com/2017/12/04/how-less-works/), [xterm ctlseqs DEC 私有模式](https://invisible-island.net/xterm/ctlseqs/ctlseqs.html)

### 2.3 "屏幕"到底是什么
屏幕是一个二维 **cell 网格**。每个 cell = 一个 grapheme(一个基础码点 + 若干组合/ZWJ 码点) + 视觉属性(前景/背景/下划线色、粗体、斜体、faint、闪烁、反显、隐藏、下划线样式、删除线)。另有独立的光标状态(行/列、可见性、样式)。

- **宽字符占 2 个 cell。** 按 UAX #11，East Asian Wide(W)/Fullwidth(F) 字符列宽为 2(CJK 表意文字)，第二个 cell 是不渲染的占位 spacer。组合标记列宽为 0。
- **"一个 cell = 一个字符"是错的。** grapheme 聚类、组合标记、emoji ZWJ、变体选择符都会打破这个假设。宽度必须按 grapheme cluster 计算，不能简单地按码点。
- 来源: [UAX #11](https://www.unicode.org/reports/tr11/), [wcwidth.c](https://www.cl.cam.ac.uk/~mgk25/ucs/wcwidth.c)

### 2.4 软换行(reflow)歧义
当一行在 `DECAWM`(自动换行，默认开)下写满最后一列时，终端**不插入换行符**，而是设置一个"pending-wrap / Last-Column Flag":字形画在最后一列、光标不动，下一个可打印字符才真正折到下一行第 1 列。所以一个被软换行的逻辑行会跨多个网格行，**行之间没有换行字节**，区别只存在于每行的一个 `wrapped` 标志位。

- **朴素的网格→文本会丢掉这个信息。** 直接用 `\n` 拼接所有行，会把一条软换行成 3 行的长命令变成 3 个独立行，且无法和程序真的打印了 3 行区分开。
- **好的抓取器用 wrap 标志**:被标记为 wrapped 的行无分隔符拼接，只有未 wrapped 的行才加真换行。(tmux 用 `-J`；iTerm2 用每行的 hard-newline 布尔；ghostty vt 库用 `WRAP`/`WRAP_CONTINUATION`。)
- 来源: [DECAWM](https://vt100.net/docs/vt510-rm/DECAWM.html), [wraptest](https://github.com/mattiase/wraptest)

### 2.5 现有工具如何暴露终端内容(对标)

| 工具 | 输出形态 | 备注 |
|---|---|---|
| tmux `capture-pane` | 默认渲染纯文本；`-e` 重新发出 SGR 转义；`-J` 拼接软换行行；`-S/-E` 滚动范围 | 纯文本(可选带转义)，**不是**结构化 cell 网格 |
| GNU screen `hardcopy` | 纯文本 dump，`-h` 带 scrollback | 纯文本，无属性 |
| iTerm2 Python API | 结构化:行 + 可选每 cell 样式，每行带 hard-newline 布尔 | Unix 工具里最接近结构化模型的 |
| xterm.js Buffer API | 完整 cell 网格 + 属性(`getCell` → 字符/宽度 0/1/2/颜色/标志) | 必须立即读取(更新时会变) |
| Windows ConPTY / `ReadConsoleOutput` | ConPTY = VT 字节流；旧 `ReadConsoleOutput` = `CHAR_INFO` cell 网格 | 两个世界 |
| AI 编码 agent | 压倒性使用渲染纯文本(常见 `tmux capture-pane` + `send-keys`) | 极少解析属性/网格 |

**结论:纯文本(可选带转义)是事实上的主流交换格式；只有 xterm.js、旧 Windows console API、iTerm2(部分)暴露结构化 cell 网格。** 本设计同时提供纯文本(给主流场景)和 cell 网格(给镜像/UI 场景)。

### 2.6 输入侧的区分
- **字面文本/字节写到 PTY master** = 程序在 stdin 读到的内容。纯文本最简单。
- **按键事件必须编码成字节序列**:方向键、功能键没有字面字节——是转义序列。上箭头 = `ESC [ A`(普通) 或 `ESC O A`(DECCKM 应用光标键模式，**模式相关**);Ctrl+字母 = 控制字节(Ctrl+C = `0x03`);**Enter 发的是 CR `\r`(0x0D)，不是 LF**。所以"发一个按键" ≠ "写一个字节"，需要一个知道当前模式的编码器。
- **括号粘贴模式(DEC 2004)**:程序启用后(`ESC[?2004h`)，终端必须把粘贴内容包成 `ESC[200~ … ESC[201~`，让程序能区分"键入"和"粘贴"(shell/编辑器据此关闭自动缩进、不对内嵌换行立即执行)。**自动化接口写多行内容时必须遵守**:若 2004 激活，把内容包进括号，否则带内嵌 `\r` 的多行粘贴会被逐行当作"按了 Enter"执行(经常是灾难性的)。来源: [xterm bracketed-paste](https://invisible-island.net/xterm/xterm-paste64.html)
  - **评审更正(谁负责剥离/包裹)**:这件事 **ghostty 已经做了**,不是 cmux 重复实现。ghostty 的粘贴编码器(`ghostty/src/.../paste.zig`,评审验证)会**无条件剥离粘贴内容里的所有 `ESC`(0x1B) 字节**,因此内嵌的字面 `ESC[201~`(7-bit)和 8-bit C1 变体都无法存活、无法逃逸出粘贴包裹。`type=text` / `type=paste` 经 `ghostty_surface_text` 走的就是这条路径,所以**这两种输入模式是构造上安全的**。本接口只需调用该 API,不要自己再实现"剥离"逻辑(否则既重复又可能比 ghostty 弱)。
- **换行坑(termios)**:按 Enter 给 tty 的是 **CR `\r`**;cooked 模式下 `ICRNL`(默认开)把输入 CR→NL，程序读到 `\n`;输出侧 `ONLCR` 把 NL→CR-LF。所以"输入命令再回车" = 写命令字节然后 **`\r`**(让 ICRNL 转换)，**不要**假设程序要裸 `\n`。来源: [termios(3)](https://man7.org/linux/man-pages/man3/termios.3.html)
- **kitty 键盘协议 / modifyOtherKeys / CSI u**:传统按键编码本来就有歧义(Esc、Ctrl+字母、Alt+键 与控制/CSI 字节冲突;Tab 与 Ctrl+I 无法区分)。存在三套分层方案,**同一个物理键在不同协议下产生不同字节**。来源: [kitty keyboard protocol](https://sw.kovidgoyal.net/kitty/keyboard-protocol/)
  - **评审更正(谁负责跟踪模式)**:原文说"输入接口必须跟踪/同步这些模式"是**过度表述**。实际上 **ghostty 在编码时就地读取活终端的模式**(DECCKM / kitty / modify_other_keys),由 `ghostty_surface_key` 在 `Surface.zig`(评审验证 ~L3326)完成。**客户端和本接口都不需要跟踪任何键盘模式**——给一个语义键,ghostty 自动产出与程序协商模式相符的字节。这也是 §8.2 `type=keys` 零 patch、开箱即用的原因。

### 2.7 流式/增量读取
没有单一标准。两类做法:
- **订阅字节流(push)**:tmux `pipe-pane` 把 pane 输出接到外部命令;control mode(`-CC`)异步发 `%output <pane> <data>`。给你原始增量输出,但要自己再渲染才得到"当前屏幕"。
- **轮询网格(pull)**:反复 `capture-pane`/读 viewport 并 diff。简单、对快速瞬态输出会丢、每次重抓整屏。

最干净的设计是**字节流订阅(push) + 按需网格快照(pull)**——正好对应 tmux 的 `%output` 与 `capture-pane` 之分。本设计采用这个模型。来源: [tmux control mode](https://github.com/tmux/tmux/wiki/Control-Mode)

### 2.8 ghostty 的两套 API(本设计最关键的发现)

ghostty 有**两套截然不同的 C API**:

**A. embedded/apprt API — cmux 当前用的这套**(`include/ghostty.h`, 来自 `src/apprt/embedded.zig`, 打包成 `GhosttyKit.xcframework`):
- **读**: `ghostty_surface_read_text(surface, selection, &text)`，选择点 tag `GHOSTTY_POINT_VIEWPORT / SCREEN / SURFACE / ACTIVE`。返回的 `ghostty_text_s` **只有一个扁平 UTF-8 字符串**——**没有每 cell 属性、没有颜色、没有宽字符标志、没有软换行标志、没有光标**。底层 `dumpTextLocked` 就是产出纯文本。
- **写**: `ghostty_surface_text(surface, bytes, len)`(字面文本，激活时触发括号粘贴) 和 `ghostty_surface_key(surface, key_event)`(编码按键事件)。cmux 已大量使用这两条路径。
- **结论:用 cmux 当前的 ghostty，cell 网格 + 属性输出模式不打 patch 就做不出来。** 开箱只能拿渲染纯文本 + 写文本/按键。

**B. libghostty-vt — 独立库，暴露你想要的一切，但 cmux 没打包**(`include/ghostty/vt.h`):
- cell 网格遍历(`ghostty_grid_ref_*` / `ghostty_cell_get`，含 `WIDE` 标志:`NARROW/WIDE/SPACER_TAIL/SPACER_HEAD`)、样式(`ghostty_grid_ref_style`)、**软换行标志(`GHOSTTY_ROW_DATA_WRAP` / `WRAP_CONTINUATION`)**、grapheme cluster、光标/渲染状态(`render.h`)、按键编码器(`ghostty_key_encoder_*` 含 `setopt_from_terminal` 同步 DECCKM/kitty/modifyOtherKeys)、括号粘贴助手(`ghostty_paste_encode(..., bracketed, ...)` + `ghostty_paste_is_safe()`)、文本序列化器(`ghostty_formatter_*` 含 `unwrap`/`trim`)。
- **但**:libghostty-vt 是独立 VT 引擎，作用在你喂字节的 `GhosttyTerminal` 上，**没有**和 cmux 跑的活 apprt `Surface`/PTY 连起来。它和 apprt xcframework 在单次构建里互斥。

**对设计的最终判断(用户已批准改 ghostty):**
- **读 = 渲染纯文本是唯一开箱选项。** 要拿结构化 cell 网格 + 属性，需要给 ghostty 的 apprt embedded 层**新增导出**，把活 surface 的 cell/row/style/cursor 暴露出来(底层屏幕模型已存在，只是 C surface 没暴露;libghostty-vt 证明了数据模型和 C ABI 已在代码库里)。
- **写开箱可用**: `ghostty_surface_text`(字面/粘贴，括号粘贴感知) + `ghostty_surface_key`(编码按键)。
- 来源(均为 `ghostty-org/ghostty@main`): [ghostty.h](https://github.com/ghostty-org/ghostty/blob/main/include/ghostty.h), [vt.h](https://github.com/ghostty-org/ghostty/blob/main/include/ghostty/vt.h), [vt/screen.h](https://github.com/ghostty-org/ghostty/blob/main/include/ghostty/vt/screen.h), [vt/style.h](https://github.com/ghostty-org/ghostty/blob/main/include/ghostty/vt/style.h), [vt/paste.h](https://github.com/ghostty-org/ghostty/blob/main/include/ghostty/vt/paste.h), [embedded.zig](https://github.com/ghostty-org/ghostty/blob/main/src/apprt/embedded.zig)

> ⚠️ 常见误区(评审时会被挑战):"libghostty 能给 cell 数据"——只在 **libghostty-vt** 里有，cmux 打包的 **apprt `GhosttyKit.xcframework` 里没有**。设计文档必须明确这两套 API 之分。

---

## 3. cmux 现状(集成点)

来自代码库探查,带文件:行参考:

- **Unix socket 服务器**: `Sources/TerminalController.swift`(`TerminalController` 类)。AF_UNIX / SOCK_STREAM，换行分隔协议，v1 空格分隔明文 + v2 JSON 行。命令分发 `processCommand()`(~L2933) / `processV2Command()`(~L3308)。客户端处理 `handleClient()`(~L2702)。
- **认证**: 基于 `CMUX_SOCKET_PASSWORD` 环境变量,`authResponseIfNeeded()`(~L2221),访问模式 `cmuxOnly` / `allowAll`。
- **现有 socket 的两道本地边界(评审验证,关键)**: `cmuxOnly` 模式下,AF_UNIX socket 还强制两道 **TCP 在结构上无法复制**的对端身份校验——(a) `LOCAL_PEERCRED` **同 UID** 检查(`TerminalController.swift` ~L829,Unix-socket-only 的 getsockopt,AF_INET 没有);(b) **进程后代**校验(`isDescendant` ~L840,在 ~L2705 强制,沿 `e_ppid` 上溯进程树,要求连入进程是 cmux 的后代)。这两道是**不可伪造的内核事实**;bearer token 只是"持有即访问"的秘密。见 §5 的威胁取舍。
- **CLI**: `CLI/cmux.swift`,`SocketClient` 类(~L1647)通过 Unix socket 与服务器通信。
- **终端层级**: Window → `TabManager` → `Workspace`(UUID) → Pane(UUID) → `TerminalPanel`(UUID, `Sources/Panels/TerminalPanel.swift`) → `TerminalSurface`(UUID, 持有 `ghostty_surface_t`, `Sources/GhosttyTerminalView.swift`)。
- **句柄系统**: UUID + 序数 ref(`surface:1`/`workspace:2`/`pane:3`),`v2ResolveHandleRef()`(~L5124) / `v2EnsureHandleRef()`(~L5108) 双向映射。
- **现有读**: socket `read_screen` → `readTerminalTextBase64()` → `readTerminalSelectionText()`(~L9373) → `ghostty_surface_read_text()`(~L9394),返回 base64 UTF-8。纯文本,无属性。
- **现有写**: socket `send` → `terminalPanel.sendInputResult(text)` → `surface.sendInputResult(text)`,经 `pendingSocketInputQueue`(1MB 上限) → `ghostty_surface_text()` / `ghostty_surface_key()`。
- **无现有 HTTP 服务器。** 无 cell 级访问 API。无 PTY 输出 tee/回调。

---

## 4. 总体架构

```
                    ┌─────────────────────────────────────────┐
   HTTP 客户端 ───▶ │ HTTPControlServer (新)                    │
   (agent/脚本/UI)  │  - NWListener: TCP 127.0.0.1 加固 / UDS    │
                    │    独立 token + Host allowlist (见 §5)     │
                    │  - REST 路由 + SSE 流 (背压契约 §9.1)      │
                    └───────────────────┬──────────────────────┘
   CLI ──┐                              │
   Unix  │  现有 socket dispatch  ──────┼──────┐
  socket ┘                              ▼      ▼
                          ┌─────────────────────────────────────┐
                          │ TerminalAccessService (新, 共享核心) │
                          │  - resolve(handle/uuid) -> surface   │
                          │  - readScreen(format, region, ...)   │
                          │  - writeInput(type, payload, ...)    │
                          │  - subscribeOutput(mode) -> stream   │
                          └───────────────────┬──────────────────┘
                                              ▼
                          ┌─────────────────────────────────────┐
                          │ TerminalSurface / GhosttyKit (patched)│
                          │  read_text | read_cells* | key | text │
                          │  pty_output_callback*  (* = 新 patch) │
                          └─────────────────────────────────────┘
```

**核心原则**:HTTP、Unix socket、CLI 三个 transport **共用同一个 `TerminalAccessService`**。遵守仓库的"共享行为策略"(一个共享动作路径,多个入口)。不在 HTTP 层重复实现读写逻辑;HTTP 层只做:解析请求 → 调一个 service 方法 → 把 typed error 映射成 HTTP 状态码。

---

## 5. Transport 与安全

> **评审结论与决策**: 四角色评审一致认为 **UDS-first 才是最安全的**(见 §16);**本项目最终选择"保留 TCP 但加固"**(用户决策)。因此本节按"加固后的 TCP"重写,并把 **HTTP-over-UDS 作为 opt-in 的更强隔离选项**保留。务必理解并接受下面"威胁取舍"里写明的降级。

### 5.1 绑定与实现
- **绑定**: `NWListener`(Network.framework)绑定 `127.0.0.1`,端口可配置,**默认关闭**,在 Settings 里显式开启。
- **HTTP 实现**: Network.framework 手写极简 HTTP/1.1(GET/POST + chunked for SSE)。**不引入 swift-nio**:cmux 已在 `Workspace.swift` 用 `NWListener` 做 loopback 监听(`makeLoopbackListener`,评审验证),Network.framework 是有先例的正确选择。
- **opt-in 更强隔离**: 同一个 `NWListener` 也支持 Unix-domain-socket(`NWEndpoint`)。提供一个 Settings 选项把 transport 切到 **HTTP-over-UDS**(文件权限即认证,浏览器 `fetch` 够不着,且恢复同 UID + 进程后代边界)。给安全要求高的用户/CI 用。

### 5.2 认证(加固后的 TCP)
- **必须 `Authorization: Bearer <token>`**。无 / 错 → `401`。
- **独立 token,不复用 `CMUX_SOCKET_PASSWORD`**(评审 §16-Q2):复用会让"吊销 HTTP token"同时打断 CLI/socket 控制平面;且 `CMUX_SOCKET_PASSWORD` 已被导出进**每个子终端的环境变量**,任何能读该 env 的本地进程都已持有它。HTTP token 必须是独立生成的、**不注入子进程 env** 的秘密,存在只有属主可读处,Settings 里展示供拷贝,可一键轮换。
- **常量时间比较(必须)**: 现有 socket 的 `Sources/SocketControlSettings.swift:133` 用 `expected == candidate`(短路、非常量时间)。HTTP bearer 校验**不得**复用这条;用常量时间比较(等长 + 逐字节累或差),抵御计时侧信道(localhost 高频请求放大该风险)。

### 5.3 浏览器可达性防护(DNS-rebinding)
- **严格 Host allowlist**: 只接受 `Host` 为 `127.0.0.1:<port>` 或 `localhost:<port>`,**其余一律 `403`**。这是抵御 DNS-rebinding 把外部域名指向 `127.0.0.1` 的关键(参考 2025 年同类 CVE:MLflow CVE-2025-14279、MCP-SDK CVE-2025-66414)。
- **`Origin` 只能作否定信号**: 浏览器会带 `Origin`,非浏览器客户端(curl/agent)不带。所以"带了且不在 allowlist → `403`","不带 → 放行"(不能要求必须带,否则打断所有非浏览器客户端)。
- **CORS 默认全拒**: 不发 `Access-Control-Allow-Origin`,不允许任何跨源读取响应。

### 5.4 威胁取舍(必须明确接受)
- **选择 TCP = 接受一次安全降级**(评审一致 blocker,用户已知情接受):TCP 监听器**没有** §3 列出的 `LOCAL_PEERCRED` 同 UID 和进程后代校验,所以**本地任意进程**只要拿到 token 即可读写用户的全部 shell(= 任意 RCE)。token 是这条路径的唯一边界,因此 §5.2 的"独立、不进 env、可轮换、常量时间比较"是底线,不是可选项。
- **缓解**: (a) 默认关闭,Settings 显式开启时给出安全提示;(b) 写操作审计日志(见 §8);(c) 输入限速(见 §8);(d) 给出 UDS opt-in(§5.1)作为消除浏览器可达性与本地进程边界缺失的"想更安全就切这个"的出口。
- **SSE 的认证**: 见 §9——**不能用浏览器原生 `EventSource`**(它无法设置 `Authorization` 头),必须用能带头的 fetch-streaming 客户端,否则 token 只能塞进 URL(会进日志/历史)或用 cookie(引入 CSRF 并削弱本节防护)。

---

## 6. 寻址(Addressing)

复用现有句柄方案,不发明新的:

- `GET /v1/surfaces` — 列出所有终端 tab。每项:
  ```json
  {
    "handle": "surface:1",
    "uuid": "…",
    "workspace": "workspace:1",
    "title": "zsh — ~/proj",
    "cols": 120, "rows": 40,
    "alt_screen": false,
    "focused": true
  }
  ```
- 单个 surface 用 **句柄(`surface:1`)或 UUID** 寻址,二者互换接受(复用 `v2ResolveHandleRef`)。
- 路径形如 `/v1/surfaces/{id}/screen`、`/v1/surfaces/{id}/input`、`/v1/surfaces/{id}/stream`。
- `{id}` 解析失败 → `404`。

---

## 7. 输出:3 种可选表示

`GET /v1/surfaces/{id}/screen?format=…&region=…&wrap=…&trim=…`

> **评审瘦身**: 原 §7.2 `format=ansi` 已删除——它是 `format=cells` 的严格子集(cells 已含全部颜色/属性,客户端要 ANSI 可自行从 cells 重发 SGR),为 v1 减负。输出模式从 4 种收敛到 3 种:`text` / `cells` / `raw`。

### 7.1 `format=text`(默认)— 渲染纯文本
- 渲染后的网格,干净 UTF-8。给 AI agent / 主流脚本。
- `region=viewport|screen|scrollback`。默认 `viewport`。**region→tag 不是简单 1:1(评审 major,源码核验)**:
  | `region` | 语义 | 对应 ghostty 内部 |
  |---|---|---|
  | `viewport` | 当前可见区 | `VIEWPORT` |
  | `screen` | 滚动历史 + 已写活动区 | `SCREEN`(= 内部 `screen`) |
  | `scrollback` | **仅**滚动历史(不含活动帧) | `SURFACE`(C 名 `SURFACE` 实为内部 `history`,**仅 scrollback**——名字有误导性,务必照此表理解) |
  - **必须保留 merge,否则回归(评审 major)**: 没有任何单个 point tag 能在 resize/reflow 边界返回完整内容(三个 tag 的右下界定义不同,接缝处差一两行)。**现有 `read_screen` 正是读 `SCREEN`+`SURFACE`+`ACTIVE` 三者再取最完整的那个**(`TerminalController.swift:9421-9453`,注释明说"不同 tag 在 reflow 边界丢不同的行")。`TerminalAccessService` 的 `format=text` **必须复刻这个 merge**(或显式记录"单 tag 会在 reflow 丢行"并加测试),不能简单透传一个 tag。
  - **更好的做法**: `format=cells`(patch #1)应**直接遍历 page 链**(像 `Screen.zig:2460` 的 `selectionString` 那样,绕过被 clamp 的 point-tag 边界),这样既天然避开 reflow 丢行,又是发出 per-row wrap/wide/semantic 的自然方式,还能让 text/cells 共用一条 page-walk 原语、最终**退役**那套三-tag merge 启发式。见 §10。
- `wrap=preserve|join`:`preserve` 保留网格行(每个网格行一行);`join` 用每行 wrap 标志把软换行行无缝拼接成逻辑行。**默认 `preserve`**(评审更正)。**`join` 在 patch #1 之前不开放**:无 wrap 标志时按列宽猜测会**静默损坏**恰好等宽的输出(`ls -l`、表格、进度条、ASCII art 会被错误拼接,且随终端宽度非确定),对解析结果的 agent 是数据完整性 bug。patch #1 之前 `wrap=join` → `400`(或返回 `wrap_reliable:false`);patch #1 落地后才开放。
- `trim=true|false`:去行尾空白。默认 `true`。
- 响应:
  ```json
  { "format":"text", "region":"viewport", "cols":120, "rows":40,
    "alt_screen":false, "title":"…", "text":"…" }
  ```

### 7.2 `format=cells`— 结构化网格 + 属性(完整镜像)
- JSON 网格,给外部 UI / 终端镜像。
  ```json
  {
    "format":"cells", "cols":120, "rows":40, "alt_screen":true, "title":"…",
    "cursor": { "row":3, "col":10, "visible":true, "style":"block" },
    "semantic_available": true,
    "rows_data": [
      { "wrap": false, "wrap_continuation": false,
        "cells": [
          { "t":"H", "wide":"narrow", "fg":"#c0c0c0", "bg":"#000000", "attrs":["bold"], "semantic":"prompt" },
          { "t":"世", "wide":"wide", "fg":"default", "bg":"default", "attrs":[] },
          { "t":"", "wide":"spacer_tail" }
        ]
      }
    ]
  }
  ```
- 每 cell:`t`=**完整 grapheme cluster** 文本, `wide`=宽度态(见下), `fg`/`bg`(`"default"` 或 `#rrggbb` 或调色板索引), `attrs[]`(bold/italic/faint/blink/inverse/invisible/underline/strikethrough), 可选 `hyperlink`、`semantic`(见下)。
- **schema 必须无损,且 C ABI 一次成型(评审 major,连带 fork 维护成本)**: cells 的 JSON 与 §10 patch #1 的 C ABI 是绑定的——**字段定少了,v2 就得重切一次已发布的 fork C ABI**(正是要避免的 fork 维护churn)。所以一次性把下面四点定全:
  1. **`wide` 用完整四态枚举,不要塌成 `w∈{0,1,2}`**: ghostty 的 `wide` 是 `narrow/wide/spacer_tail/spacer_head`(评审验证 `vt/screen.h:82-95`)。`spacer_tail`=宽字符尾随占位;`spacer_head`=软换行行尾放不下 2 列宽字符时的占位(`page.zig:516` 强制它在 wrapped 行的末列)。把两种 spacer **和**组合标记(宽度 0)都塌成 `w=0` 会把三种语义混为一谈,`wrap=join` 消费端会在软换行接缝处算错宽度(CJK-at-wrap 静默错——对日文用户是真实场景)。原样导出四态。
  2. **per-row 两个 wrap 标志都要**: `WRAP`(本行续到下一行)**和** `WRAP_CONTINUATION`(本行是上一行的续行)(`vt/screen.h:247-254`)。只有 `wrapped` 一个标志时,窗口化/reflow 读无法无歧义重接。
  3. **`t` 是完整 cluster**: 基础码点 + 组合 + ZWJ + VS15/16,宽度按 **cluster** 算而非基础码点,否则 emoji-ZWJ/旗帜会被截断。
  4. **OSC 133 semantic 进核心 cells(可空 + 仅 zsh)**: `semantic` ∈ prompt/input/output(行级 prompt/prompt_continuation),ghostty 已在活 Screen 上跟踪(`vt/screen.h:107-113`)。这是文档 §1 的**首要消费者(AI agent)最需要的字段**——直接区分"我的输入回显 / 提示符 / 程序输出",省掉每个 agent 自己写脆弱的 prompt 正则。**但要诚实标注可靠性**:cmux 关掉了 ghostty 自带 shell-integration(`shell-integration=none`,`GhosttyTerminalView.swift:2481`),改用自己的 `.zshenv` 注入,且**只有 zsh 集成发 OSC 133**(`cmux-zsh-integration.zsh`),bash/fish 不发。所以 `semantic` **可空/可缺省**(绝不默认 "output"),文档标"依赖 shell 集成、当前仅 zsh",并在 `/surfaces` 元数据加 `semantic_available` 布尔让 agent 知道能不能信。`hyperlink`(OSC 8) 价值较低,保持可选即可。
- 示例(无损 schema):
  ```json
  { "t":"世", "wide":"wide", "fg":"default", "bg":"default", "attrs":[] },
  { "t":"",   "wide":"spacer_tail" }
  ```
- 每行带 `wrap` / `wrap_continuation` 标志。顶层带 `cursor` 和屏幕元数据。
- **图形协议出范围**: cells **无法**表示 Sixel/DCS/Kitty-image;一个 cells 镜像会静默丢图。文档明确声明图形读出范围(raw 流里会带 DCS/APC,由消费端自理)。
- 需 §10 的 apprt cell/row/style/cursor 导出(直接 page-walk,见 §7.1/§10)。
- **性能(评审 blocker→已纳入设计)**: 遍历整屏 cell 必须在 `renderer_state.mutex` 下进行(`embedded.zig` ~L1685),长时间持锁会拖慢渲染/打字。**强制**采用 ghostty 现有 `selectionString`(`Screen.zig` ~L2460)同款模式:**持锁期间只做 O(rows×cols) 的"按值拷出"**到一个自有结构(行/cell/style/cursor 全部 copy-out,复用 scratch 缓冲、避免逐 cell 堆分配),**解锁后再做 JSON 序列化**(更贵的那步在锁外)。流式 `mode=cells` 还要叠加节流(见 §9)。

### 7.3 `format=raw`— 原始字节流(**仅流式**)
- PTY 输出的真实字节,含所有转义序列。给自带 VT parser 的客户端做**实时尾随(live-tail)**。
- **只作为流存在**:对"当前屏幕"做一次 raw 字节快照没有意义(raw 本质是流)。所以 `format=raw` 只在 §9 的 stream 端点有效;在 `screen` 端点用 `raw` → `400`。
- **不是"忠实录制/回放"(评审更正)**: 订阅是**前向的、从订阅那一刻起**的字节增量,**没有初始状态前缀**——所以无法据此从零重建当时的屏幕(中途接入的客户端拿不到订阅前已消费的序列)。明确定位为 live-tail;要重建当前屏幕请配合 `GET /screen?format=cells` 取一帧快照再叠加 raw 流。真正的"从生成起完整录制"超出 v1 范围(tee 无法追溯订阅前的字节)。

### 输出侧通用规则(避坑)
- **viewport vs scrollback 永远是显式选择**:这样 alt-screen TUI(vim)无歧义。`region=viewport` 永远返回活帧(vim 那一帧)。**alt 屏下 `region=scrollback` 返回空(评审源码核验更正)**:备用屏以 `max_scrollback=0` 创建(`Terminal.zig:2989-2991`),且 apprt point tag 只读"活动屏"——所以 vim 打开时读 scrollback 拿到的是**空**,不是 vim 之前的主屏历史(主屏是另一个 Screen,活动屏 tag 够不着)。要拿 vim 之前的主屏历史,得等 TUI 退出回主屏后再读,或由 patch #1 的 page-walk 显式访问非活动主屏(后者超出 v1)。
- **元数据永远带 `alt_screen` 和 `title`**:客户端据此判断当前是不是 TUI。
- **嵌套多路复用器(tmux)对 cmux 不透明**:cmux 只能拿到 tmux 渲染出来的输出,拿不到 tmux 内部各 pane 的 scrollback——那是 tmux 自己的职责。这是有意的限制,文档明确。要读 tmux 内部 pane,客户端应直连 tmux 控制接口,不是本接口的职责。
- **直接操作缓冲区的程序(vim/tmux/htop)**:唯一有意义的读法是 viewport 网格(text/cells)或 raw 流。scrollback 在 alt 屏上是空的/前序内容。`format=cells` + `region=viewport` 是镜像 TUI 的正确工具。

---

## 8. 输入:6 种可选模式

`POST /v1/surfaces/{id}/input`,body 形如 `{ "type":"…", … }`。

> **评审更正(输入/输出对称性 major)**: 原设计输出做了 3-4 种格式、输入却只有键盘,导致 §1 宣传的"交互式终端镜像"用例**自相矛盾**——你能渲染 htop/fzf/vim-mouse,却**点不动**它们(无鼠标、无焦点上报)。评审验证 **apprt API 已经有鼠标/焦点写入、零 patch**:`ghostty_surface_mouse_button`(`ghostty.h:1152`)、`mouse_pos`(:1156)、`mouse_scroll`(:1160)、`set_focus`(:1129),且 ghostty 会按活动鼠标模式(X10/normal/button/any × SGR/UTF8)编码正确字节(与 `keys` 同样的"语义事件入、模式正确字节出")。因此补上 `type=mouse` / `type=focus`,让交互式镜像用例真正成立(写入侧因此对 keyboard+mouse+focus 已完整;只有读出侧 cells/raw 需要 ghostty patch)。

### 8.1 `type=text`— 字面文本(括号粘贴感知)
```json
{ "type":"text", "text":"echo hello", "submit": true }
```
- 经 `ghostty_surface_text` 写字面 UTF-8。**括号粘贴/转义剥离由 ghostty 负责**(评审更正,见 §2.6):surface 的 2004 模式激活时 ghostty 自动包 `ESC[200~…ESC[201~`,并**无条件剥离内容里所有 `ESC` 字节**(`paste.zig`),所以内嵌 `ESC[201~`(含 8-bit C1)无法逃逸。本接口只调 API,不自实现剥离。→ 因此 **`type=text` 是构造上安全的**,不需要 §8.3 那种额外门控。
- `submit:true` 在末尾追加 Enter(CR)。
- **换行处理(避坑)**:Enter = `\r` 不是 `\n`。要执行命令用 `submit:true` 或 `keys:["Enter"]`,**不要**靠在 `text` 里塞 `\n`(在括号粘贴里 `\n` 会被当作内容的一部分,不会执行)。文档明确这一语义。
- **已知残留(minor)**: 2004 模式的"读-然后-写"在**跨多次调用**之间存在语义竞争(两次 `text` 调用之间程序可能切换 2004)。单次调用内 ghostty 在 IO 线程同步读模式编码,无 intra-write 竞争。要绝对原子的多行粘贴,用单次 `type=paste`(由 service 在一次调用内完成包裹)。

### 8.2 `type=keys`— 语义化按键
```json
{ "type":"keys", "keys": ["Enter","Ctrl+C","Up","Escape","F5","Alt+x"] }
```
- 每个键经 `ghostty_surface_key` 编码,**按 surface 当前激活的模式**(DECCKM/kitty/modifyOtherKeys)产出正确字节(评审验证零 patch、客户端不跟踪模式,见 §2.6)。
- **这是发方向键/Ctrl/功能键的正确方式**:不硬编码 `ESC[A`,把编码委托给 ghostty,自动跟随程序协商的模式。
- 键名语法:`Mod+Mod+Key`,Mod ∈ {Ctrl,Alt,Shift,Cmd},Key ∈ 字母/数字/`Enter`/`Tab`/`Escape`/`Up`/`Down`/`Left`/`Right`/`Home`/`End`/`PageUp`/`PageDown`/`F1`..`F12`/`Space`/`Backspace`/`Delete` 等。
- **实现复用(评审)**: 现有 socket 已有 `send_key` 编码路径。`type=keys` 必须走**同一条共享编码实现**(经 `TerminalAccessService`),不要在 HTTP 层另写一份(遵守仓库共享行为策略)。

### 8.3 `type=raw`— 原始字节(**独立默认关闭门控**)
```json
{ "type":"raw", "bytes_base64": "…" }
```
- base64 解码后直接写 PTY,**不做编码/不做括号粘贴包裹/不做 ESC 剥离**。给确切知道要发什么字节的高级客户端。
- **⚠️ 这是本接口最高爆炸半径的写路径(评审 major)**: 未净化的字节可发 OSC 52(读/写系统剪贴板)、DCS、以及查询序列(DA/DECRQSS/DSR)——**这些查询的回复会被终端当作 stdin 注入回 shell**,可构成反射式命令注入。`text`/`keys`/`paste` 都没有这个问题(ghostty 编码器会剥离),只有 `raw` 有。
- **必须独立门控**: `type=raw` 需要一个**独立于 `text`/`keys` 的、默认关闭**的开关(Settings 单独项)。即使 HTTP 接口本身已开,`raw` 仍默认禁用,显式开启时给出"任意控制序列注入"警告。未开启时 `type=raw` → `403`。

### 8.4 `type=paste`— 显式括号粘贴
```json
{ "type":"paste", "text":"多行\n内容…" }
```
- 无论 2004 是否激活都按括号粘贴语义发送。包裹由 **service 在单次调用内原子完成**(避免跨调用的 2004 竞争);ESC 剥离仍由 ghostty 编码器负责。可视为 `text` 的显式变体,语义更清晰。

### 8.5 `type=mouse`— 鼠标事件
```json
{ "type":"mouse", "action":"press|release|move|scroll", "button":"left|middle|right", "x":10, "y":3, "mods":["ctrl"], "scroll_dy":-1 }
```
- 经 `ghostty_surface_mouse_button` / `mouse_pos` / `mouse_scroll`,由 ghostty 按 surface 当前鼠标模式(DEC 1000/1002/1003 + 1006 SGR)编码。坐标用 cell 行列(由 service 换算)。
- **关键实现约束(评审,必须遵守)**: HTTP 鼠标事件**必须直接调 `ghostty_surface_mouse_*`**,**绝不**合成 `NSEvent` 走 AppKit hit-test 路径——`TerminalWindowPortal.hitTest()` 是按键/指针门控的打字延迟敏感路径(CLAUDE.md 热路径约束),走它会命中延迟敏感路径。这与 §9.1 的 tee-under-mutex 同属"正确 API、错误线程/路径"风险族。

### 8.6 `type=focus`— 焦点事件
```json
{ "type":"focus", "gained": true }
```
- 经 `ghostty_surface_set_focus`,发 DEC 1004 焦点上报(若程序启用)。让镜像端能告诉 TUI "我聚焦了/失焦了",避免显示陈旧的失焦帧。同样不抢 macOS app 焦点(纯协议上报)。

### 输入侧通用规则
- 文本 vs 按键的区分对应 ghostty 两条 API:`text`="程序在 stdin 读到的内容";`keys`="物理按键";`mouse`/`focus`="指针/焦点事件,按活动模式编码"。
- **写 = 任意 RCE,必须有护栏(评审 major)**:
  - **审计日志(v1)**: 所有写操作(text/keys/raw/paste)记审计日志——时间、surface、type、字节长度(不必记全文,但 raw 建议记摘要/hash),便于事后排查"谁往我的 shell 写了什么"。成本低、价值高,v1 必做。
  - **输入限速(v1)**: 对写端点做基本限速(每 surface / 每连接),抵御自动化洪泛。超限 → `429 Too Many Requests`。
  - **`raw` 独立门控**(见 §8.3)。
- **1MB 输入队列上限**:超出 → `413 Payload Too Large`。
- 写入默认**不抢焦点**(遵守仓库 socket 焦点策略:非焦点意图命令不改 macOS app 焦点)。可选 `focus:true` 显式聚焦。

---

## 9. 流式输出

`GET /v1/surfaces/{id}/stream?mode=…` → **SSE**(Server-Sent Events)。

- **为什么 SSE**:HTTP 原生,chunked 响应即可实现,输入仍走独立的 `POST /input`(SSE 单向下行正好够用)。WebSocket 列为未来选项(若需双向单连接)。
- **认证(评审 blocker 已修正)**: **不能假设客户端用浏览器原生 `EventSource`**——它无法设置 `Authorization` 头,会逼出 token-in-URL(进日志)或 cookie(引入 CSRF)。**SSE 必须用能带 `Authorization: Bearer` 头的 fetch-streaming 客户端**(`fetch` + `ReadableStream` 读 `text/event-stream`),文档与示例客户端都按这个写。切到 §5.1 的 UDS opt-in 时认证变为文件权限,此问题自然消失。
- `mode=raw`(默认):推 PTY 输出字节增量。对应 tmux `%output`。事件:
  ```
  id: 42
  event: output
  data: {"bytes_base64":"…","seq":42}
  ```
  需 §10 的 PTY 输出回调 patch(patch #2)。
- `mode=cells`:在渲染变化时推**完整 cell 快照**(不是 diff,v1 范围)。事件 `screen`,payload 同 §7.2。**必须节流 + dirty 合并**(≤ N 次/秒,且只在自上次以来脏了才发),并复用 §7.2 的"持锁拷出、锁外序列化"——否则每帧持渲染锁 = 本地 DoS。
- 连接建立时先发一个初始快照/状态事件,之后增量。

### 9.1 背压契约(评审 BLOCKER — 强制)
patch #2 的 PTY 输出 tee 触发点 `Termio.processOutput`(评审验证 `Termio.zig` ~L731)**在持有 `renderer_state.mutex` 时、于 io-reader 线程上**执行。所以**绝不允许**在 tee 回调里直接做网络写或任何阻塞/分配/系统调用——否则会卡住 PTY 排空**并冻结渲染器**(命中仓库明令禁止的打字延迟回归类)。强制设计:

- **tee 回调只做**:把这次 `read` 的字节 `memcpy` 进一个**预分配、有界**的"每订阅者环形缓冲",然后立即返回。零分配、零 syscall、零日志(它在渲染锁下)。
- **有界环 + 溢出丢弃**:每连接环固定上限(几百 KB ~ 低 MB)。**溢出丢最旧 + 递增 `seq`**(制造可见间隙),客户端据此知道丢了数据、回退到 `GET /screen` 重新取整屏。**绝不**为了背压而阻塞(会传导到渲染锁),也**绝不**无界缓冲(暂停的 `less`/`cat 大文件` 会 OOM)。
- **网络写在别处**:由一条独立的 Network.framework dispatch 队列把环排空写到 socket,完全脱离 io-reader/渲染线程。
- **连接数上限**:每 surface 并发流低位个数(个位数)。N 个订阅者 = 每次 PTY read 在渲染锁下做 N 次 memcpy,上限用来约束持锁开销。
- **心跳**:每 ~15–30s 发一个 SSE 注释行(`: ping`)。它兼做存活探测——`NWConnection` 只在**写**时才暴露对端已死,静默的流没有心跳就发现不了死连接,死订阅者会永久占住它的环。

> `mode=cells` 的资源约束同源:用 §7.2 的持锁拷出 + 节流/合并;`seq` 字段对齐 SSE 原生 `id:`,客户端用 `Last-Event-ID` 重连(v1 至少返回"有间隙、请重新快照",不做完整回放)。

> v1 **不做** cell 级增量 diff(只做 raw 字节增量 + cells 全快照)。cells-diff 推到 v2(见 §11)。

---

## 10. 需要的 ghostty patch(用户已批准)

所有 patch 加在 `ghostty` fork 的 apprt embedded 层(`include/ghostty.h` + `src/apprt/embedded.zig`),把活 `Surface` 的能力暴露成 C API。libghostty-vt 已证明数据模型和 C ABI 存在,只需在 apprt surface 上 surface 出来。

1. **cell 网格读取导出**:新增类似 `ghostty_surface_read_cells(surface, region, &grid)` 的导出,返回行/cell 结构,每 cell 带码点(s)、宽度标志(NARROW/WIDE/SPACER_TAIL/SPACER_HEAD)、style id;配套 style 查询(fg/bg/underline 色 + 标志位)、grapheme 查询、以及 `ghostty_surface_cursor()`(行/列/可见/样式)和每行 `wrapped`/`wrap_continuation` 标志。
   - **工作量(评审更正)**: 这**不是**薄薄一层再导出。原文"只需 surface 出来"低估了。活 apprt Surface 能拿到 `core_surface.io.terminal.screens.active`(`terminal.Screen`,评审验证 `embedded.zig` ~L1685),其 cell(`page.zig`)已带 `wide`(narrow/wide/spacer_tail/spacer_head ~L490)、per-page hyperlink、per-row `semantic_prompt`、软换行等**全部所需数据**;`dumpTextLocked` 已经用 `screens.active.selectionString` 遍历这些 cell 只是塌成纯文本。所以这是**几百行真实的 Zig 遍历代码**(走 page → C 的 struct-of-arrays + style 查表 + cursor),**低风险但非平凡**。数据模型齐全,不需要新 VT 引擎。
   - **直接 page-walk,不要走 clamped point-tag(评审)**: 实现应像 `Screen.zig:2460` 的 `selectionString` 那样直接遍历 page 链返回自有数据,**不要**用被 clamp 的 point-tag pin(`embedded.zig:1391` 会把 x/y clamp 到屏幕边界,逐 region 迭代会重新引入 §7.1 的 reflow 丢行)。好处:天然避开丢行,是发 per-row wrap/wide/semantic 的自然方式,且 text 与 cells 可共用这一条 page-walk 原语——最终把 §7.1 的三-tag merge 启发式一起退役。
   - **C ABI 一次成型**: 见 §7.2——导出**完整四态 `wide` 枚举 + `WRAP` 与 `WRAP_CONTINUATION` 两个行标志 + 完整 grapheme cluster + OSC 133 semantic**。字段定全一次,避免 v2 重切已发布的 fork C ABI(这正是 fork 维护成本的来源)。
   - **可上游(评审,降低维护担忧)**: 结构化 cell/row/style/cursor 读 C API 是通用能力——libghostty-vt 已为独立引擎导出同形状 C ABI(`vt/grid_ref.h`),所以这是"把已被上游接受的 ABI 形状桥到第二个消费者(apprt surface)",**上游接受概率不低**;`docs/ghostty-fork.md` 自身就写明"有上游 C bridge 就优先用上游"。倾向**主动尝试上游化**,把它从"永久 fork 负担"降为"管理而非恐惧"。
2. **PTY 输出回调**:新增注册一个输出字节回调,在 `Termio.processOutput`(评审验证 `Termio.zig` ~L731,io-reader 线程,每次 `posix.read` 一次,**不在逐字节解析循环里、不在渲染/按键路径上**)tee 一份,供 `mode=raw` 流订阅。无此回调则 raw 流做不出来(现状无任何输出 tee)。
   - **关键约束(评审 blocker)**: 该 tee 点**持有 `renderer_state.mutex`**(`Termio.zig` ~L734)。回调内任何阻塞/网络/分配都会卡渲染器。设计必须遵守 §9.1 的背压契约(只 memcpy 进有界环后返回)。原文 §10 只提了"别在热路径加分配",**漏了"tee 在渲染锁下"这一条**,这里补上,作为 patch #2 的硬约束。
   - **复用既有 seam(评审,降低维护担忧)**: fork 已经为 libghostty iOS 维护着一条双向手动 IO 的 C seam(PR #53:`io_write_cb` + `ghostty_surface_process_output`,`embedded.zig` ~L428/L1919)。输出 tee 是这条已存在 seam 的对称补充,**边际维护成本小**,不是新开一个 fork 维度。

每个 patch:在 fork 提交并推到 `manaflow-ai/ghostty`,更新 `docs/ghostty-fork.md`,再在父仓库更新 submodule SHA(遵守仓库 submodule 安全流程)。GhosttyKit.xcframework 用 ReleaseFast 重建。

> **诚实的 go/no-go(评审)**: 这个特性真正的决策不是"要不要起个 HTTP server",而是"**愿不愿意长期维护两个 apprt fork 补丁(并尽量上游 patch #1)**"。这是该把它当作首要决策摆在台面上,而不是藏在"Phase 0 不碰 ghostty"后面。结合上面的可上游性 + 既有 seam,维护代价是"可管理"而非"永久液体债"。

---

## 11. 分期(Phasing)

> **评审更正(go/no-go 前置)**: 原分期把全部差异化价值(cells / 流式)押在 Phase 1-2 的两个 ghostty 补丁之后,而 Phase 0 只是把 socket 已有的 `read_screen`/`send` 换层 HTTP 皮——**几乎没有新价值,却新增了 TCP 攻击面**。本项目已决定**把 patch #1 砸实进 v1 承诺范围**(不把 cells 藏到"以后"),并在动代码前就承认这是一次 fork-补丁承诺(见 §10)。

- **Phase 0 — service 抽取(独立有价值)**:抽出 `TerminalAccessService`,让现有 socket `read_screen`/`send`/`send_key` 改走它(行为不变,回归测试覆盖)。这是纯内部重构,**不依赖 HTTP server 也成立**,且让 socket/CLI/HTTP 三入口共享一条路径(仓库共享行为策略)。
- **Phase 1 — HTTP transport + patch #1(v1 核心)**:加 `HTTPControlServer`(Network.framework;**默认 TCP 加固,UDS opt-in**,见 §5);实现 `GET /surfaces`、`POST /input`(`text`/`keys`/`paste`;`raw` 独立默认关闭门控)、`GET /screen?format=text`(默认 `wrap=preserve`)。**同期打 patch #1**,实现 `format=cells` 与(patch #1 落地后的)准确 `wrap=join`。cells 是 socket 真正缺、本接口真正新增的能力,属于 v1。
- **Phase 2 — 流式**:打 patch #2(PTY 输出回调 + §9.1 背压契约),实现 SSE `mode=raw`;实现 `mode=cells` 节流全快照流。
- **Phase 3(v2,本设计范围外)**:cell 级增量 diff 流;WebSocket 双向;更多 OSC 元数据(标题/超链接/shell-integration 语义);把 patch #1 推上游。

---

## 12. 错误处理

HTTP 层把 typed domain error 映射成状态码:
- `400` 参数非法(未知 format/region/type、`screen?format=raw`、坏 base64、坏键名)。
- `401` 缺/错 token。
- `403` Origin/Host 校验失败(防 rebinding);或 `type=raw` 门控未开启(见 §8.3)。
- `404` surface 句柄/UUID 解析失败;**功能未在 Settings 启用时整个 `/v1` 也返回 `404`**(不暴露"功能存在但关闭"的信息,评审更正——原 `503` 不合适)。
- `405` 方法不允许;`406`/`415` 内容协商不符;
- `413` 输入超过 1MB 队列上限。
- `429` 写端点超过限速(见 §8)。
- `500` 未预期 defect(与 typed error 分开处理)。
响应 body 统一 `{ "error": { "code":"…", "message":"…" } }`。

---

## 13. 文件组织(遵守仓库包/单类型单文件规则)

- 新包 `Packages/CmuxTerminalAccess/`(或在 app target 内的内聚目录,取决于依赖方向):
  - `TerminalAccessService.swift`(协议 + 实现入口)
  - `ScreenReadRequest.swift` / `ScreenReadResult.swift`
  - `InputWriteRequest.swift`
  - `OutputSubscription.swift`
  - `CellGrid.swift` / `Cell.swift` / `CellAttributes.swift` / `CursorState.swift`(结构化模型,各自单文件)
  - `KeyName.swift`(键名解析 → ghostty key event)
- HTTP 层:
  - `HTTPControlServer.swift`、`HTTPRoute.swift`、`SSEResponder.swift`、`HTTPAuth.swift`
- 因 service 需访问活 surface 注册表(在 app target),用**协议 seam**:低层包定义 `SurfaceProvider` 协议,app target 实现,避免依赖环。
- **包边界(评审 minor)**: `TerminalAccessService`(领域逻辑)与 `HTTPControlServer`(transport)可能属于两个领域。按仓库"一个包一个完整领域"的约束,倾向把 HTTP transport 单独成包(依赖 service 包),而不是塞进同一个包。实现时再定，但别让 service 包反向依赖 HTTP。
- 所有新 `public` 符号配 DocC 三斜线文档(仓库规则)。

### 13.1 仓库强制的配套义务(评审 major — 原文遗漏)
新用户可见特性必须连带完成,否则违反 CLAUDE.md 硬规则:
- **本地化**: Settings 里的开关/说明、所有错误消息字符串,必须用 `String(localized:)` 并在 `Resources/Localizable.xcstrings` 补齐英/日翻译。不得有裸字面量。
- **配置 schema + 文档**: 启用开关(及端口、UDS 路径、`raw` 门控、token)要进 `web/data/cmux.schema.json` 的 `cmux.json` 配置 schema,并在 `docs/configuration.md` 记录。
- **API 文档页**: 给这个 HTTP API 写一份面向用户的文档(端点、格式、鉴权、示例 fetch-streaming SSE 客户端)。
- **键盘快捷键**(若新增): 任何新增的 cmux 快捷键(如"切换 HTTP 接口")要进 `KeyboardShortcutSettings` + 配置 + 快捷键文档(仓库快捷键政策)。本特性默认无新增快捷键。

---

## 14. 测试(遵守仓库测试策略)

- **永不本地跑测试**;E2E/UI 走 CI/VM,unit 优先 CI(`cmux-unit` 安全)。
- **行为级测试,不测源码文本/签名**:
  - key 名 → 字节编码(通过真实 ghostty 编码器,断言产出字节)。
  - `type=text`/`paste` 经 ghostty 编码器后内嵌 `ESC[201~`/`ESC` 被剥离(断言无法逃逸粘贴包裹)。
  - `type=raw` 门控:默认关闭时 → `403`;开启后字节原样到达。
  - `wrap=join` 软换行拼接逻辑(构造已知 wrap 标志的网格 → 断言文本);`wrap=preserve` 为默认。
  - cell 序列化(宽字符 `w=2` + `spacer:"tail"`/`"head"` 区分、组合字符、属性、cursor、per-row wrapped)。
  - **背压**: 模拟慢 SSE 客户端 + 高速输出,断言 tee 不阻塞(环溢出丢最旧 + `seq` 跳变),且不在渲染锁下做网络/分配。
  - HTTP 路由 + auth(401/403/404/413/429 路径)、Host allowlist(伪造 `Host` → `403`)、常量时间 token 比较。
- **集成**:起 server,驱动真实 surface,经 ghostty 端到端断言读/写(行为级)。
- **回归测试两段式提交**(仓库政策):先加失败测试(CI 红)再加修复(CI 绿)。
- 新测试文件必须接进 `cmux.xcodeproj/project.pbxproj`(否则静默不编译/不跑)。

---

## 15. 待确认 / 开放问题(评审后更新)

已决:
- **传输**: 保留 TCP 但按 §5 加固,UDS 作为 opt-in(用户决策;评审一致更安全的是 UDS-first,取舍见 §5.4 / §16)。
- **token**: 独立生成、不进子进程 env、可轮换,**不复用** `CMUX_SOCKET_PASSWORD`(§5.2)。
- **v1 范围**: 砸实 patch #1 + `cells` 进 v1;默认 `wrap=preserve`;删除 `ansi` 与 raw"回放"声明;`keys` 保留但复用 socket `send_key` 编码(§7/§8/§11)。
- **SSE 认证**: fetch-streaming 客户端(可带 `Authorization`),不用浏览器原生 `EventSource`(§9)。
- **错误模型**: 功能关闭用 `404` 而非 `503`;补 `405/406/415/429`(§12)。

仍开放:
1. SSE vs WebSocket:v1 选 SSE。若客户端强需单连接双向,再评估 WebSocket。
2. `cells` **diff** 流(增量)推 v2;v1 只做 `raw` 字节增量 + `cells` 全快照(节流)。
3. patch #1 上游化的具体形态(上游可能要求 grid_ref 而非 bespoke `read_cells`),需与 ghostty 上游对齐(§10)。
4. `wrap=join` 在 patch #1 落地后是否切回默认。
5. 截图里的设计确认点未能解码(HEIC 占位图),尚未纳入。若有需要请补文本。

---

## 16. 附录:多角色交叉验证评审结论与变更记录

> 本节记录 2026-05-29 的独立评审过程与证据链。评审在干净上下文中由四个角色并行进行,**彼此交叉验证**(互相质询、用代码/规范反驳),而非各自汇总。期间发生了两次基于证据的反向定级修正,是交叉验证生效的标志。

### 16.1 角色与方法
- **vt-expert**(VT/终端语义)、**ghostty-eng**(ghostty 集成 + cmux 代码可行性)、**api-security**(HTTP API + 安全)、**architect-skeptic**(架构/范围/YAGNI)。
- 每人独立读文档 + 用 WebSearch/源码核验,然后**点名给其他三人发结论并要求确认/反驳**,处理回信后再给出最终立场。

### 16.2 两次交叉验证修正(过程证据)
- **下调**: api-security 起初把"输入净化可绕过(C1 `0x9B` / 拆分 `ESC[201~` / 2004 TOCTOU)"定为 major;**vt-expert 核验 ghostty `paste.zig` 后更正**——粘贴编码器无条件剥离所有 `ESC`,`text`/`keys`/`paste` 构造上安全。该 major **撤回**,残留仅 `raw`(已独立门控)与一个 minor 的跨调用 2004 语义竞争。
- **上调**: SSE 背压由 major 升为 **blocker**;**ghostty-eng 核验**确认 tee 点 `Termio.processOutput` 持 `renderer_state.mutex`,阻塞写会冻结渲染器(打字延迟违规),而非仅拖慢 PTY 排空。

### 16.3 BLOCKER(已纳入正文)
1. **传输降级**(§5.4):TCP 缺 AF_UNIX 的 `LOCAL_PEERCRED` 同 UID + 进程后代校验(`TerminalController.swift` ~L829/840/2705),token 成唯一边界。评审一致建议 UDS-first;本项目选 TCP 加固 + UDS opt-in,并明确接受降级 + 配齐护栏。
2. **EventSource 无法带 `Authorization`**(§5.4/§9):原文 §5 要求 bearer、§9 用"标准 EventSource"自相矛盾。改为 fetch-streaming 客户端;UDS 下此问题消失。
3. **SSE 背压契约缺失**(§9.1):tee 在渲染锁下,必须只 memcpy 进有界环后返回,溢出丢最旧 + `seq` 跳变,网络写在别处,加心跳与连接上限。

### 16.4 MAJOR(已纳入正文)
- `mode=cells`/`format=cells` 整屏遍历持渲染锁 → 持锁拷出、锁外序列化 + 节流(§7.2/§9)。
- 写 = 任意 RCE:审计日志 + 限速(v1),`type=raw` 独立默认关闭门控 + OSC52/DSR 反射注入告警(§8)。
- 分期回避了真实 go/no-go:Phase 0 仅 socket 能力换皮、却引入 TCP 面;patch #1 砸实进 v1,reframe 为 fork-补丁承诺(§10/§11)。
- 常量时间 token 比较(现 `SocketControlSettings.swift:133` 非常量时间)、严格 Host allowlist、独立 token(§5.2/§5.3)。
- 仓库配套义务遗漏:本地化 / 配置 schema / 文档 / 快捷键(§13.1)。

### 16.5 MINOR / NIT(已纳入正文)
- `raw` "忠实回放"不成立 → live-tail(§7.3)。
- §2.6 "接口须跟踪键盘模式"过度表述 → ghostty 编码时自带(§2.6/§8.2)。
- patch #1 工作量被低估("只需 surface 出来"→ 几百行真实遍历,低风险非平凡)(§10)。
- §8.1 把括号粘贴/剥离误记为 cmux 实现 → 实为 ghostty 编码器(§2.6/§8.1)。
- 错误码补 405/406/415/429;功能关闭用 404 不用 503(§12)。
- cells JSON 不应把 `spacer_tail`/`spacer_head` 都塌成 `w=0`(§7.2)。
- SSE `seq` 对齐原生 `id:`/`Last-Event-ID`(§9)。

### 16.6 评审确认为"稳妥/可行"(无需改)
- 两个 ghostty 补丁**均可行、低风险**;§2.8/§3/§10 的事实性断言**经源码核验准确**。
- **`keys` 模式正确且零 patch**(ghostty 编码时读活模式),仅需复用 socket `send_key`(去重点,非风险)。
- **`text`/`keys`/`paste` 注入安全**(ghostty ESC 剥离)。
- **架构(service + `SurfaceProvider` seam)稳妥**,符合仓库 DAG 与共享行为策略。
- **维护担忧可控**:patch #1 可上游(同 libghostty-vt 已有的 C ABI 形状),patch #2 复用 PR #53 既有手动 IO seam。

### 16.7 评审 → 决策映射
| 评审建议 | 本项目决策 |
|---|---|
| UDS-first | **改为 TCP 加固 + UDS opt-in**(用户决策;接受 §5.4 降级) |
| 砸实 patch #1 进 v1、默认 `wrap=preserve`、删 `ansi`/raw-replay | **采纳** |
| SSE 背压契约 / cells 持锁拷出 / raw 门控 + 审计 + 限速 | **采纳(正文强制)** |
| 配齐本地化/配置/文档义务 | **采纳(§13.1)** |

### 16.8 第二轮深挖的新发现(均已纳入正文)
评审在第一轮修订后又做了一轮源码深挖(pinned ghostty SHA `176bd550`),新增以下经核验的发现:
- **[major] region→tag 是正确性陷阱 + reflow 回归风险**(§7.1):C 名 `SURFACE` 实为 scrollback-only;单 tag 在 reflow 边界丢行,现有 `read_screen` 用三-tag merge(`TerminalController.swift:9421-9453`)。→ 加语义表 + 复刻 merge,或 cells 直接 page-walk 退役该启发式。
- **[major] cells C ABI 有损,且会逼出 v2 fork 重切**(§7.2/§10):必须导出完整四态 `wide`、`WRAP`+`WRAP_CONTINUATION`、完整 grapheme cluster、OSC 133 semantic(可空/仅 zsh)。一次成型。
- **[major] 输入/输出不对称,镜像用例不自洽**(§8):补 `type=mouse`/`type=focus`(apprt 已有 `ghostty_surface_mouse_*`/`set_focus`,零 patch),且必须直调不走 AppKit hit-test。
- **[major] `type=raw` 是不可净化的回复注入**(§8.3):DSR(`ESC[6n`)/DA/OSC 52 的回复被 ghostty 写回 PTY 输入、被 shell 当作键入——净化 payload 无法缓解(危险字节是终端生成的)。→ 独立默认关闭门控 + 审计;或 v1 干脆不出 raw 写。
- **[更正] alt 屏 scrollback 读返回空**(§7 输出通用规则):备用屏 `max_scrollback=0`,apprt tag 只读活动屏。
- **[minor] 图形协议(Sixel/DCS/Kitty-image)出 cells 范围**(§7.2),显式声明。
- **维护成本进一步软化**:fork 活跃维护(~15 个有记录的补丁 + 上游 rebase 节奏,`ghostty-fork.md`),patch #1 可上游(同 libghostty-vt 已有 C ABI 形状),patch #2 复用 PR #53 既有手动 IO seam。
- **[更正] 撤回"token 进每个子终端 env"**:经核验 cmux **不**把 `CMUX_SOCKET_PASSWORD` 注入子终端;§5.4 的降级论证不依赖此点(仍成立,基于缺失 PEERCRED + 后代校验)。
