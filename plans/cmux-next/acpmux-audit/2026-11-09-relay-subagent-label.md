# Notice to PL-acpmux: a subagent's relayed send names the subagent as a label (2026-11-09)

W5-M (b), PR 1 of 2 (owner W5-S; lead decision: limit plus label, then a signed reply address).
`cli/send_relay.rs`: `relay_with_deadline`, `send_with_deadline` and `audit_sent` take a
`RelaySender` (the `ACPMUX_FROM` name and the Claude Code subagent). A subagent's relayed send
sets `ACPMUX_FROM_SUBAGENT` (`TYPE:ID`) and `ACPMUX_FROM_LABEL` (`LEAD's TYPE subagent ID`); the
lead's own send removes both, so an inherited value never names another sender. The CLI takes the
subagent from the Bash hook's mark (`subagent_of_this_process`), the MCP `send` tool from the
call's tool use id (`subagent_call.rs`). The cross-host audit line adds `fromSubagent`.
`ACPMUX_FROM` is unchanged (the lead's name): relays use it as the reply address
(`tests/cross_host_send_cli.rs` passes it on as `--from`), so a label there would break replies.
The limit (the far side's answer reaches the lead) is in SKILL.md and README.md. A Codex
subagent's relayed send is not labeled (its thread is compared by the daemon, after the relay
choice). PR 2 adds a reply address that this daemon can verify.
