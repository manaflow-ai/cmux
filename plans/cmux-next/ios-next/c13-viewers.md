# C13 `viewers`: changes, files and documents on the phone

Status: lane C13 of [PLAN.md](PLAN.md), 2026-10-06, branch `feat-cmux-next-ios-c13-viewers` off
`feat-cmux-next-ios` (C4 merged). Covers [a1-shell.md](a1-shell.md) 1.20 items 3 (changes/diff
viewer), 4 (artifact and file viewer) and 7 (Markdown surfaces). Wire: [a0-rpc.md](a0-rpc.md). Host
seams and policy: [b5-mac-host.md](b5-mac-host.md), [c4-files.md](c4-files.md) section 3. Entry:
[c5-workspaces.md](c5-workspaces.md) workspace detail.

## 1. Ownership

| Fact | Owner (single writer) | Phone |
| --- | --- | --- |
| Repository state (branch, HEAD, changes, patches) | the Mac's cmux-tui session host (`git.status`, `git.diff`, read only) | a read result per request, cached per screen, never written |
| Which folders a phone may read | the Mac (`MobileFilePolicy` over `MobileFileRootsProvider`, C4) | learns roots through `files.roots` |
| File bytes | the Mac file system | a downloaded copy in `Caches/cmux-viewers/` (C4 download) |
| Scope, unified/split, selected file, scroll | the phone (client view state) | per screen |

Nothing here is shared or mirrored state: no DO, no stream, no op. Every git fact is a `read` on the
Mac's `rpc` channel (stream plane), answered from the session host at request time. A "Refresh"
reissues the read; there is no subscription (the daemon has no git change stream yet, and polling is
banned).

## 2. Wire (A0 family `git`, stream plane, owner the Mac)

Two reads, served by `CmuxMobileHost` and passed to the daemon's `git.status` / `git.diff`
(`cmux-tui/spec/resource-operations-v2.json`) after the policy below.

- `git.status {path}` -> `{root, branch?, detached, head?, upstream?, base?, ahead, behind}`.
- `git.diff {path, scope, paths?, include_patch?, max_patch_bytes?, max_files?}` ->
  `{scope, root, head?, base?, files: [{path, previous_path?, status, additions, deletions, binary?,
  patch?, patch_truncated?}], additions, deletions, total_files, files_omitted, untracked_skipped?}`.
  `scope` is `uncommitted | unstaged | staged | committed | branch`; `status` is
  `added | modified | deleted | renamed | untracked`. Field names and meanings are the daemon's.
- Errors: `git.not_a_repo` (the path is in scope but not in a repository), `git.forbidden` (outside
  every root, a denied name, or a `paths` entry escaping the scope), `git.failed` (the session host
  failed; retryable). `files.not_found` for a missing path.

Catalog JSON, `families/git.schema.json`, `fixtures/git.json`, Swift `CmuxMobileWire/Git/`
(`GitStatusParams`, `GitStatusResult`, `GitDiffParams`, `GitDiffScope`, `GitDiffResult`,
`GitChangedFile`, `GitChangeStatus`) and TS (`mobileCatalog` plus Effect schemas in
`mobile-wire-git.ts`). Cap `git.read` in `hello.ok` when the host serves the family.

Two-step use, so a reply always fits one frame: the phone reads the file list without patches, then
one file's patch at a time (`paths: [file]`, `include_patch: true`). The host bounds every reply:
`max_patch_bytes` is clamped to 128 KiB, `max_files` to 1000, and an encoded result above 192 KiB
(below `hello.ok.max_frame` 256 KiB) drops the largest patches first (`patch_truncated: true`), then
trailing files (`files_omitted` grows), until it fits.

## 3. Host policy (`CmuxMobileHost/Git`)

Default deny, Mac side only, admitted devices only (B5), read only (no git op is reachable).

1. `path` resolves through the C4 `MobileFilePolicy.resolveExisting` against the device's roots:
   realpath-canonical, inside a root strictly under home, no denied component, no symlink escape.
2. The host asks the daemon for `git.status` of the canonical path to learn the repository `root`.
3. Scope: when the repository root is the matched policy root or inside it, the read is unrestricted
   within the repository. When the repository root is above the policy root (a workspace folder deep
   in a larger repository, or a home-level repository), the diff is restricted to the policy root's
   relative prefix: phone `paths` must lie under it (else `git.forbidden`), and no `paths` becomes
   `[prefix]`. `git.status` still reports that repository's branch (residual: branch name and
   counts of a repository that contains the root are visible).
4. `paths` entries are relative, without `..`, NUL or a leading `/`, at most 256, at most 4096 bytes.
5. Results drop every file whose path or previous path has a denied component
   (`MobilePolicy.isDenied`, case-insensitive), and recompute the totals from what is returned when
   anything was dropped.
6. The daemon call runs through the `MobileGitReader` seam (`read(operation, params) -> JSONValue`);
   the app adapter is `GitResourceClient.read` with a 30 s deadline. Its refusal
   `operation.failed` with `details.extra.code = not_a_repository` maps to `git.not_a_repo`; anything
   else to `git.failed` (retryable).

`MobileGit(configuration:roots:reader:).registering(into:)` adds both read handlers next to C4's.

## 4. Phone modules

