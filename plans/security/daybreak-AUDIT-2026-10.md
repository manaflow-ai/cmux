# Daybreak security audit, October 2026 (round 3)

Scope: code added or changed on `feat-cmux-next` (and related cmuxterm-hq / subrouter code) from
2026-10-06 to 2026-10-20. Auditors: 10 Codex workers on `gpt-daybreak-blue-latest` (subrouter,
account lawrence@manaflow.ai), one per area. Rounds 1-2 (Oct 18-19, 12 areas) are in
`~/fun/cmux-worktrees/security-audit/REPORT.md`; this round reports only new findings.
Full per-area reports: `~/fun/cmux-worktrees/security-audit/r3/<area>.md`.

Status at 2026-10-20 14:30 PDT: 6 of 10 areas done; chief-tools, chromium, cloud-chief and
acpmux-new are still fixing. Counts so far: **0 critical, 18 high, 18 medium, 6 low** (round 3) plus **6 high, 7 medium, 1 low** from the first nightly run (below).

## High findings (most severe first)

| ID | What is wrong | Status |
|----|---------------|--------|
| ci-gates-1 | TestFlight job ran branch-controlled scripts with App Store Connect key and distribution cert. | fixed: f35c2945e95 (test), 28d802e42a6 (fix). Rollout: fast-forward `rc/cnx-ios-builder`. |
| ci-gates-2 | `pull_request_target` minted a write token and pushed a ref at a PR merge commit, so PR code ran in privileged CI. | fixed: d7c0d4df093 (test), ef7c434a3d2 (fix). Rollout: apply ef7c434a3d2 to `main` (pull_request_target runs from main). |
| ci-gates-3 | PR `path_route` job ran PR scripts with `actions:write` + `contents:write`. | fixed: 92c4efa19b3 (test), e93faa5f1fb (fix). |
| ci-gates-4 | Pre-push gate executed checker scripts from the pushed branch on the contributor's Mac. | fixed: da263c93f5c (test), 539e0c5923b (fix). Rollout: rerun `scripts/install-git-hooks.sh`. |
| cloud-chief-1 | Cloud Chief host, model turns and spawned agents share one Unix user with the Mac-gate bearer and hub root key. | fix on worker branch (169eb90b7dd/f96c9fcddd6, ed0380b8695/311df1112b1), landing in progress; hq part on `sec/cloud-chief-1`. |
| cloud-chief-2 | `server.addServer` open to CLI/MCP: a local process can pair its own server and move the user's Chief. | fix on worker branch (dc83a7425e7/f3693d26155), red proven on fleet, landing in progress. |
| chief-tools-1 | Side/group conversations get the private DM context; auto-approved tools and unapproved replies leak it to non-owners. | fix in progress. |
| chief-tools-2 | A Markdown image/link in a reply makes the host upload any local file (symlinks followed) outside approvals. | fix in progress (red test 4e0f5852bda local). |
| chief-tools-4 | A non-owner message downloads all attachments (16 x 100 MB) before any approval. | fix in progress. |
| acpmux-new-1 | New `_acpmux/process/list/tail/kill` trusts any same-user socket client; no person proof or session binding. | fix in progress. |
| acpmux-new-2 | `process/tail` reads an output path taken from tool-result text, following symlinks, in the unsandboxed daemon. | fix in progress. |
| acpmux-new-3 | Device-wide chat route checks only `Origin::Local`; any same-user process reads all chats. | fix in progress. |
| chromium-1 | Downloaded Chromium runtime is checked only at install; later launches trust user-writable `installed.json`. | fix on scratch (24054e46c8c test, 39141b891c7 fix), fleet runs queued. |
| home-files-1 | `browser.page.screenshot` and screenshot actions return app pixels to CLI/MCP callers. | fixed: 3e030521599 (test), 45fe246e9ab (fix). |
| mobile-1 | Action Button voice notes used one unscoped outbox; after sign-out notes go to the next account. | fixed: 0fd41aba81b (test), a6aa0c01af0 (fix). |
| freestyle-1 | Org-workflow `automationExec` did not check that the creator is still a team member. | fixed: 353056437db (test), cd3693b170c (fix). |
| freestyle-5 | Own-sign-in stores Claude/Codex/OpenCode credentials in the shared `cmux` HOME of team VMs. | partly fixed: 8bd30951d31..26db4bda19b (team auth default, isolated launchers). Rollout: bake image, revoke creds on old disks; real per-user isolation needs a design decision. |
| teammate-access-1 | On a322's unlanded `teammate-access-scratch`: a legacy full-access `allow` entry survives `revoke`. | lead for a322 (not edited). |

