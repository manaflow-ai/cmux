# Quick Open 搜索逻辑

## 入口与触发

- **快捷键** `Cmd+Shift+O`（默认）或 **File → Quick Open…** → 发送 `.commandPaletteFileSearchRequested` 通知
- `ContentView` 收到通知后调用 `openCommandPaletteFileSearch()` → `handleCommandPaletteListRequest(scope: .fileSearch)`
- 初始 query 设为 `@`，输入框前缀触发 `.fileSearch` scope

## Scope 判定（`commandPaletteListScope`）

```
query 前缀    scope
────────────────────────
  >           .commands  （命令面板）
  @           .fileSearch（文件搜索）
  其他        .switcher  （工作区切换）
```

`>` 优先于 `@`（如 `>@` → `.commands`）。在 switcher 中输入 `@` 会自动切到 fileSearch。

## Query 提取

- `commandPaletteQueryForMatching`：去掉 scope 前缀（`>` 或 `@`），返回完整 suffix
- `commandPaletteFileSearchMatchingTerm`：从 matching query 提取搜索词。path 模式取 last `/` 之后的部分（若解析到已存在目录则返回空），cross-directory 返回全文

| 输入 | matching query | matching term |
|---|---|---|
| `@` | `""` (空) | `""` |
| `@/Users/cha` | `"/Users/cha"` | `"cha"`（`/Users` 存在，剩余 `cha` 为搜索词） |
| `@./Sources/Cont` | `"./Sources/Cont"` | `"Cont"` |
| `@main.swift` | `"main.swift"` | `"main.swift"` |

## 搜索模式分流（`commandPaletteFileSearchResolve`）

```
@ + 空/空白
  → path 模式: currentDir = workspace root, searchTerm = ""

@ + ~...、/... 或 ./...
  → path 模式: 展开 ~，resolve 最长存在的目录前缀
    currentDir = 已存在目录, searchTerm = 剩余部分

@ + 其他字符
  → cross-directory 模式: currentDir = workspace root, searchTerm = 完整内容
```

workspace root 为空时回退到 `NSHomeDirectory()`。

### 路径解析（`resolveLongestExistingDirectory`）

从完整路径的末尾向前逐级尝试，找到第一个真实存在的目录：

```
输入: /Users/changtang/Dev/cmux/Sources

尝试:
  /Users/changtang/Dev/cmux/Sources  → 存在 ✓ → 返回此目录, remainder=""
  （若不存在则继续向前找 /Users/changtang/Dev/cmux, 以此类推）

输入: /Users/cha
  /Users/cha  → 不存在
  /Users      → 存在 ✓ → 返回 /Users, remainder="cha"
```

## path 模式 vs cross-directory 模式

| | path 模式 | cross-directory 模式 |
|---|---|---|
| 触发 | `@`、`@/`、`@~`、`@./` 前缀 | 其他输入（如 `@ab`、`@cry/gnu`） |
| 搜索范围 | **单层目录**（`listFilesInDirectory`） | **并行 BFS** + 即时打分 + fast quit |
| 搜索方式 | 单层内 nucleo fuzzy match | raw query 对 workspace 相对路径做 fuzzy match |
| `.` 条目 | 非 root 时追加 | 无 |
| 排序 | 目录优先，名称字母序 | 按 score 降序（即时 top-K） |
| 目录选择 | 选目录进入下一层 path 模式 | workspace 内目录保持 cross-directory 查询 |

### Cross-directory 搜索（`searchCrossDirectory`）

结构化并行 BFS + fast quit。cross-directory 不对输入 query 分词；搜索目标串是每个文件/目录从 workspace root 起算的相对路径。`/` 按普通字符参与匹配，因此 `cry/gnu` 可以命中 `crypto/gnupg.md`，但 `cry/to` 不会只因为 `crypto` 内部有 `to` 而命中。

```
调用任务: BFS(root, depth=0) 收集顶层子目录，同时为 root 级文件打分入全局 top-K

withTaskGroup(topLevelDirs):
  每个 child task: BFS(dir, scoring=on):
    queue = [(dir, depth)]
    while queue:
      if Task.isCancelled: return local top-K
      dir = dequeue
      for entry in contentsOfDirectory(dir):
        if hidden or skip-list: continue
        score = fileSearchCrossDirectoryFuzzyScore(query, relativePath)
        if score > 0: insert local top-K min-heap (K=30)
        if isDir: enqueue (entry, depth+1)

        // Fast quit（三个条件同时满足）
        if query.count >= 3
           && heap.count >= 30
           && heap.min.score >= ideal × 0.618
           && scanned >= 10,000:
             break thread

逐个合并 child task 的 local top-K → 全局 top-30
```

