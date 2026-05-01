# cmux iOS App

## Licensing
- Files under `ios/**` are proprietary and governed by `ios/LICENSE`.
- Repository-wide license scope is documented in `../LICENSE_SCOPE.md`.

## Local development

```bash
./scripts/reload.sh
./scripts/device.sh
./scripts/testflight.sh
```

- `reload.sh` builds and installs the dev app to booted simulators and connected iPhone/iPad devices when available.
- `device.sh` installs to connected iPhone/iPad devices only.
- `testflight.sh` archives and uploads Nightly/Release builds.

Public environment overrides live in `Sources/Config/LocalConfig.plist`, which is gitignored. Use `Sources/Config/LocalConfig.example.plist` as the template.

## Mobile workspace architecture
- GRDB is the mandatory local read model for the workspace and inbox surface. The app boots from cache first, then reconciles live data.
- Workspace state comes from the desktop daemon over WebSocket. `WorkspaceLiveSyncing` remains a seam for future backend-backed workspace rows, but the default implementation is no-op.
- iOS side effects that need app backend state go through authenticated HTTP route clients.
- PostHog is analytics only. It is not an operational database and should never receive terminal content, TLS pins, or ticket secrets.

## Living Spec
- Sidebar terminal roadmap and implementation status:
  `docs/terminal-sidebar-living-spec.md`.
