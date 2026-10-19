# Lane B provider-aware restore status

Updated: 2026-10-18

## Findings

- Direct and Subrouter Codex/Claude restore planning is provider-aware. Provider identity and route identity remain separate: Codex uses structured `model_provider=subrouter` evidence plus the wrapper-attested marker; Claude uses the agreeing Subrouter marker pair (with the bounded legacy proxy-directory fallback).
- Legacy shell evidence is parsed as a single canonical command. Shell operators, expansions, malformed quoting, spoofed command text, and non-Codex executables fail closed.
- Codex provider declarations now fail closed when metadata is ambiguous. Routing is accepted only when every observed `model_provider` declaration agrees on `subrouter`; a conflicting declaration is passed through instead of being upgraded to a routed restore.
- Proven Claude restores rebuild the `sr claude proxy --resume` invocation and preserve a validated account pin when present. Proven Codex restores rebuild the Subrouter resume invocation and restore the required dummy credential without replaying private routing configuration.

## Verification

All commands were run from `/Volumes/Atelier/Code/cmux-rootcause-20261019`.

```text
~/.local/bin/pulp-worktree-lineage-session --plain
swift test --package-path Packages/macOS/CMUXAgentLaunch --filter 'AgentResumeArgvTests|SubrouterClaudeResumeRoutingTests|AgentSessionRecoveryTests|AgentExternalLauncherTests'
swift test --package-path Packages/macOS/CMUXAgentLaunch
python3 scripts/verify-local.py --only swift-syntax --swift-changed
```

Results:

- Focused package run: PASS, 83 tests in 6 suites.
- Full package run: PASS, 845 tests in 99 suites.
- Swift syntax check: PASS, 5 selected files.

No cmux process was launched, and the protected PID/socket namespace was not touched. No merge or push was performed.

## Next action

Lane A should run the copied-session restore matrix against the isolated fixture, covering direct Codex, Subrouter Codex, direct Claude, Subrouter Claude, ambiguous metadata, spoofed shell text, and missing provider binaries. Keep the restore fail-closed if any identity/count or provider provenance check is unavailable.
