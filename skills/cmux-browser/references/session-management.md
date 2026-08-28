# Session Management

cmux gives each browser surface its own context. Every surface is an independent session with its own cookies, localStorage/sessionStorage, tab list and active tab, and navigation history. Related: [authentication.md](authentication.md), [../SKILL.md](../SKILL.md).

Keep the handle returned by creation or
[surface discovery](surface-discovery.md); never use a guessed default.

## Parallel sessions

Each `cmux browser open` returns a new surface ref; drive them independently.

```bash
cmux --json browser open https://site-a.example --focus false    # -> surface:11
cmux --json browser open https://site-b.example --focus false    # -> surface:12

cmux browser --surface surface:11 get text body > /tmp/a.txt
cmux browser --surface surface:12 get text body > /tmp/b.txt
```

## Reusing auth across surfaces

```bash
SOURCE_SURFACE="surface:7"       # from discovery
DESTINATION_SURFACE="surface:8"   # from the second open response
cmux browser --surface "$SOURCE_SURFACE" state save /tmp/auth.json
cmux --json browser open https://app.example.com --focus false    # -> surface:8
cmux browser --surface "$DESTINATION_SURFACE" state load /tmp/auth.json
cmux browser --surface "$DESTINATION_SURFACE" goto https://app.example.com/dashboard
```

## Cleanup

```bash
cmux close-surface --surface surface:7
rm -f /tmp/auth.json
```

## Best practices

Log only the surface refs needed to keep actions attributable (not raw URLs or
auth payloads), keep one task per surface to avoid ref churn, save state after
successful auth milestones, and re-snapshot after switching tabs or pages
inside a surface.
