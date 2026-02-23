# cmux iOS App

## Build Configs
| Config | Bundle ID | App Name | Signing |
|--------|-----------|----------|---------|
| Debug | `dev.cmux.app.dev` | cmux DEV | Automatic |
| Beta | `dev.cmux.app.beta` | cmux Beta | Manual |
| Release | `dev.cmux.app` | cmux | Manual |

## Development
```bash
./scripts/reload.sh   # Build & install to simulator + iPhone (if connected)
./scripts/device.sh   # Build & install to connected iPhone only
```

Always run `./scripts/reload.sh` after making code changes to reload the app.

## Public Config Sync (Convex + Stack)
```bash
./scripts/sync-public-convex-vars.sh --source-root ~/fun/cmux
```

This script copies only public keys from `~/fun/cmux/.env.local` and
`~/fun/cmux/.env.production` into `Sources/Config/LocalConfig.plist`:
- `CONVEX_URL`
- `NEXT_PUBLIC_CONVEX_URL`
- `NEXT_PUBLIC_STACK_PROJECT_ID`
- `NEXT_PUBLIC_STACK_PUBLISHABLE_CLIENT_KEY`
- `NEXT_PUBLIC_WWW_ORIGIN`

`Sources/Config/LocalConfig.plist` is gitignored and must not be committed.

## Convex Type Sync
```bash
./scripts/sync-convex-types.sh --source-root ~/fun/cmux
```

This generates `Sources/Generated/ConvexApiTypes.swift` from the Convex schema
in `~/fun/cmux/packages/convex`.

## TestFlight
```bash
./scripts/testflight.sh  # Auto-increments build number, archives, uploads
```

Build numbers in `project.yml` (`CURRENT_PROJECT_VERSION`). Limit: 100 per version.

## Notes
- **arm64 only**: ConvexMobile doesn't support x86_64
- **Dev shortcut**: Enter `42` as email to auto-login (DEBUG only, needs test user in Stack Auth)
- **Encryption**: `ITSAppUsesNonExemptEncryption: false` set in project.yml