`fileSearchCrossDirectoryFuzzyMatch` 返回 score 和高亮 indices，cross-directory 结果排序和 title 高亮使用同一套匹配规则。

打分规则：

- query 字符必须按顺序出现在相对路径里，`/` 不做特殊解析，只作为必须匹配的字符
- 每个命中字符基础加分
- 命中字符串开头或 `/` 后面的路径分段开头时加分
- 连续命中加分，跳跃匹配按距离扣分
- 候选相对路径越长，尾部长度差扣分越多

### Fast Quit 常量

| 常量 | 值 | 说明 |
|---|---|---|
| `fastQuitKeepMax` | 30 | top-K 大小 |
| `fastQuitMinQueryChars` | 3 | query < 3 字符不启用早停 |
| `fastQuitRatio` | 0.618 | 黄金比，最差分 ≥ ideal × ratio 才饱和 |
| `fastQuitMinScan` | 10,000 | 至少扫够样本再决策 |

### 跳过的目录（`shouldSkipDirectoryForQuickOpen`）

```
.svn  .hg  .build  .cache  .idea  .vscode  .vs  .swiftpm
.eggs  .tox  .dart_tool  .next  .nuxt
node_modules  __pycache__  vendor  bower_components
Pods  Carthage  DerivedData
build  dist  target
```

## 条目结构（`CommandPaletteCommand`）

每条 entry：

| 字段 | 文件 | 目录 | `.` |
|---|---|---|---|
| `id` | `file.quickopen.<pathHash>` | 同左 | `file.quickopen.dot.<dirHash>` |
| `rank` | 1 | 0 | -1 |
| `title` | path 模式: 文件名；cross-directory: 从 workspace root 的相对路径 | 同左 | `.` |
| `subtitle` | 空 | 空 | 当前目录绝对路径 |
| `kindLabel` | File | Directory | Directory |
| `keywords` | path 模式: `[]`（空）；cross-directory: `[文件名] + 路径分段` | 同左 | `[".", "open", "finder", "reveal"]` |
| `dismissOnRun` | true | **false** | true |
| `action` | `openFileInDefaultEditor` | 更新 `commandPaletteQuery` | `NSWorkspace.shared.open` |

### Path 模式触发规则

`commandPaletteFileSearchResolve` 按优先级判断：

1. `~` 或 `/` 前缀 → path 模式（绝对/home 路径）
2. `./` 前缀 → path 模式（workspace 相对路径）
3. 其他 → cross-directory 模糊搜索（包括 `foo/`、`foo/bar` 这类 workspace 相对路径）

### 目录选中后的路径生成（`commandPaletteFileSearchPathForDirectory`）

workspace root 内目录根据 `usePathPrefix` 决定是否加 `./` 前缀。path 模式目录点击传 `usePathPrefix = true`，保持逐级浏览；cross-directory 结果中的 workspace 内目录传 `usePathPrefix = false`，保持 cross-directory 模式继续按 workspace 相对路径搜索。home 下目录始终用 `~` 前缀，其他用绝对路径。所有目录路径追加 `/`。

| 目录位置 | 生成 |
|---|---|
| workspace root 下（path 模式） | `@./Sources/` |
| workspace root 下（cross-directory） | `@Sources/` |
| home 下 | `@~/Develop/` |
| 绝对路径 | `@/opt/homebrew/` |

### 文件打开（`openFileInDefaultEditor`）

| 文件类型 | 行为 |
|---|---|
| 脚本 (`.sh`, `.py`, `.rb`, `.pl`, `.php`) | 默认文本编辑器 |
| 已知二进制 (`.executable`, `.unixExecutable`) | Finder 中显示 |
| 无扩展名可执行 + 检测为文本 (UTF-8 可解码, 无 null byte) | 默认文本编辑器 |
| 无扩展名可执行 + 检测为二进制 | Finder 中显示 |
| 软链接 | 解析到目标后按上述规则 |
| 其他 | `NSWorkspace.shared.open` |

