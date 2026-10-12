# Session Management

Drive several browser tabs at once by keeping each tab's `tab_…` id. Related:
[authentication.md](authentication.md), [../SKILL.md](../SKILL.md).

The per-tab CLI cannot save or copy browser state. The browser REPL can:
`session.storageState({ path })` and `session.setStorageState(stateOrPath)`
save and restore cookies and localStorage, and `tabs.open(url, { incognito:
true })` opens a tab with none ([repl-guide.md](repl-guide.md)).

## Parallel tabs

```bash
tab_id() { jq -r '.. | .id? // empty | select(startswith("tab_"))' | head -n1; }
FIRST="$(cmux --json tab create browser --url https://site-a.example | tab_id)"
SECOND="$(cmux --json tab create browser --url https://site-b.example | tab_id)"
[ -n "$FIRST" ] && [ -n "$SECOND" ] || exit 1
cmux browser "$FIRST" text body
cmux browser "$SECOND" text body
```

## Cleanup

```bash
cmux tab "$FIRST" close
cmux tab "$SECOND" close
```

Keep one task per tab to avoid ref churn, and log tab ids rather than URLs or
page text from authenticated pages.
