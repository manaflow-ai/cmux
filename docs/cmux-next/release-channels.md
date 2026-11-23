# cmux-next release channels: Stable and RC

cmux-next ships on Classic's two public channels under Classic's own identities, so each
Classic install takes cmux-next as an ordinary Sparkle update on the channel it already uses.
Nothing here publishes anything: every switch below is off until a person turns it on.

Companion pages: [the go-live runbook](../../plans/cmux-next/classic-handoff-go-live-RUNBOOK.md)
(dry runs, kill switch, rollback, blockers), [the migration design](../../plans/cmux-next/classic-migration-DESIGN.md)
(what comes over at first launch), [the handoff test](classic-handoff-test.md) (try an RC on your own Mac),
[cmux NEXT Stable](../ci/stable-next.md) (the team's internal nightly-derived channel, a different thing).

## The channels

| | Stable | RC |
| --- | --- | --- |
| App | `cmux.app` | `cmux RC.app` |
| Bundle id | `com.cmuxterm.app` (Classic Stable's) | `com.cmuxterm.app.rc` (Classic RC's) |
| Icon | `AppIcon` (the regular cmux icon) | `AppIcon-RC` |
| URL scheme (sign-in) | `cmux` | `cmux-rc` |
| Entitlements, profile | `cmux.release.entitlements`, `APPLE_RELEASE_PROVISIONING_PROFILE_BASE64` | `cmux.rc.entitlements`, `APPLE_RC_PROVISIONING_PROFILE_BASE64` |
| App ID, keychain group | `7WLXT3NR37.com.cmuxterm.app` | `7WLXT3NR37.com.cmuxterm.app.rc` |
| Workflow | `release.yml`, on a `v*` tag | `nightly.yml`, on a push to `rc/**` |
| Feed | `github.com/manaflow-ai/cmux/releases/latest/download/appcast-<arch>.xml` and `files.cmux.com/stable/appcast*.xml` | `files.cmux.com/rc/appcast*.xml` |
| Sparkle key | Classic's stable key (`SPARKLE_PRIVATE_KEY`, public `avjcg…`) | the same shared key (`nightly-sparkle-key.sh`: RC always uses it) |
| `sparkle:channel` | none (Classic allows none) | none |
| Version | `MARKETING_VERSION` (1.0.0) | `<marketing>-rc.<build>` |
| Build number | `CURRENT_PROJECT_VERSION`, now **117** (Classic Stable is 113; the handoff RCs used 114–116) | the run-based number nightly.yml writes (Classic RC is at 3849553622001), larger every run |
| Architectures offered | Apple silicon: the item carries `<sparkle:hardwareRequirements>arm64</sparkle:hardwareRequirements>` | the same, on every RC item (this change) |
| Phased rollout | `vars.CMUX_STABLE_PHASED_ROLLOUT_INTERVAL` seconds per group (this change); unset: everyone at once | none (RC users opted in to early builds) |
| Publish switch | pushing the tag | `vars.CMUX_NEXT_RC_PUBLISH=1` (this change); unset: the run builds and signs, and publishes nothing |
| Signing, notarization | Developer ID `7WLXT3NR37`, notarized and stapled (`release` environment) | the same (`release` environment) |

Because the bundle id, team and App ID are Classic's, the update keeps what macOS ties to them:

- **Keychain**: items in the `7WLXT3NR37.com.cmuxterm.app` (or `.rc`) group and items keyed by
  the code-signing designated requirement stay readable: no prompt, no lost sign-in.
- **TCC grants** (Accessibility, Screen Recording, Full Disk Access, Automation): kept, since the
  designated requirement (bundle id plus team) is unchanged. Still to confirm on a real install
  (runbook "Go live", step 3 of the staging check).
- **UserDefaults**: the same domain. cmux-next reads Classic's keys it imports (shortcuts, link
  routing, socket mode) and writes its own; Classic's `session-<bundle>.json` and `cmux.json` are
  never written, so a downgrade opens Classic where it was.
