# Finishing a task

Moved here from the root CLAUDE.md on 2026-11-19 (docs audit); the root keeps a one-line pointer.

A change to the Mac or iOS app is not done until the person can open it. Every agent report for
such a change ends with the dev build link, the fleet simulator evidence and the iPhone install result.
Use one task tag, `<task-slug>` (for example `sidebar-star-align-v1`), for the Mac and iOS builds.
A documentation-only change needs no build; give the file path instead.
A change to the cmux-next API (`backend/apps/api`, `backend/db`) is tried on its own per-tag stack,
`scripts/cmux-next/cloud-dev-stack.sh up --tag <task-slug> --journey`, and stopped with `down` when done
([cmux-backend](../../cmux-backend/SKILL.md#run-your-unmerged-cmux-next-api-a-per-tag-stack-on-the-dev-vm)).
The report also names, for the person to run, the command that puts the change into their running cmux now, from
[the loop](../../../CLAUDE.md#the-loop-use-it-first-then-test) (`cmux app try <PR>`, `cmux customize use pr:N`), so they
use it before the build is done. The agent itself runs it there only when asked; otherwise it uses a side copy (`hot-verify.py look`).

- **Mac:** build the pushed exact head on the fleet and publish it to HQ, never on the person's Mac:

  ```bash
  JOB_ID=$(cmux-ci build cmux --ref "$(git rev-parse HEAD)" --tag <task-slug> \
      --workspace <PR URL, else the branch name> --production \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')
  cmux-ci wait "$JOB_ID"
  cmux-ci publish-hq "$JOB_ID"
  ```

  `--workspace` is required (queued builds with the same workspace and tag supersede each other).
  `--production` because the build is for a person: it launches on the production Cloud, where their own
  cmux.com account signs in (Leo: "why is the stuff so weird to log in to dev builds?"), and it needs no hq
  checkout. An agent's own test build takes `--backend-mode local` instead (the default `auto` provisions
  hq's shared backend and stops with "Shared backend helper missing" outside an hq checkout).
  When you run `cmux-next-ios/scripts/review.sh` below, skip this step: it builds and publishes the
  same-tag Mac app itself, and a second Mac build replaces the first.
  Report the Tag Opener link `http://127.0.0.1:17320/<task-slug>`. Never `open` it (macOS sends it
  to the default browser); team members add it to their workspace with hq's `scripts/open-dev-build.sh <task-slug>`.
- **iOS:** the iPhone app is `cmux-next-ios/`. Run `cmux-next-ios/scripts/review.sh --tag <task-slug>`.
  In one command it builds the same-tag Mac app and the iPhone app on the fleet, publishes the Mac
  app to HQ, and leaves the build on every connected iPhone signed in and paired with that Mac
  (`--manual-pairing` to pair by hand, `--approve-first` to test the Mac's Allow prompt, `--no-auth`
  for a signed-out install; a tagged dev Mac otherwise pairs its own tag's iPhone app with no prompt). It proves both
  survive a relaunch, and checks the build in a fleet simulator signed in with the agent account,
  whose session comes from this Mac (`cmux-ci run --sign-in agent`; no credential lives on a
  worker). Never install with raw `devicectl`, and nothing boots in a simulator on the person's
  Mac. Rerunning the same command resumes the saved fleet jobs. Its phone leg passed end to end on
  2026-11-18 (real iPhone, tag `phone-e2e-1118`, #46718, all three modes); report a failure as the
  phone's blocker. Details:
  [cmux-next-ios/CLAUDE.md](../../../cmux-next-ios/CLAUDE.md).
  The Tag Opener link opens the Mac app and, on every connected phone, the same-tag iPhone app it
  has installed (hq `tools/cmux-hq/Sources/CmuxHQ/TagOpener.swift`, `iosLauncher.launch`).
- **Install on every connected phone.** A phone that is connected gets the build, including one
  you have not seen before: `review.sh` registers a new phone and installs on it too.
- **A phone is always connected.** No connected phone, a locked phone, a queued install or a
  failed auth gate is a blocker to report with its error and retry command, never a step to skip
  or replace with a simulator-only result.
- End the report with:

  ```text
  Dev build:  http://127.0.0.1:17320/<task-slug>   (fleet job <JOB_ID>, head <sha>)
  Simulator:  fleet simulator, signed in: <evidence dir> (screenshot.png and the recording)
  iPhone:     <name> (<model>, <udid>): installed, signed in, paired and linked with <Mac>
              <name> (<model>, <udid>): BLOCKED: <reason>; retry: <command>   (one line per connected phone)
  ```
