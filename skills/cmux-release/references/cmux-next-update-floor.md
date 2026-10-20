# cmux-next update floor

cmux-next deploys to macOS 14.0, the same floor as the legacy app (it was 26.0 before 2026-10-13). Sparkle only offers an appcast item to a Mac whose macOS is at least the item's `sparkle:minimumSystemVersion`, so the floor must reach every new item or older Macs download a build that cannot launch. The pipeline below enforces that whatever the floor is.

## How the floor gets into the feed

1. `Resources/Info.plist` sets `LSMinimumSystemVersion` to `$(MACOSX_DEPLOYMENT_TARGET)`: 14.0 in the `cmux-next` target since 2026-10-13 (26.0 before), 14.0 in the legacy target.
2. `scripts/ci/appcast_minimum_system_version.py floor <app>` reads that value from the built bundle and fails when it is missing or lower than the main executable's `LC_BUILD_VERSION minos`.
3. `scripts/sparkle_generate_appcast.sh` requires `SPARKLE_MINIMUM_SYSTEM_VERSION` (the value from step 2). After `generate_appcast` it runs `enforce`: the item for the new DMG must carry that `sparkle:minimumSystemVersion`. A missing element is inserted and a different value fails the release.
4. `nightly.yml`, `release.yml` and `scripts/build-sign-upload.sh` pass the floor from the app they built. `release.yml` also greps the final `appcast.xml` for it.

`tests/test_appcast_minimum_system_version.py` and `tests/test_sparkle_generate_appcast_no_deltas.sh` cover these steps (`ci-guards.yml`, group `release-notary`). The app side is `CmuxNextUpdater.AppcastSelector`; it has no test target yet.

## If the floor rises above macOS 14 again

The two sections below applied while cmux-next required macOS 26. They are kept for the next floor raise.

### What older Macs get

Sparkle picks the newest item the Mac can run. It never offers an item above the Mac's macOS, and it reports "requires a newer macOS" when the newest item is too new.

Nightly: the feed lists the new build plus the two previous builds (kept for deltas). For the first two cmux-next nightlies, macOS 14/15 users are offered the newest legacy nightly still in the feed. After that the feed has only cmux-next items, so those Macs stay on the build they have.

Stable: the feed lists only the new release. Without further action, a macOS 14/15 Mac stays on whichever legacy release it has, which may be older than the last legacy release.

### Keep older Macs on the last legacy build (stable)

After the final legacy stable release, and before the first cmux-next stable release:

1. Copy that release's `<item>` from `https://github.com/manaflow-ai/cmux/releases/download/<final-legacy-tag>/appcast.xml` into `scripts/cmux-next/legacy-appcast-item.xml`. Its `sparkle:minimumSystemVersion` must be 14.0 and its enclosure must point at that tag's `cmux-macos.dmg`.
2. Commit the file through a normal PR.

When that file exists, `release.yml` and `build-sign-upload.sh` pass it as `SPARKLE_LEGACY_APPCAST_ITEM_FILE`, and `append-legacy` adds it to every stable feed. Deltas are removed from it. It is rejected when its floor is not below the new floor. macOS 26 Macs still get the newest cmux-next build. macOS 14/15 Macs move to the final legacy build and stop there.

The file is not committed yet because the final legacy release does not exist. Security fixes for macOS 14/15 after that point would need a separate legacy branch and feed. That is a product decision, not something the pipeline does.

## Homebrew

`update-homebrew.yml` and `scripts/build-sign-upload.sh` write `depends_on macos: :sonoma` into the cask (macOS 14). The symbol form means "this macOS or newer"; Homebrew deprecated the `">= :sonoma"` comparison string (issue 5877), and `tests/test_ci_homebrew_cask_macos_dependency.sh` derives the symbol from the app target's deployment target.
