# cmux iOS App

## Licensing
- Files under `ios/**` are proprietary and governed by `ios/LICENSE`.
- Repository-wide license scope is documented in `../LICENSE_SCOPE.md`.

## Sync from `~/fun/cmux`
From the `ios/` directory:

```bash
./scripts/sync-public-convex-vars.sh --source-root ~/fun/cmux
./scripts/sync-convex-types.sh --source-root ~/fun/cmux
```

- `sync-public-convex-vars.sh` copies only whitelisted public env keys into
  `Sources/Config/LocalConfig.plist` (gitignored).
- `sync-convex-types.sh` regenerates
  `Sources/Generated/ConvexApiTypes.swift` using Convex schema from
  `~/fun/cmux/packages/convex`.
