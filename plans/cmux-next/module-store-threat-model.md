# Module store: threat model (git-distributed modules)

Status: core landed in `cmux-tui/crates/cmux-app-manifest/src/module_store/` (pure logic, tests in
`tests/module_store.rs`). The supervisor wiring, the consent sheet and the store UI are not built yet;
section 7 lists what each one must enforce. Owner: app platform lead (plans/cmux-next/app-platform.md).

## 1. What a module is

A module is one tab. It is either:

- `web`: a URL in the browser engine with its own profile (`presentation.web.url`), or
- `offline`: a bundled page implementing `cmux.pane/1` (`implements["cmux.pane/1"].web`), with no network.

`presentation.tab` must be true. A module declares no code (`runtime.main`), no server, no binaries,
no handles, no requirements, no toolbar items, no catalog, no CLI names, no drag or drop, no custom
CSP. Those fields belong to first-party apps and Verified apps (app-platform.md section 12).

A module is distributed from a git repository: GitHub, GitLab, Codeberg, Bitbucket or any other
public git host, over https or ssh, pinned to a full commit SHA or a tag.

## 2. Assets

1. The user's data in cmux: sessions, the browser profiles, cookies and logins, the clipboard, files
   the user can open, the sidebar layout, notifications.
2. The user's network position: the hosts the module may reach, the user's address to those hosts.
3. The user's git and ssh environment: `~/.gitconfig`, `~/.ssh`, credential helpers, and the
   keychain behind them.
4. The integrity of the approved module: the bytes the user reviewed are the bytes that run.

## 3. Actors

- **Module author**, honest or compromised (stolen token, pushed-to repository, new maintainer).
- **Lookalike publisher**: a repository that copies a real module under another owner or name.
- **Network attacker**: on the path to the git host, or DNS-level.
- **Git host operator** or a host that serves a different repository than the one named.
- **Local attacker** with write access to the user's home directory (installed files, config).
- **Rushed user**, who approves without reading the preview.

## 4. Trust boundaries

```
user-typed source ─▶ parse (refuse) ─▶ git fetch (untrusted network, sandboxed git, no config)
  ─▶ staged blobs (untrusted bytes, digested, limits) ─▶ review (pure, all issues reported)
  ─▶ approval (exact source, commit, digest, manifest) ─▶ install ─▶ check before every run
  ─▶ web page in a per-module profile, or offline page, under the browser's network policy
```

## 5. Threats and mitigations