- `ios/CmuxiOS/Sources/CmuxiOSViewersCore` (Foundation only; Swift Testing on macOS):
  - Diff: `UnifiedDiffParser` -> `DiffDocument` (hunks, lines with old/new numbers, no-newline
    markers, intra-line emphasis from `IntraLineDiff`), `DiffRowBuilder` flattens a document into
    `DiffRow`s for unified or split layout (removal/addition runs paired side by side), `hunkRows`
    for jump-to-hunk.
  - `ChangedFileTree`: folders from changed paths, single-child folders compressed, sorted folders
    first.
  - `SyntaxHighlighter`: a line lexer with block-comment and multi-line-string state for the common
    families (C-like incl. Swift/Kotlin/Java/JS/TS/Go/Rust/C/C++/C#, Python, Ruby, shell, JSON, YAML,
    TOML, SQL, CSS, HTML/XML, Markdown); tokens are UTF-16 ranges with a kind (keyword, string,
    comment, number, type, punctuation, tag, attribute, heading). `SyntaxLanguage.detect(name:)`.
  - `MarkdownParser` -> `MarkdownDocument` blocks (heading 1-6, paragraph, fenced and indented code
    with info string, block quote, ordered and bullet lists with nesting and task state, table,
    thematic break). Inline markup is rendered by Foundation's `AttributedString(markdown:)` in the
    UI.
  - `ViewerFileKind.classify(name:mime:prefix:)` -> text, markdown, image, pdf, other (NUL in the
    first 8000 bytes is binary). `LineIndex` (line starts in UTF-16, line of an offset).
  - Seam `ViewerContentSource`: `roots(host)`, `list(host, path, after)`, `status(host, path)`,
    `diff(host, request)`, `fetch(host, path) -> URL`. Real `LinkViewerContentSource` over C4's
    `FileHostConnector` (`MobileLinkClient.read`) and `FileTransfer` downloads into
    `Caches/cmux-viewers/<host>/<sha of path>/<name>`; `MockViewerContentSource` serves a canned
    repository and files; `UnavailableViewerContentSource` until a carrier fills the connector.
  - Models (`@MainActor @Observable`): `ChangesModel` (status, scope, file list, tree, per-file
    patch cache with one in-flight read per file, cancellation on scope change), `FileBrowserModel`
    (one folder, paged by `next`).
- `ios/CmuxiOS/Sources/CmuxiOSViewers` (UIKit; en + ja):
  - `ViewersFeature`: `makeChanges(target)`, `makeFiles(target)` and `router`, the `FileViewerHook`
    that replaces C4's QuickLook default.
  - Changes: `ChangesViewController` (scope menu, branch/ahead/behind header, tree or flat list with
    +/- counts) -> `DiffViewController`: a `UICollectionView` list, one row per diff line (cells are
    reused, so a 50k-line diff costs only the visible rows), gutter numbers, highlighted code with
    intra-line emphasis, unified/split toggle (split defaults on regular width), previous/next hunk
    buttons and keyboard commands (`[`/`]`), truncated and binary states.
  - Viewers routed by `ViewerFileKind`: `TextFileViewController` (TextKit 2 `UITextView`, read only,
    highlighted off-main up to 2 MiB, line-number gutter drawn from the visible layout fragments,
    system find bar via `UIFindInteraction`), `MarkdownViewController` (rendered blocks in a TextKit 2
    text view: headings, code blocks with highlighting and a background, quotes, lists, task items,
    tables as aligned monospaced rows, links; "Source" toggles to the text viewer), `ImageViewController`
    (zoom and double-tap), `PDFViewController` (PDFKit, find), QuickLook for the rest.
  - `FileBrowserViewController`: a workspace root's folders and files from `files.list`, paging,
    tap a file to download and open.
  - Dynamic Type through `UIFontMetrics` (monospaced scaled per text style, re-rendered on size
    change), VoiceOver labels per diff row ("Added line 12: ..."), Reduce Motion respected.
- Entry: `WorkspacesFeature.viewers` (`WorkspaceViewerOpening`, defined in CmuxiOSWorkspaces) adds
  "Changes" and "Files" rows to the workspace detail; the composition root adapts `ViewersFeature`.
  The workspace's folder is the `files.roots` root whose id is the workspace id (C4's provider keys
  roots by workspace id).

## 5. Tests

- `CmuxMobileWire`: catalog equality and fixture round trip (existing suites cover the new family),
  typed git params decode from fixtures.
- `CmuxMobileHost`: git read handlers over a fake `MobileGitReader`: outside root refused, denied
  name refused, nested repository unrestricted, repository above the root restricted to the prefix,
  escaping `paths` refused, denied files dropped and totals recomputed, reply bounded under the frame
  budget, `not_a_repository` mapping.
- `CmuxiOSViewersCore`: diff parsing (headers, counts, numbering, CRLF, no-newline marker, rename
  without hunks), split pairing, hunk navigation, file tree, markdown blocks (headings, fences, task
  lists, nested lists, tables, quotes), syntax tokens (strings, comments across lines, keywords),
  file kind classification, models over the mock source.

## 6. Not in this lane

A git change stream (needs a daemon event; until then Refresh), staging or committing from the phone,
review comments, editing files, the in-app browser for HTML artifacts (C14), the agent chat artifact
surfaces (agent GUI is out of scope in PLAN.md), the Mac app adapter for `MobileGitReader` (cmux-next
app wiring, no local Mac build here: `GitResourceClient` already has the call).
