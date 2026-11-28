# Proxy Support

cmux browser uses WKWebView networking, so proxy behavior follows macOS/system networking and the app process environment. Related: [commands.md](commands.md), [../SKILL.md](../SKILL.md).

There is no `cmux browser proxy ...` command for per-surface routing: WKWebView has no CDP-style per-context proxy controls. Configure a system or network-level proxy for the environment cmux runs in, or route traffic through an upstream gateway you control.

Verify egress:

```bash
OPEN_JSON="$(cmux --json browser open https://httpbin.org/ip --focus false)"
SURFACE="$(printf '%s' "$OPEN_JSON" | jq -r '.surface_ref // .surface_id // empty')"
[ -n "$SURFACE" ] || { printf '%s\n' 'browser open did not return a surface ref' >&2; exit 1; }
cmux browser --surface "$SURFACE" get text body
```