| # | Threat | Mitigation (code) | Test |
| --- | --- | --- | --- |
| T1 | Source selects a transport that runs code or reads files (`ext::`, `file://`, local paths) | Only `https://`, `ssh://git@…` and `git@host:…` are parsed; everything else is `source.scheme`. `protocol.allow=never` plus one allowed protocol per call | `module_store_rejects_unsafe_transports_and_option_smuggling`, `module_store_fetch_plans_refuse_config_prompts_and_option_injection` |
| T2 | Option injection into git (`-oProxyCommand=…`) | No leading `-` input; `--` before the URL; the commit must be 40 or 64 lower-case hex | same as T1 |
| T3 | Credentials in the URL, or a credential helper prompting | `@` in host refused; `credential.helper=` empty; `GIT_TERMINAL_PROMPT=0`; ssh `BatchMode=yes` | `module_store_rejects_credentials_ports_queries_and_encodings` |
| T4 | Fetch reaches local or private services (SSRF: `localhost`, LAN, `*.local`, IP literals, metadata addresses) | `is_public_host`: at least two labels, no IP literal, no port, no local or test suffix | `module_store_rejects_private_bare_and_ip_hosts` |
| T5 | Lookalike publisher, impersonating a cmux or known publisher | Module `id` publisher must equal the repository owner; first-party publisher names reserved; the consent sheet shows host, owner and repo | `module_store_review_binds_the_publisher_to_the_repository_owner` |
| T6 | Moving tag: the tag is repointed after review | The tag is resolved to a commit at review; the approval records the commit; a different commit is `pin.moved` | `module_store_approval_covers_only_the_reviewed_bytes` |
| T7 | Branch drift: a branch changes under the user | A branch is never a pin. Only a full SHA or a tag resolves; a branch name fails `pin.notFound` | `module_store_pin_is_a_full_commit_or_a_tag`, `module_store_ls_remote_prefers_the_peeled_commit_of_an_annotated_tag` |
| T8 | Ambiguous pin (a short SHA that is also a tag) | Hex names of 7 to 64 characters that are not full lower-case SHAs are refused (`pin.ambiguous`) | `module_store_pin_is_a_full_commit_or_a_tag` |
| T9 | Repository content runs on checkout: hooks, smudge and clean filters, `.gitattributes` drivers, `core.fsmonitor`, submodules | No checkout. Trees are read with `ls-tree -z` and blobs as stored. `core.hooksPath=/dev/null`, `core.fsmonitor=false`, `GIT_CONFIG_GLOBAL=/dev/null`, `GIT_CONFIG_NOSYSTEM=1`. Submodules (`160000`) and symlinks (`120000`) are refused | `module_store_ls_tree_accepts_only_regular_blobs` |
| T10 | Local config rewrites the URL (`url.<x>.insteadOf`, a system or user gitconfig) | `GIT_CONFIG_NOSYSTEM=1` and `GIT_CONFIG_GLOBAL=/dev/null` in the fetch environment | `module_store_fetch_plans_refuse_config_prompts_and_option_injection` |
| T11 | Corrupt or substituted objects | Fetch by full SHA with `fetch.fsckObjects` and `transfer.fsckObjects`. The content digest is recorded and re-checked on every load (T16) | `module_store_digest_*` |
| T12 | Path traversal, absolute paths, a `.git` directory inside the module | Relative ASCII paths only; no `..`, `.`, empty segment, leading `-`, or `.git` component (any case) | `module_store_digest_rejects_unsafe_and_confusable_paths` |
| T13 | Case-only or Unicode confusables on macOS and Windows: `A.js` and `a.js` | ASCII allowlist; case-folded collision refused (`path.caseCollision`) | same as T12 |
| T14 | Symlinks in a staged directory point outside it | `symlink_metadata`; any symlink, FIFO, socket or device is refused | `module_store_digest_from_dir_matches_memory_and_refuses_symlinks` |
| T15 | Huge tree (zip-bomb style, memory exhaustion) | At most 1024 files, 8 MiB per file, 32 MiB total, depth 16, 512-byte paths; `fetch --depth=1` | `module_store_digest_enforces_count_and_size_limits` |
| T16 | Installed files change after approval (local tamper) | `check_installed(recorded_digest, tree)` before every run; mismatch is `digest.tampered` | `module_store_installed_bytes_that_changed_are_refused` |
| T17 | Approval reused for other bytes, another source or another commit | Approval binds source key, resolved commit, tree digest and manifest hash; `covers` checks each in turn | `module_store_approval_covers_only_the_reviewed_bytes` |
| T18 | Code execution from the module | v1 refuses `runtime.main`, `server`, `binaries`, `implements` other than a web `cmux.pane/1`, `native` and `export` | `module_store_review_refuses_code_and_power_fields_a_module_may_not_declare` |
| T19 | Scope escalation: filesystem, actions, terminal, sidebar, projects, MCP, elevated | Allowlist: `storage:local`, `storage:synced`, `embed:run`, `net:<host>` (sensitive, shown). Anything else is `scope.notAllowed`; unknown scopes are refused | `module_store_review_allows_only_the_v1_scope_list` |
| T20 | Wildcard egress (`*.googleusercontent.com`, `net:*.x`) | Wildcard origins refused (`origin.wildcard`) | `module_store_review_rejects_wildcard_and_unsafe_origins` |
| T21 | Network beyond what the user saw | The preview lists every origin: URL origin, declared origins, `net:` hosts. The browser host must enforce that list (section 7) | `module_store_review_accepts_a_web_tab_and_lists_its_origins` |
| T22 | Silent upgrade: a new commit or new bytes apply without the user | `decide_update` returns `UpToDate`, `NeedsApproval(diff)` or `Refused`. There is no applied state. Same commit with different bytes is refused | `module_store_update_never_applies_silently` |
| T23 | Upgrade that quietly adds reach (origins, scopes, files) | `UpdateReview` lists added and removed origins, scopes and files, changed files, and warns on downgrades and sensitive new scopes | `module_store_update_review_lists_what_changed`, `module_store_update_flags_a_downgrade` |
| T24 | Module changes identity or moves to another repository under the same name | Different `id` or source key is `Refused` (`identity.changed`, `source.changed`); reinstall is required | `module_store_update_never_applies_silently` |
| T25 | Manifest that does not match the digested tree | The tree must contain `cmux-app.json` (or `cmux-app.v2.json`); the manifest hash is recorded in the approval. Caller contract in section 7 | `module_store_review_requires_the_manifest_inside_the_tree` |
| T26 | Pin moved between review and fetch | The reviewed commit must equal the pinned SHA; the fetch resolves the tag before review | `module_store_review_pin_must_match_the_resolved_commit` |
| T27 | Module-declared `repository` field lies about the source | The git source is authoritative. The manifest's `repository` is ignored (the store's GitHub-only rule does not apply) | covered by the review tests (fork source with the same manifest) |

