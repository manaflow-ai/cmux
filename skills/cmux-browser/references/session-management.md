# Session Management

cmux gives each browser surface its own context. Every surface is an independent session with its own cookies, localStorage/sessionStorage, tab list and active tab, and navigation history. Related: [authentication.md](authentication.md), [../SKILL.md](../SKILL.md).

## Parallel sessions

Each `cmux browser open` returns a new surface ref; drive them independently.

```bash
cmux browser open https://site-a.example --json    # -> surface:11
cmux browser open https://site-b.example --json    # -> surface:12

cmux browser surface:11 get text body > /tmp/a.txt
cmux browser surface:12 get text body > /tmp/b.txt
```

## Reusing auth across surfaces

```bash
cmux browser surface:7 state save /tmp/auth.json    # after logging in on surface:7
cmux browser open https://app.example.com --json    # -> surface:8
cmux browser surface:8 state load /tmp/auth.json
cmux browser surface:8 goto https://app.example.com/dashboard
```

## Cleanup

```bash
cmux close-surface --surface surface:7
rm -f /tmp/auth.json
```

## Best practices

Log surface refs in script output so actions stay attributable, keep one task per surface to avoid ref churn, save state after successful auth milestones, and re-snapshot after switching tabs or pages inside a surface.
