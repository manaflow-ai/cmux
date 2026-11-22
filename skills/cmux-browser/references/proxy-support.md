# Proxy Support

cmux has no browser proxy command, old or new. Browser traffic follows macOS
system networking and the app's environment. Configure a system or network
proxy, or route traffic through a gateway you control. Related:
[commands.md](commands.md), [../SKILL.md](../SKILL.md).

Check egress by opening an echo page and reading its text:

```bash
TAB="$(cmux --json tab create browser --url https://httpbin.org/ip | jq -r '.. | .id? // empty | select(startswith("tab_"))' | head -n1)"
cmux browser "$TAB" text body
```