## 6. Residual risks (accepted in v1)

- **A trusted repository can publish harmful web content.** A web module is a remote site in a
  profile of its own. Review shows the origins; it cannot judge the content.
- **Owner account compromise** keeps the owner name, so the publisher check still passes. Only a
  signed or verified tier closes this (section 8, question 3).
- **Git sees the user's address** when it fetches. Expected: the store is a git client.
- **The git host can see which module is installed.** Same reason.
- **Denial of service by a slow host.** The supervisor must put a timeout on every git call (7).

## 7. Caller contract (what the supervisor and the UI must do)

These are not enforced by the pure library. They are part of the install path and must be tested
where they are built.

1. Parse the source with `parse_install_spec`, then resolve: for a tag, run `ls_remote_plan`, then
   `parse_ls_remote`; for a commit, the commit is the answer.
2. Fetch with `fetch_plan` (into a fresh staging repository owned by the supervisor, mode 0700,
   with no other writer) and list with `ls_tree_plan` + `parse_ls_tree`.
3. Read each blob (`git cat-file --batch`, bytes as stored) and build a `TreeDigest::from_files`.
   Do not use `from_dir` on a checkout.
4. Parse the manifest from the exact bytes that were digested. Call `review_install`.
5. Show the preview: source key and display URL, owner and repo, pin and resolved commit, digest,
   kind, origins (each one), scopes with class and reason, warnings. Install only after an explicit
   user gesture in the native sheet (the existing `origin user` rule), never from an agent.
6. Store the `Approval` with the install. Before each run, call `check_installed`. Before each
   install or update, call `Approval::covers` on the new preview.
7. Put a wall-clock timeout on every git call, and a size limit on stdout.
8. The browser host enforces the origin list: no navigation, subresource or fetch to an origin not in
   `InstallPreview::origins`. The offline kind runs with a strict content security policy and no
   network.
9. Uninstall deletes the staged tree, the storage, the grants and the approval in one commit.

## 8. Open questions (for Lawrence)

1. **Private hosts.** Today a host such as a LAN or tailnet GitLab is refused. Option: allow a host
   the user adds in Settings, one at a time, with a warning. Default: refused.
2. **Wildcard origins.** Today refused. Option: allow `*.example.com` only when the user approves
   that exact wildcard in the sheet. Default: refused.
3. **Signed commits.** Option: a "Verified" tier that requires a commit signature from a key the
   publisher registered with cmux. Default: no signature check in v1; the commit SHA is the identity.
4. **Monorepos.** A module must be at the repository root in v1. Option: a path inside the repo,
   pinned the same way. Default: root only.
5. **DNS rebinding.** `is_public_host` checks names, not addresses. The supervisor must resolve the
   host and refuse private addresses before it connects. Not built yet.

## 9. Tests and how they are run

`cmux-tui/crates/cmux-app-manifest/tests/module_store.rs`, 30 tests, all named `module_store_*`.
Run with `./scripts/verify-cmux-tui-hosted.sh --filter module_store` (hosted Linux and macOS). Rust
is not built on the Mac (cmux-tui/AGENTS.md).

Not covered yet: the supervisor's git calls against a real host, the browser host's origin
enforcement, the consent sheet, the store UI, and the DNS check in section 8.

## 10. Comparison: OpenCode GUI plugins (2026-10-27)

Source: https://opencode.ai/v2/docs/build/plugins/gui/ (their GUI plugin API, marked experimental).
Their model: a code plugin (`Plugin.define`) with a `setup` part that runs in every window and a `main`
part that runs once in the Electron main process. It contributes commands, panels, slots, menus,
settings pages, styles and link handlers through `ctx.add(Registry, item)`. It is distributed as an
npm package with a `./gui-experimental` export and one prebuilt CommonJS bundle.

