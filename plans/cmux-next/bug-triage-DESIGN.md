# Bug report triage agent

Status: built (skill `skills/cmux-bug-triage`, a141; dedup upgrades in this change).

## Goal

A tester sends bug reports (screenshots, videos, short text). One agent picks the ones worth
fixing, drops the ones already fixed or in progress, and gives a short fix list that the Chief
can hand to agents without more editing.

## How reports come in

1. **Home chat (main path).** The tester sends the report to Lawrence; Lawrence forwards it to
   the Chief in Home (text plus images, or a video). The Chief runs the `cmux-bug-triage` skill.
2. **CLI.** `skills/cmux-bug-triage/scripts/cmux-bug-triage add --text - --image shot.png --from NAME`.
3. **Folder.** Drop `report.md` and images in a new subfolder of `~/fun/cmux-bug-inbox`.

Videos: the agent takes 3-6 frames (`ffmpeg -i clip.mov -vf fps=1 frame-%02d.png`, on a
fleet Mac when the clip is long), reads them like screenshots and writes what it sees under
`## Images` in `report.md`. The script never opens media.

## Flow

1. **Split** each report into one bug per bullet (or paragraph). A short "macOS 15, build X" line
   is the environment for every bug.
2. **Dedup** against, in order: open subagents (`aN: task` lines from the Chief's view),
   Sentry issues, `~/fun/cmux-prompt-commits.md`, and the last 600 commits on
   `origin/feat-cmux-next` (subject plus first body paragraph; fix commits quote the tester, so
   "crashes after cmd 123" finds its fix). A fix commit wins over its failing-test commit.
3. **Fixed-where.** For a landed match, the script checks if the sha is in `nightly-next`.
   "Not in nightly-next yet" means: tell the tester to retest after the next nightly, do not spawn.
4. **Score.** severity x 3 + reach - effort. Severity 3 crash/hang/data loss/closes the wrong
   thing, 2 broken feature, 1 polish. Reach +1 for global paths (shortcuts, sidebar, launch).
   Effort 1-3.
5. **Decide.** `skip` (duplicate, fixed, or too vague), `fix now` (severity 3 or score >= 6),
   `batch` (rest; one agent per 3+ queued).
6. **GitHub.** Open issues (`gh issue list --json number,title,url`) are linked into the fix
   task so the fix closes them. A match never skips a bug: an open issue is not a fix.
7. **Output.** `triage.md` (one line per bug: decision, title, reason) and `triage.json` with a
   ready task per fix-now bug: 2-5 word title line, sidebar group, tester text, screenshots,
   macOS repro note, standing rules (failing-first test, fleet only, plain push feat-cmux-next,
   no PR).

## First batch (Oct 20, managed company Mac, macOS 15)

| Bug | Decision | Fixed by | In nightly-next (6327df61790)? |
|---|---|---|---|
| Crash after Cmd+1/2/3 | skip, fixed | ae0b2d6710a | no |
| Settings: Cmd+D then Cmd+W fails 2-3 times, then closes all | skip, fixed | e4d566e7e30 | no |
| Composer 3rd dropdown (permission mode) broken under managed permissions | skip, fixed | 36ff1835704 | no |
| Settings wallpaper caption overflows | skip, fixed | c55f563792c | no |

All four were fixed on Oct 19 by the `sequoia-tester-bugs` agent (failing tests 777f13836fd and
5c28aa71be8). Nothing to spawn. Next step: publish a nightly, then ask the tester to retest.

## Not in scope

- A direct tester inbox (email, iMessage, web form). Lawrence forwards for now.
- Automatic Sentry fetch (needs a logged-in `sentry-cli`).