- **Passkeys**: Stable keeps `com.apple.developer.web-browser.public-key-credential`; RC never had
  it (the RC App ID's capability request is still pending at Apple, `plans/cmux-next/passkeys.md` K14).

What does not come over: browser sign-ins (Classic's WebKit store), about 170 Settings-window
preferences, Classic's packet-tunnel extension (runbook B3, B4, B5).

## The Classic → cmux-next update path

1. **Feed hand-off.** No feed changes address. Stable: pushing `v1.0.0` makes that release
   `latest`, so `releases/latest/download/appcast-<arch>.xml` (what every Classic Stable install
   reads) serves the cmux-next item; then `files.cmux.com/stable/` is written. RC: a published
   `rc/**` run writes `files.cmux.com/rc/appcast*.xml`.
2. **Who is offered it.** Apple silicon Macs on macOS 14 or later. Intel installs skip the item
   (`hardwareRequirements arm64`, Sparkle 2.9+; Classic ships 2.9.5) and stay on Classic.
3. **First launch.** cmux-next imports Classic's windows, workspaces, groups, colors and pins once
   (the migration ledger under `Application Support/cmux-next/<bundle id>/classic-migration/`),
   asks first, and never duplicates on later launches or after a downgrade and re-upgrade.
4. **Undo.** Kill switch and rollback are in the runbook: point `latest` back at Classic's release
   and its appcast, or ship Classic again with a higher build number.

## Turning a channel on (each needs a person's go)

```bash
# RC: let rc/** runs of this tree publish to every Classic RC install, then cut the branch.
gh variable set CMUX_NEXT_RC_PUBLISH -R manaflow-ai/cmux --body 1
git push origin <feat-cmux-next sha>:refs/heads/rc/v1.0.0
# Off again (the next rc/** run publishes nothing):
gh variable delete CMUX_NEXT_RC_PUBLISH -R manaflow-ai/cmux

# Stable: optional phased rollout (one of 7 groups a day), then the tag.
gh variable set CMUX_STABLE_PHASED_ROLLOUT_INTERVAL -R manaflow-ai/cmux --body 86400
git tag v1.0.0 <feat-cmux-next sha> && git push origin v1.0.0
```

An `rc/**` push without the variable is still useful: it builds, signs and notarizes `cmux RC.app`
from cmux-next and uploads it as a run artifact, the RC equivalent of a dry run.

## Decisions only a person makes

- **When to switch.** The moment `v1.0.0` is tagged, every Apple silicon Classic Stable install
  starts updating; `CMUX_NEXT_RC_PUBLISH=1` plus an `rc/**` push does the same for RC.
- **RC first, or Stable directly.** Default here: RC first, for at least one release cycle.
- **Rollout speed.** `CMUX_STABLE_PHASED_ROLLOUT_INTERVAL` (86400 recommended) or all at once.
- **Intel.** Intel Classic users stay on Classic until Intel CEF and cmux-tui ship (runbook B6, B6b).
- **The build-number commit.** `cmux.xcodeproj/project.pbxproj` sits under the coordinator's
  freeze (runbook "Go live" step 1); this PR carries the 108 → 117 bump as its own commit so it can
  land in a granted slot or be dropped.
- **The open runbook blockers** (B3 tunnel extension, B4 settings, B5 browser sign-ins, B7 CLI verbs).

## Tests

```bash
python3 tests/test_ci_nightly_push_throttle.py   # RC publish switch, RC identity
python3 tests/test_appcast_require_arm64.py      # Stable and RC items are Apple silicon only
python3 tests/test_appcast_phased_rollout.py     # phased rollout on this release's item only
CMUX_SPARKLE_MONOTONIC_MODE=enforce bash tests/test_ci_sparkle_build_monotonic.sh  # 117 > Classic's 113
```