文件打开会先在异步任务中计算打开策略，再回主线程调用 `NSWorkspace`。`isTextFile(at:)` 检测逻辑：读取文件前 4096 字节，包含 `\0`（null byte）→ 二进制，严格 UTF-8 解码成功 → 文本，空文件 → 视为文本。

## 搜索流程

1. `commandPaletteQuery` 变化 → `onChange` 触发 `scheduleCommandPaletteResultsRefresh`
2. scope 变更时清零 `commandPaletteNucleoSearchIndex`（清除旧 index）
3. **Path 模式**：`commandPaletteFileSearchPathEntries` → `listFilesInDirectory` 单层列表 → nucleo 搜索
4. **Cross-directory 模式**：`searchCrossDirectory` 并行 BFS + 即时打分 + fast quit，结果已排序直接构建 entries，不走 nucleo pipeline

### Cross-directory 去重

两个 `ContentView` 实例可能收到同一 query 变更。`fileSearchDedupFingerprint` 使用 query + workspace root 确保同一 workspace 的同一 query 只触发一次后台搜索，同时允许不同 workspace 里的同名 query 各自刷新。离开 cross-directory 模式时会清空 token，避免 path 模式结果污染下一次 fuzzy 搜索。

### Cross-directory 取消

`commandPaletteSearchTask` 持有搜索生命周期；新搜索会 cancel 旧 task。`searchCrossDirectory` 和每个 child task 通过 `Task.isCancelled` 退出，避免全局 generation side channel。

## 关键函数索引

纯 Quick Open 搜索/打开逻辑在 `Packages/CmuxCommandPalette/Sources/CmuxCommandPalette/QuickOpen/` 中；`Sources/CommandPaletteQuickOpenFileSearch.swift` 保留 app 侧 `ContentView` wrapper；palette 状态和条目装配仍在 `Sources/ContentView.swift`。

| 函数 | 类型 | 职责 |
|---|---|---|
| `commandPaletteListScope(for:)` | static | 根据 query 前缀判定 scope |
| `commandPaletteQueryForMatching` | static | 提取搜索词（去掉 scope 前缀） |
| `commandPaletteFileSearchFingerprint` | instance | 条目指纹（hash query） |
| `commandPaletteFileSearchPathEntries` | instance | 生成 path 模式条目列表 |
| `resolvedFileSearchWorkspaceRoot` | instance | 获取 workspace root 目录 |
| `commandPaletteFileSearchResolve` | static | 解析 query → (dir, searchTerm, isPathMode) |
| `commandPaletteFileSearchMatchingTerm` | static | 从 matching query 提取搜索词（去掉路径前缀） |
| `resolveLongestExistingDirectory` | static | 找出最长存在的目录前缀 |
| `searchCrossDirectory` | static | 并行 BFS + 即时打分 + fast quit |
| `fileSearchCrossDirectoryFuzzyScore` | static | cross-directory 专用 fuzzy score |
| `fileSearchCrossDirectoryFuzzyMatch` | static | cross-directory 专用 fuzzy match，返回 score 和高亮 indices |
| `insertTopK` | static | min-heap 插入，维护 top-K |
| `ScoredFile` | struct | 即时打分的返回结构 |
| `commandPaletteFileSearchDotEntry` | static | 创建 `.` 条目 |
| `commandPaletteFileSearchPathForDirectory` | static | 目录路径 → 新 query 路径 |
| `openFileInDefaultEditor` | static | 文件打开安全分发（脚本→编辑器，二进制→Finder） |
| `isTextFile` | static | 检测文件是否为文本 |
| `listFilesInDirectory` | static | 单层目录列表（path 模式） |
| `shouldSkipDirectoryForQuickOpen` | static | 判断是否跳过目录 |

## 已知修复记录

