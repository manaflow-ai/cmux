# Native workflow follow-ups (2026-11-16)

PR lane `issue-35755-daemon-workflow` fixes the four folded review follow-ups in #35755.

- The workflow host resolves one current tool-profile snapshot for the tool ceiling and folded upstream names, avoiding duplicate profile and secret-store work per check request.
- A start refusal is durably completed as a deterministic journal error and replays as the same immediate refusal; uncertain transport failures remain pending.
- Journal handoff waits on the kernel's exact `resume.lock` ownership condition, so a runner in a long upstream call is not failed by an arbitrary 60-second cap.
- Active runner generations carry one cancellation token; pause, replacement, and runner exit cancel it so an in-flight activity wait releases immediately. The token map is bounded by active generations.

Validation will use the focused acpmux workflow tests through `cmux-ci` after the PR head is published.
