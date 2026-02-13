# Proxy Support

How proxy behavior works for cmuxterm browser automation.

**Related**: [commands.md](commands.md), [SKILL.md](../SKILL.md)

## Contents

- [Current Behavior](#current-behavior)
- [What Is Not Exposed via CLI](#what-is-not-exposed-via-cli)
- [Workarounds](#workarounds)
- [Verification](#verification)

## Current Behavior

cmuxterm browser uses WKWebView networking. Proxy behavior follows macOS/system networking and app process environment.

## What Is Not Exposed via CLI

There is currently no first-class `cmuxterm browser proxy ...` command for per-surface proxy routing.

Why: WKWebView does not provide CDP-style per-context proxy controls equivalent to Chrome automation stacks.

## Workarounds

1. Configure system/network-level proxy for the environment where cmuxterm runs.
2. Route traffic through an upstream gateway you control.
3. Validate behavior with explicit IP checks.

## Verification

```bash
cmuxterm browser open https://httpbin.org/ip --json
cmuxterm browser surface:7 get text body
```

Compare returned IP against expected proxy egress.
