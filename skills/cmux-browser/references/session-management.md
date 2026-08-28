# Session Management

cmux gives each browser surface its own context. Every surface is an independent session with its own cookies, localStorage/sessionStorage, tab list and active tab, and navigation history. Related: [authentication.md](authentication.md), [../SKILL.md](../SKILL.md).

Keep the handle returned by creation or
[surface discovery](surface-discovery.md); never use a guessed default.

## Parallel sessions

Each `cmux browser open` returns a new surface ref; drive them independently.

```bash
FIRST_JSON="$(cmux --json browser open https://site-a.example --focus false)"
FIRST_SURFACE="$(printf '%s' "$FIRST_JSON" | jq -r '.surface_ref // .surface_id // empty')"
SECOND_JSON="$(cmux --json browser open https://site-b.example --focus false)"
SECOND_SURFACE="$(printf '%s' "$SECOND_JSON" | jq -r '.surface_ref // .surface_id // empty')"
[ -n "$FIRST_SURFACE" ] && [ -n "$SECOND_SURFACE" ] || exit 1

cmux browser --surface "$FIRST_SURFACE" get text body > /tmp/a.txt
cmux browser --surface "$SECOND_SURFACE" get text body > /tmp/b.txt
```

## Reusing auth across surfaces

```bash
SOURCE_SURFACE="surface:7"       # from discovery
cmux browser --surface "$SOURCE_SURFACE" state save /tmp/auth.json
DESTINATION_JSON="$(cmux --json browser open https://app.example.com --focus false)"
DESTINATION_SURFACE="$(printf '%s' "$DESTINATION_JSON" | jq -r '.surface_ref // .surface_id // empty')"
[ -n "$DESTINATION_SURFACE" ] || exit 1
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
