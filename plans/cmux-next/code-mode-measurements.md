# Code mode discovery measurements

Preliminary static estimate collected 2026-10-02 on the same catalog revision as PR #16891 (`feat-cmux-next` at `cda1f6586fe`). Counts use `tiktoken` `cl100k_base` and count the exact UTF-8 text supplied to the model. This is not the live harness benchmark yet.

## Baseline and progressive disclosure

| Surface | Tokens |
| --- | ---: |
| Existing `skills/cmux-cua/SKILL.md` | 4,121 |
| Synthetic Codex CUA roster JSON with the ten names and minimal object schemas | 222 |
| Skill plus that synthetic roster | 4,343 |
| `skills/cmux-code-mode/SKILL.md` | 248 |
| Code mode skill plus `cmux docs search "pane split"` result (stdout newline included) | 372 |
| Code mode skill plus `cmux docs search "terminal run"` result (stdout newline included) | 344 |

The 222-token roster is an author-supplied synthetic estimate, serialized compactly as `{"tools":[{"name":"...","description":"cmux Computer Use test tool","inputSchema":{"type":"object"}}]}`. It is not a checked-in live helper payload. The live current MCP list must be captured from `tools/list` per harness before a final comparison. The user supplied Playwright baseline is 21 tools and about 13.7k tokens; this is the expected high-cost case that progressive disclosure avoids.

The slice-B MCP server's live `tools/list` response was captured on 2026-10-02 from `cmux-tui/bindings/typescript/code-mode/mcp.mjs` (the same file bundled as `Resources/bin/cmux-code-mode-mcp`): the JSON-RPC result is 700 bytes and 164 cl100k tokens, with exactly two tools (`cmux_docs` and `cmux_exec`). The bundled current CUA helper was not built in this checkout, so its live response remains unverified; the repository smoke test reports `SKIP: cmux-cua binary not built`.

The raw responses are checked in as [`code-mode-tools-list.jsonl`](code-mode-tools-list.jsonl), [`code-mode-docs-pane-split.jsonl`](code-mode-docs-pane-split.jsonl), and [`code-mode-docs-terminal-run.jsonl`](code-mode-docs-terminal-run.jsonl). Each file contains one newline-delimited JSON-RPC response from the source MCP entry point.

## Task coverage

`cmux docs search` in slice A reads the 127-operation cmux-tui resource catalog. It covers panes, terminals, browser operations present in that catalog, sessions, workspaces and agent state. Cloud VM operations and the Swift app's broader browser command surface are documented by the existing Swift `cmux docs` and skills but are not yet merged into this catalog. The execute slice must consume a merged catalog before claiming coverage for cloud and CUA operations.

## Reproduction

```sh
python3 - <<'PY'
import json
from pathlib import Path
import tiktoken
enc = tiktoken.get_encoding("cl100k_base")
print(len(enc.encode(Path("skills/cmux-cua/SKILL.md").read_text())))
print(len(enc.encode(Path("skills/cmux-code-mode/SKILL.md").read_text())))
PY
```

For each harness, save the raw `tools/list` JSON and count it with the same tokenizer. Save the exact docs query and stdout, including its trailing newline, next to it. Do not compare a skill with a tool list from a different harness or catalog revision. The current PR contains the live two-tool payload above, but no live Claude/Codex harness payload or wall-time task run, so those comparisons remain pending.

## Execute-slice measurement plan

For each harness and each task, record the current MCP setup and the two-tool code-mode setup:

1. open the PR diff in a split and run tests;
2. screenshot a browser tab and summarize it;
3. pause idle cloud machines;
4. create a pane, run a command and read its result.

Record prompt tokens, tool/schema tokens, output tokens, number of turns, wall time, success, and recovery attempts. The script and catalog revision are part of every result. Cloud and CUA tasks remain `unavailable` until their operations are included in the merged catalog and the same `cmux_exec` permission gate is wired to them.