Their page documents no permission model and no sandbox. Its only guards are build-time import checks,
the rule that a plugin may provide only tokens whose ids start with its own id, and refusal of reserved ids.

| Topic | OpenCode GUI plugins | This design (module store) | Decision |
| --- | --- | --- | --- |
| Unit | Code that adds UI hooks (commands, panels, slots, menus, settings, styles) | One tab: a web URL, or an offline page. No code | Keep ours. Their hooks need a permission model they do not document |
| Code execution | JS in every window and in Electron main with Node access | None in v1. Any future JS runs in the sandboxed app host (app-platform 13) | Reject. This is the main difference |
| Permissions | Not documented; build-time import checks and id prefixes only | Scope allowlist, every origin listed, consent sheet, elevated scopes never granted at install | Keep ours |
| Identity | Ids prefixed with the plugin id; reserved ids refused | Publisher must equal the repository owner; reserved publishers refused | Already aligned. Adopt the prefix rule for contributions in v2 |
| Distribution and update | npm package; an installed GUI changes only with the package version | Git repository pinned to a SHA or tag; digest over every file; an update needs approval with a diff | Keep ours. A registry version can be republished, our pin cannot |
| Packaging | One prebuilt CJS file; dynamic imports inlined; build fails on disallowed imports | Files in the tree, all digested; no build step at install | Adopt the single-entry rule for any future JS module: one prebuilt entry, no dynamic import, so the reviewed bytes are the bytes that run |
| Status | `Live<T>`: `pending`, `active`, `inactive` with `reason` `disabled` or `failed` | No status vocabulary in v1 | Adopt for the store list (task item 4: the browse and search list): `pending` (fetching or verifying), `active`, `inactive` with reason `disabled` or `failed`. A failed reason names the refusal code (for example `digest.tampered`, `pin.moved`) |
| Enable and disable | Settings > Extensions switch, separate from removal | installed, enabled, hidden states (app-platform V9); uninstall is separate | Keep ours |
| Lifecycle | Registrations end with their owner; `ctx.signal`; cleanup last-in first-out; async cleanup capped at 3 s; reloads on rebuild, option change or update, never on a server restart | Closing the tab ends it; uninstall deletes tree, storage, grants and approval in one commit | Adopt the 3-second cap on teardown in the supervisor. Keep ours for uninstall. An approved update reloads the tab; nothing reloads without approval |
| Platform gating | `os`: `macos`, `windows`, `linux`; omit to run everywhere | `requires.platforms` exists in the schema but is refused for git modules in v1 | Candidate for v2, not adopted now |
| Styles | Arbitrary CSS string while active | Custom CSS and CSP refused | Keep refusal. CSS can leak data through `url()` without any script |
| Embedded views | `WebContentsView`; `dispose()` removes the view but does not close its page | Web tab in its own profile under the origin list | Add to the host checklist: teardown must close the page, not just hide it |
| Contributed commands | Declarative `Command` with `slash`, `bind`, `run` | None in v1 | Candidate for v2: declarative commands that only open the module's tab. Not adopted now |
| Stores and i18n | `Store.global` and `Store.session`; locale fallback to `en` | `storage:local`, `storage:synced`; no module strings | Keep ours. Adopt the `en` fallback for module strings in v2 |
| Main-process IPC | Typed `Ipc` contracts; calls wait while main starts; reject on failure | No main-process code | Not applicable in v1 |

### 10.1 Adopted into this design now

1. Status vocabulary for the store list: `pending`, `active`, `inactive` (reason `disabled` or `failed`). Design only; the code lands with the supervisor.
2. Teardown cap: 3 seconds for any module cleanup, after which the tab is closed.
3. Single-entry packaging rule for any future JavaScript module: one prebuilt file, no dynamic import.
4. Id-prefix rule for future contributions (commands, tokens): an id must start with the module's own id.

### 10.2 Not adopted

- Code in the window or in the browser main process. A module stays a tab with no code.
- Custom CSS or CSP. Refused.
- Registry-mutable versions. An installed module changes only through a pinned, approved update.
- Platform gating and declarative commands: kept as v2 candidates above.

The OpenCode API is experimental. Nothing here depends on it, and we should not pin to it.