| # | 问题 | 根因 | 修复 |
|---|---|---|---|
| 1 | `@/` 不更新搜索结果 | `commandPaletteQueryForMatching` 取 "last slash 之后" 导致 `/` 匹配为空 → 回退到 workspace root | 改为返回完整 suffix，由 `commandPaletteFileSearchResolve` 统一解析 |
| 2 | `Cmd+P` 后输入 `@` 不切换 scope | scope 切换时旧的 nucleo index（workspace 条目）未清除 | scope 变更时清零 `commandPaletteNucleoSearchIndex` |
| 3 | fileSearch 内 `@`→`@/` 不刷新结果 | `hasVisibleResultsForScope` 为 true 阻塞了同步 seeding | `.fileSearch` 始终允许同步 seeding |
| 4 | `@/` 只显示 4 个目录 | `.skipsHiddenFiles` 跳过了 macOS 根目录下的系统隐藏目录 | `listFilesInDirectory` 移除 `.skipsHiddenFiles` |
| 5 | Settings 中不显示 Quick Open | 只加到 `KeyboardShortcutSettings.Action`，未加到 `ShortcutAction`（Settings UI 用） | 同步添加 `ShortcutAction.quickOpenFile` + `displayName` + `group` + `defaultStroke` |
| 6 | `@/b`、`@~/b` 搜索结果为空 | matching query 包含路径字符（`/`、`~`）无法匹配文件名 | 新增 `commandPaletteFileSearchMatchingTerm`，path 模式下仅取 last `/` 之后作为搜索词传入 nucleo |
| 7 | `@~` 不显示 home 目录 | `resolveLongestExistingDirectory` double-insert 了路径开头的空字符串，导致 `//Users/...` | 移除冗余的 `components.insert("", at: 0)` |
| 8 | Shell 脚本/二进制文件意外执行 | `NSWorkspace.shared.open` 对可执行文件走终端 | `openFileInDefaultEditor` 按类型分发：脚本→文本编辑器，二进制→Finder，无扩展名可执行→检测 text/binary |
| 9 | 目录选中后 query 未加 `/`；模式切换不一致 | 路径生成无后缀；path 触发规则不明确 | 追加 `/`；path 前缀限定为 `~`、`/`、`./` |
| 10 | workspace 内目录用了 `~/` 而非 `./` | home dir 检查优先于 workspace root | 调换检查顺序：workspace root → home dir |
| 11 | `@yun` 无结果；`@desktop` 找不到深层文件 | DFS 在大目录耗尽 maxCount；fast quit 过早跳过深层目录 | 改为 **BFS**；移除 fast quit 仅用于深度遍历场景 |
| 12 | path 模式 + 搜索词走向递归搜索 | 与 path 模式语义不符（path 应逐级搜索） | path 模式始终用 `listFilesInDirectory` 单层；cross-directory 才递归 |
| 13 | `@/.t` 命中 `.VolumeIcon.icns` 等不相关文件 | nucleo FFI 对不匹配条目返回 score=0 但不排除；Swift fallback 返回 nil 排除 | `.fileSearch` 结果 `filter { $0.score > 0 }`，不修改 `CommandPaletteNucleoSearch` |
| 14 | cross-directory 打字卡顿 | DFS enumerator 同步主线程 I/O + 遍历后 nucleo 搜索 | 改为 `searchCrossDirectory` 并行 BFS + cross-directory 专用 fuzzy score 即时打分 + fast quit |
| 15 | `@cry/gnu` 搜不到 `crypto/gnupg.md`，或 `@cry/to` 误命中 `crypto` | cross-directory 没有按 workspace 相对路径和 raw query 统一匹配 | cross-directory 使用 `fileSearchCrossDirectoryFuzzyMatch`，`/` 作为 query 字符参与匹配，score 和高亮共用同一规则 |
| 16 | cross-directory 中选中 workspace 内目录后切到 path 模式 | 目录 action 生成了带 `./` 前缀的 query | cross-directory 目录 action 生成无 `./` 的 workspace 相对 query，保持 cross-directory 模式 |

## 单元测试（47 个）

测试类 `QuickOpenFileSearchScopeTests`，位于 `cmuxTests/CommandPaletteQuickOpenFileSearchTests.swift`。

**Scope 判定（4 个）:**
- `testCommandsScopeWithPrefix` — `>` → `.commands`
- `testFileSearchScopeWithPrefix` — `@`、`@/`、`@~`、`@main` → `.fileSearch`
- `testSwitcherScopeWithoutPrefix` — 无前缀 → `.switcher`
- `testCommandsPrefixTakesPriorityOverFileSearch` — `>@` → `.commands`（`>` 优先）

**去重指纹（3 个）:**
- `testFileSearchPathModeDoesNotUseDedupFingerprint` — path 模式不使用 cross-directory 去重
- `testFileSearchCrossDirectoryUsesEffectiveQueryAndWorkspaceForDedupFingerprint` — query + workspace root 共同决定去重
- `testNonFileSearchDoesNotUseFileSearchDedupFingerprint` — 非 file search 不使用该指纹

