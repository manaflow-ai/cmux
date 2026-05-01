# cmux iOS App

## Build Configs
| Config | Bundle ID | App Name | Signing |
|--------|-----------|----------|---------|
| Debug | `dev.cmux.app.dev` | cmux DEV | Automatic |
| Nightly | `com.cmuxterm.app.nightly` | cmux NIGHTLY | Automatic |
| Release | `com.cmuxterm.app` | cmux | Manual |

## Development
```bash
./scripts/reload.sh   # Build & install to simulator + iPhone/iPad devices
./scripts/device.sh   # Build & install to connected iPhone/iPad devices only
```

Always run `./scripts/reload.sh` after making code changes to reload the app.

### Cross-stack reload checklist

iOS clients connect to mac-side `cmuxd-remote` over WebSocket. Many
"reload the app" turns touch code that affects **both** sides. Always
reload **every** surface the change can land in:

| Code area touched | Mac tagged reload | iOS reload | Daemon rebuild |
|-------------------|-------------------|------------|----------------|
| `daemon/remote/zig/**` | yes (mac respawns daemon on launch) | yes (iOS connects to it) | implicit via mac reload script |
| `ios/Sources/**` | no | **yes** | no |
| `Sources/**` (mac swift) | yes | no | no |
| Shared protocol / RPC schema changes | yes | yes | yes |
| `MobileDaemonBridgeInline` / WS port logic | yes | yes (iOS may cache stale port) | no |

The default for ambiguous turns is "reload both". Faster than rediscovering a
stale-state bug after the user reports it.

iOS reload from this dir:

```bash
cd ios && ./scripts/reload.sh
```

Always state explicitly in chat handoff which surfaces were reloaded:
"Reloaded mac (tag: <slug>) and iOS simulator. iPhone unavailable." —
never let the user guess.

## Living Spec
- `docs/terminal-sidebar-living-spec.md` tracks the sidebar terminal migration plan.
- Keep this document updated as implementation status changes.

## TestFlight
```bash
./scripts/testflight.sh  # Auto-increments build number, archives, uploads
```

Build numbers in `project.yml` (`CURRENT_PROJECT_VERSION`). Limit: 100 per version.

## Notes
- **Dev shortcut**: Enter `42` as email to auto-login (DEBUG only, needs test user in Stack Auth)
- **Encryption**: `ITSAppUsesNonExemptEncryption: false` set in project.yml
