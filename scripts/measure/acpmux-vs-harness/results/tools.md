### Tool servers: raw vs acpmux (gcp-agent-lane-10.us-west1-c.c.manaflow-437420.internal, cpus 4-7, load 9.6, n calls 100)

| metric | claude-raw | codex-raw | acpmux+claude | acpmux+codex |
|---|---|---|---|---|
| shell call, first in chat (ms p50, n=chats) | 54.72 (n=7) | 89.95 (n=7) | 59.26 (n=7) | 34.78 (n=7) |
| shell call, later (ms p50 / p95) | 63.46 / 78.33 | 77.54 / 129.5 | 62.81 / 74.79 | 22.56 / 36.28 |
| shell kind | fresh process per call | fresh process per call | fresh process per call | fresh process per call |
| new procs per `/bin/true` call (sampled, lower bound) | 1.8 | 7.0 | 1.95 | 6.95 |
| pid-counter delta per call (VM-wide, idle-rate subtracted; noisy) | -4.0 | 10.8 | 6.1 | 12.4 |
| background procs started per s with no call (control) | 0 | 0 | 0 | 0 |
| procs seen | bash, claude, true | bash, bwrap, codex, codex-linux-san, exe, tokio-rt-worker | bash, claude, true | bash, cat, exe, locale, locale-check, tr |
| procs left after turn (+1 s) | 0 | 0 | 0 | 0 |
| file read call (ms p50 / p95) | 68.99 / 78.88 | 71.0 / 74.04 | 69.7 / 88.0 | 22.58 / 104.43 |
| file edit call (ms p50 / p95) | 69.86 / 97.72 | 69.25 / 75.29 | 66.81 / 117.47 | 14.52 / 36.3 |
| 10 parallel `sleep 0.3` in one reply (ms p50) | 395.21 | 644.36 | 373.63 | 395.5 |
| tree RSS after 20th call (MB) | 258.5 | 155.8 | 309.9 | 263.0 |
| tree RSS growth after 100 calls (MB) | 28.7 | 9.6 | 53.9 | 8.3 |
| acpmux daemon RSS, shared (MB) | - | - | 107.5 | 114.2 |
| tree procs (20th call -> 100th) | 1 -> 1 | 1 -> 1 | 2 -> 2 | 4 -> 4 |
| errors | none | none | none | none |

Ancestry of one shell call (leaf first):

claude-raw:
```
2685897:/bin/bash -c source /tmp/atb-9ofhf6r3/claude-config/shell-snapshots/sn
2685836:claude -p --model claude-opus-5-5 --input-format stream-json --output-
```

codex-raw:
```
2:/bin/bash -c p=$$; while [ "$p" -gt 1 ]; do printf "%s:%s\n" "$p" "$(t
```

acpmux+claude:
```
2698337:/bin/bash -c source /tmp/atb-9ofhf6r3/claude-config/shell-snapshots/sn
2698227:/home/cmux/.local/bin/claude --append-system-prompt Before each tool s
2698218:/home/cmux/.local/bin/acpmux __agent-host 
2681117:/home/cmux/.local/bin/acpmux daemon run 
```

acpmux+codex:
```
2705136:/bin/bash -lc p=$$; while [ "$p" -gt 1 ]; do printf "%s:%s\n" "$p" "$(
2704217:/usr/local/lib/node_modules/@openai/codex/node_modules/@openai/codex-l
2704075:node /usr/local/bin/codex -m gpt-5.5 -c agents.max_concurrent_threads_
2704071:/home/cmux/.local/bin/acpmux __agent-host 
2681117:/home/cmux/.local/bin/acpmux daemon run 
```

Processes under the tree while `sleep 1.5` ran (not there before):

claude-raw: bash | /bin/bash -c source /tmp/atb-9ofhf6r3/claude-config/shell-snapshots/snapshot-bash-1795567321513-fd2gf4.sh 2>/dev/null || true && \builtin shopt -u extglob 2>/de; sleep | sleep 1.5

codex-raw: codex-linux-san | /tmp/atb-9ofhf6r3/codex-home/tmp/arg0-linux/codex-arg0tF2yDV/codex-linux-sandbox --sandbox-policy-cwd /tmp/atb-9ofhf6r3/codex-raw/work --command-cwd /tmp/atb-9o; bwrap | bwrap --as-pid-1 --new-session --die-with-parent --ro-bind / / --dev /dev --perms 000 --tmpfs /tmp/codex-daemon-1005 --remount-ro /tmp/codex-daemon-1005 --bind ; codex | codex-linux-sandbox --sandbox-policy-cwd /tmp/atb-9ofhf6r3/codex-raw/work --command-cwd /tmp/atb-9ofhf6r3/codex-raw/work --permission-profile {"type":"managed",; sleep | sleep 1.5

acpmux+claude: bash | /bin/bash -c source /tmp/atb-9ofhf6r3/claude-config/shell-snapshots/snapshot-bash-1795567370963-71ive4.sh 2>/dev/null || true && \builtin shopt -u extglob 2>/de; sleep | sleep 1.5

acpmux+codex: sleep | sleep 1.5

Noise: VM load 6-17 during runs (other helpers); same-core pinning 4-7. One earlier run at load 17 gave acpmux+claude parallel10 568 ms and acpmux+codex tree RSS 627 MB (pool warm session counted in the daemon tree); the run above (load 9.6) is the table. Treat differences under ~15 ms as noise. Tree RSS = the session's host + harness + children (daemon RSS shown apart).

## acpmux gaps (found by this bench)
1. Codex runs with NO sandbox through acpmux (no bwrap/codex-linux-sandbox; `exe --codex-run-as-process-setup` only), raw Codex under workspace-write runs 3x bwrap + a `bwrap --help` probe per call. acpmux+codex is 3x faster per call (22 vs 78 ms) but that is the missing sandbox, not a win: approve-all starts at the harness's full-access level by design. `cmux-tui/crates/acpmux/src/hub/start_mode.rs`, `hub/policy_mode.rs`.
2. acpmux+codex shell calls run `bash -lc` (login shell): each call sources /etc/profile (locale-check, locale, cat, tr: ~7 procs per `/bin/true`, vs 1.8 for Claude). A non-login shell would cut ~4 procs per call. Codex honours `allow_login_shell`; the bridge args are in `cmux-tui/crates/acpmux/src/agent/` (harness argv, see `tests/codex_bridge_config.rs` for the pinned `-c` list).
3. acpmux+claude: Read dedupe hook answers a repeat Read of an unchanged file with an is_error PreToolUse "hook error: [dedupe]" result (10 of 20 in the first run when one file was re-read). Intended saving, but it surfaces as a tool error to the model and in ACP clients; `cmux-tui/crates/acpmux/src/claude_stdio/dedupe.rs`.
4. acpmux+claude first-call and 10-parallel latency were +40 ms / +190 ms over raw in the load-17 run (PreToolUse callbacks cmux-repo-sync, acpmux-policy-gate, dedupe run per call over the control channel) and equal to raw at load 9.6: the hook round trip is load sensitive. `cmux-tui/crates/acpmux/src/claude_stdio/inbound.rs`, `policy_gate.rs`.
5. Tree RSS: acpmux+claude 310 MB vs raw 259 MB (+51: `cmux mcp serve` and agent-host) and +108-114 MB for the shared daemon; RSS growth over 100 calls is not above raw (54 vs 29 MB claude, 8 vs 10 MB codex; node GC noise, no leak signal). `cmux-tui/crates/acpmux/src/agent_host/`, `agent_tools.rs`.
6. No gap: shell is a fresh process per call on all four (no persistent shell); nothing left after the turn on any side.
