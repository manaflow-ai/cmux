# Find the right CMUX skill

Choose by the task: operating the installed app and changing its implementation
use different instructions. Load the matching `SKILL.md`, then only the reference
needed for the current operation. Installed CLI `--help` owns available commands
and flags; repository instructions own build and test rules.

## Working on the repository

Run repository commands only from a [trusted checkout](../docs/contributor-verification.md#trust-boundary);
even `verify-local.py --help` and `--list` load repository code.

For a local iteration, start with `python3 scripts/verify-local.py --help`.
`--swift-changed` discovers current Swift edits; `--list` exposes focused checks.
See [cmux-testing](cmux-testing/SKILL.md) for the boundary between static checks,
parsing, test compilation, executed tests and runtime evidence.

| Task | Skill |
| --- | --- |
| Setup, tagged builds, project normalization | [cmux-dev-workflow](cmux-dev-workflow/SKILL.md) |
| Tests, verification scope, target wiring | [cmux-testing](cmux-testing/SKILL.md) |
| Package boundaries, Swift APIs and concurrency | [cmux-architecture](cmux-architecture/SKILL.md) |
| Backend APIs, providers, database and migrations | [cmux-backend](cmux-backend/SKILL.md) |
| Billing implementation, Stripe and entitlements | [cmux-billing](cmux-billing/SKILL.md) |
| Instrumentation and app/runtime implementation bugs | [cmux-debugging](cmux-debugging/SKILL.md) |
| User-facing strings and localization | [cmux-localization](cmux-localization/SKILL.md) |
| CLI/socket implementation, threading and focus | [cmux-socket-policy](cmux-socket-policy/SKILL.md) |
| Shared actions across multiple entry points | [cmux-shared-behavior](cmux-shared-behavior/SKILL.md) |
| Ghostty submodule or GhosttyKit | [cmux-ghostty](cmux-ghostty/SKILL.md) |
| Versions, changelog and release artifacts | [cmux-release](cmux-release/SKILL.md) |
| Adversarial review of agent-written changes | [cmux-review](cmux-review/SKILL.md) |

## Using the installed app

| Task | Skill |
| --- | --- |
| Inspect or change windows, workspaces, panes and surfaces | [cmux](cmux/SKILL.md) |
| Work in the caller's existing workspace without disrupting it | [cmux-workspace](cmux-workspace/SKILL.md) |
| Browser automation | [cmux-browser](cmux-browser/SKILL.md) |
| Operate Cloud machines and their persistent workspaces | [cmux-cloud-vm](cmux-cloud-vm/SKILL.md) |
| Native computer use when requested | [cmux-cua](cmux-cua/SKILL.md) |
| Settings values and validation | [cmux-settings](cmux-settings/SKILL.md) |
| Shortcuts, key bindings and templates | [cmux-keyboard-shortcuts](cmux-keyboard-shortcuts/SKILL.md) |
| Actions, commands and layouts | [cmux-customization](cmux-customization/SKILL.md) |
| Build a custom sidebar | [cmux-custom-sidebar](cmux-custom-sidebar/SKILL.md) |
| Diagnose installed hooks, settings, restore or socket access | [cmux-diagnostics](cmux-diagnostics/SKILL.md) |
| Display a Markdown file in a viewer | [cmux-markdown](cmux-markdown/SKILL.md) |

Start with diagnostics for a user's broken installation; use debugging when
investigating or changing the source implementation. Similarly, Cloud VM operations
belong to `cmux-cloud-vm`, while its service implementation belongs to `cmux-backend`.
