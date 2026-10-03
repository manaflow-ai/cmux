# apps swift3 resume note (updated 2026-10-02 21:20)
1. State: feat-cmux-next-apps-swift3-wip = feat-cmux-next (264128b17cd) + 8 apps commits, VERIFIED on cmux-lawrence-2 (build, AppsTests 49, AppPermissions, AppsWire, AppPresence, Sidebar*, check-action-surfaces; godfiles/concurrency/crash/l10n/theme earlier same tree).
2. Landing blocked: 16872 and 17008 are OPEN and the cmux-tui pin does not ship cmux-app-host yet; land only after all three (coordinator).
3. Next: when they land, rebase, sync-app-runtime.sh (v2 samples), rerun the same gates, drop this note commit, push to feat-cmux-next (safe-push.sh not found in hq or cmux; ask coordinator for its path).
4. Then rebase feat-cmux-next-apps-store-pane (f5548642b3f) and send heads to the app platform lead; pane wiring waits for lane 20.
5. Open runs: none.
