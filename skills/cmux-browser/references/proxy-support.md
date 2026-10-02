# Proxy Support

cmux browser uses WKWebView networking, so proxy behavior follows macOS/system networking and the app process environment. Related: [commands.md](commands.md), [../SKILL.md](../SKILL.md).

There is no `cmux browser proxy ...` command for per-surface routing: WKWebView has no CDP-style per-context proxy controls. Configure a system or network-level proxy for the environment cmux runs in, or route traffic through an upstream gateway you control.

Verify egress:

```bash
cmux browser open https://httpbin.org/ip --json
cmux browser surface:7 get text body
```