**Query 提取（5 个）:**
- `testFileSearchMatchingQueryEmpty` — `@`、`@␠` → `""`
- `testFileSearchMatchingQueryRootSlash` — `@/` → `"/"`
- `testFileSearchMatchingQueryHome` — `@~` → `"~"`
- `testFileSearchMatchingQueryPathWithSearch` — `@/Users/cha` → `"/Users/cha"`
- `testFileSearchMatchingQueryCrossDirectory` — `@main.swift` → `"main.swift"`

**Nucleo 搜索词提取（8 个）:**
- `testMatchingTermEmpty` — `""` → `""`
- `testMatchingTermCrossDirectory` — `"main.swift"` → `"main.swift"`
- `testMatchingTermPathOnly` — `"/"` → `""`, `"~"` → `""`
- `testMatchingTermNoPrefixIsCrossDirectory` — 无前缀 → 保持全文
- `testMatchingTermPathWithSearch` — `"/b"` → `"b"`, `"~/Develop"` → `"Develop"`
- `testMatchingTermDotSlashUsesWorkspaceRoot` — `./` 目录判断使用 workspace root
- `testMatchingTermDirectoryWithoutTrailingSlash` — `/tmp` 存在 → `""`, `/tmp/nonexistent` 不存在 → 搜索词
- `testMatchingTermDotfileSearch` — `/.t` → `.t`，`./.git` 像普通 dot path 一样按文件/目录类型处理

**路径解析（11 个）:**
- `testResolveEmptyQueryReturnsWorkspaceRoot` — 空 → workspace root
- `testResolveWhitespaceOnlyReturnsWorkspaceRoot` — 纯空白 → workspace root
- `testResolveHomePrefix` — `~` → home dir
- `testResolveHomeSubdirectory` — `~/Develop` → 以 home 开头
- `testResolveRootSlash` — `/` → `"/"`
- `testResolveCrossDirectoryMode` — `main.swift` → cross-directory
- `testResolveCrossDirectoryModeMultipleWords` — `"content view"` → cross-directory
- `testResolveNilWorkspaceRootFallsBackToHome` — nil root → home
- `testResolveDotSlashEntersPathMode` — `./Sources/` → path mode
- `testResolveDotSlashWithSearch` — `./Sources/Cont` → path mode
- `testResolveNoPrefixIsCrossDirectory` — `"ab"` → cross-directory

**最长目录前缀解析（4 个）:**
- `testResolveExistingRootDirectory` — `/` → `("/", "")`
- `testResolveExistingHomeDirectory` — home path → `(home, "")`
- `testResolveExistingDirectoryWithRemainder` — `home + "/nonexistent"` → `(home, "nonexistent")`
- `testResolveCompletelyNonexistentPath` — `/xyz/foo/bar` → `("/", remainder)`

**路径格式化（5 个）:**
- `testPathForHomeSubdirectory` — home 下 → `"~/"` 前缀
- `testPathForHomeDirectoryItself` — home 本身 → `"~/"` 
- `testPathUnderWorkspaceRoot` — root 下 → 相对路径
- `testPathUnderWorkspaceInsideHome` — root 在 home 内 → 相对路径
- `testPathOutsideWorkspaceAndHome` — `/opt` → 绝对路径

**目录跳过（2 个）:**
- `testKnownSkipDirectories` — `node_modules`, `.build` 等被跳过
- `testNormalDirectoriesNotSkipped` — `Sources`, `lib` 等正常

**Cross-directory raw fuzzy（5 个）:**
- `testCrossDirectorySlashQueryMatchesRelativePath` — `cry/gnu` → `crypto/gnupg.md`
- `testFileSearchCrossDirectoryFuzzyMatchKeepsSlashInQuery` — `/` 保留为 query 字符，并返回高亮 indices
- `testCrossDirectorySlashQueryDoesNotMatchInsideSinglePathComponent` — `cry/to` 不误命中 `crypto/gnupg.md`
- `testSearchCrossDirectoryDeduplicatesSymlinkDirectoryCycles` — symlink 回环不会重复扫描同一真实目录
- `testQuickOpenRelativePathUsesWorkspaceRoot` — cross-directory target 使用 workspace 相对路径