## First nightly run (2026-10-20 04:23, range a7ebd89a0a7..e9c6f20a63b)

Lanes app and rust finished; cloud, mobile and ci hung on the model stream (fixed by the lane
timeout, they run again tonight). Fix workers (round 4) are queued, max 5 workers at a time.

| ID | What is wrong | Status |
|----|---------------|--------|
| cmux-app-1 | CLI/MCP screenshot actions capture any window/pane/tab, including off-screen signed-in tabs. | likely closed by 45fe246e9ab (person-only); worker n-screens verifies. |
| cmux-app-2 | App and phone screenshot actions write to caller-chosen paths and replace existing files. | worker n-screens. |
| cmux-app-3 | App launches `cnx-hostd` and VS Code `code-server` from user-writable paths without a code-identity check, and gives them credentials. | worker n-helpers (relates to update-3). |
| cmux-app-4 | Opening Markdown runs `git status`/`diff` with repo config enabled; an untrusted repo's `core.fsmonitor` runs code. | worker n-git. |
| cmux-rust-1 | acpmux `start_session` accepts any absolute cwd outside the parent's trusted root. | worker n-subsessions. |
| cmux-rust-2 | Cross-harness child of a restricted parent keeps the target's broader default mode. | worker n-subsessions. |

Mediums: cmux-app-5..8 (design mode, CEF events, task-manager kill policy, iPhone host), cmux-rust-3..5; low cmux-rust-6. Details: `~/fun/cmux-worktrees/security-audit/nightly/2026-10-20/`.

## Medium and low (summary)

- attribution-1 (med): `/_subrouter/prompts` and transcripts have no Host/Origin check; DNS rebinding via a reader's browser. Rollout in subrouter repos.
- attribution-2 (med): prompts stored without secret redaction. attribution-3 (low): retention runs only on writes.
- chief-tools-3 (med): right-column browser lease. chromium-2 (med): MDM policy is "Slice 2". chromium-3 (med): intranet DNS probe. chromium-4 (med): chief_inspect write impact over socket-auth-2.
- cloud-chief-3 (med): hub posting token can grow the database without bound (retention decision).
- freestyle-2 (med): cross-Chief pause lifecycle; freestyle-6 (med): cloud-move credential egress; freestyle-3/4 (low): mesh pre-auth limiter, stale tailnet nodes.
- home-files-2/3 (med): Files batch/undo and pasteboard races; home-files-4 (low): release-notes nested decode.
- mobile-3 (med): Android phone backend; mobile-2 (low): voice outbox legacy files.
- teammate-access-2 (med, fixed a968ba2f37d + 0eca91e213e): direct serve bypassed root refusal; -3, -6 (med) open; -4, -5 (med), -7 (low) leads for a322.

## Recurring audit

`scripts/security/daybreak-nightly/` (16e2a1d8062, b913aa31e2e, 9f4c14a92d3, c44e585a765,
c7548e94d08): LaunchAgent `ai.manaflow.cmux-daybreak-nightly`, daily 04:23, installed by
`install.sh`. It audits only commits since the last audited sha, read-only, in lanes (cmux app,
rust, cloud, mobile, ci; cmuxterm-hq), max 4 workers, 90 min per lane, and raises a cmux
notification for critical or high findings. Reports: `~/fun/cmux-worktrees/security-audit/nightly/<date>/`.
Test: `bash scripts/security/daybreak-nightly/test_nightly.sh`.
