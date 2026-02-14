# Session Management

cmux uses isolated browser contexts per surface. Treat each browser surface as its own session.

**Related**: [authentication.md](authentication.md), [SKILL.md](../SKILL.md)

## Contents

- [Surface-Based Sessions](#surface-based-sessions)
- [Isolation Properties](#isolation-properties)
- [State Persistence](#state-persistence)
- [Common Patterns](#common-patterns)
- [Cleanup](#cleanup)
- [Best Practices](#best-practices)

## Surface-Based Sessions

```bash
# session A
cmux browser open https://app.example.com/login --json
# -> surface:7

# session B
cmux browser open https://example.com --json
# -> surface:8

cmux browser surface:7 get url
cmux browser surface:8 get url
```

## Isolation Properties

Each surface has independent:
- cookies
- localStorage/sessionStorage
- tab list and active tab
- navigation history

## State Persistence

### Save State

```bash
cmux browser surface:7 state save /tmp/auth-state.json
```

### Load State

```bash
cmux browser surface:8 state load /tmp/auth-state.json
cmux browser surface:8 goto https://app.example.com/dashboard
```

## Common Patterns

### Reuse Auth Across New Surface

```bash
cmux browser open https://app.example.com/login --json
# login on surface:7 ...
cmux browser surface:7 state save /tmp/auth.json

cmux browser open https://app.example.com --json
# assume surface:8
cmux browser surface:8 state load /tmp/auth.json
cmux browser surface:8 goto https://app.example.com/dashboard
```

### Parallel Multi-Site Tasks

```bash
cmux browser open https://site-a.example --json
cmux browser open https://site-b.example --json
cmux browser open https://site-c.example --json

cmux browser surface:11 get text body > /tmp/a.txt
cmux browser surface:12 get text body > /tmp/b.txt
cmux browser surface:13 get text body > /tmp/c.txt
```

## Cleanup

```bash
cmux close-surface --surface surface:7
cmux close-surface --surface surface:8
rm -f /tmp/auth-state.json
```

## Best Practices

1. Name/log surfaces in your script output so actions stay attributable.
2. Keep one task per surface to avoid ref churn.
3. Save state after successful auth milestones.
4. Re-snapshot after switching tabs/pages inside a surface.
