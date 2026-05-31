# Panecho code-signing & notarization

Panecho is distributed as a **Developer ID-signed, notarized, stapled** macOS
app. This document explains how that happens **without any credential ever
living in this public repository.**

## Why signing matters

CI builds Panecho **ad-hoc signed** (`CODE_SIGNING_ALLOWED=NO`). An ad-hoc app
has no stable code-signing identity, so:

- Gatekeeper warns / blocks it on other Macs.
- macOS **cannot persist privacy (TCC) consent** — e.g. the *"Panecho.app would
  like to access data from other apps"* prompt re-appears on **every launch**,
  because the grant can't be bound to a stable Team ID.

Developer ID signing + notarization fixes both: the signature carries a stable
identity (`Team YQ5FZQ855D`), Apple notarizes the binary, and the stapled ticket
lets Gatekeeper trust it offline.

Verified before/after (`codesign -d -r-`):

- ad-hoc: `designated => cdhash H"…"` (changes every build → TCC can't persist)
- Developer ID: `designated => identifier "io.panecho.app" and anchor apple
  generic and … leaf[subject.OU] = YQ5FZQ855D` (stable → consent persists)

## Hard rule: no credentials in this repo

This repo is **public**. Never commit or store in its Actions secrets any
`*.p12`, `*.p8`, certificate password, or App Store Connect key. `.gitignore`
blocks the file types; secret-scanning + push-protection are the backstop. All
signing happens in the **private repo** `xxshubhamxx/panecho-signing` (or a
self-hosted runner) that holds the credentials. Signed files come back as a
workflow **artifact** — so no cross-repo write token is needed either.

## What lives where

| Item | Location |
|---|---|
| `panecho.release.entitlements`, `scripts/sign-panecho-bundle.sh`, `scripts/notarize-and-staple-panecho.sh` | **This public repo** (no secrets) |
| Developer ID Application `.p12` + password | **Private repo secret** / Keychain only |
| Notarization credential: Apple ID + app-specific password (BrowserStack `AC_PASSWORD`) **or** an App Store Connect API key | **Private repo secret** only |

## Credential setup (in the PRIVATE repo)

The certificate-derived secrets (`APPLE_CERTIFICATE_BASE64`,
`APPLE_CERTIFICATE_PASSWORD`, `APPLE_SIGNING_IDENTITY`, `APPLE_TEAM_ID`) come
from BrowserStack's MacGap2 `build_assets` + known constants.

The **notarization credential** is the only Apple-account-bound secret. Two
options — the signer/notarize scripts accept either:

1. **Apple ID + app-specific password** (reuses BrowserStack's existing
   `AC_PASSWORD` from MacGap2; no App Store Connect access needed):

   ```bash
   printf '%s' 'appleadp@bsstag.com' | gh secret set NOTARY_APPLE_ID -R xxshubhamxx/panecho-signing
   printf '%s' 'xxxx-xxxx-xxxx-xxxx' | gh secret set NOTARY_PASSWORD -R xxshubhamxx/panecho-signing
   printf '%s' 'YQ5FZQ855D'          | gh secret set NOTARY_TEAM_ID  -R xxshubhamxx/panecho-signing
   ```

2. **App Store Connect API key** (`.p8` + Key ID + Issuer ID) — set
   `ASC_API_KEY_P8_BASE64`, `ASC_API_KEY_ID`, `ASC_API_ISSUER_ID` instead.
   The scripts prefer the API key if present, else fall back to (1).

## Local signing (alternative to the private repo)

On a trusted Mac with the cert in your Keychain and a notarytool keychain
profile, after a Panecho release is published:

```bash
gh release download <tag> -R xxshubhamxx/cmux-panecho -p '*macos.zip'
ditto -x -k *macos.zip .                     # -> Panecho.app
./scripts/sign-panecho-bundle.sh Panecho.app panecho.release.entitlements \
  "Developer ID Application: Browserstack Inc (YQ5FZQ855D)"
NOTARY_APPLE_ID=appleadp@bsstag.com NOTARY_PASSWORD='xxxx-xxxx-xxxx-xxxx' NOTARY_TEAM_ID=YQ5FZQ855D \
  ./scripts/notarize-and-staple-panecho.sh Panecho.app \
  "Developer ID Application: Browserstack Inc (YQ5FZQ855D)"
gh release upload <tag> Panecho.dmg panecho-macos.zip -R xxshubhamxx/cmux-panecho --clobber
```

## Private signing repo workflow

Lives at `xxshubhamxx/panecho-signing` → `.github/workflows/sign-release.yml`.
Trigger it manually with the Panecho release tag; it downloads the unsigned
artifact (public, default token), Developer ID signs it with
`sign-panecho-bundle.sh`, notarizes via the App Store Connect API key, staples,
and uploads the signed `Panecho.dmg` + `panecho-macos.zip` as a workflow
artifact named `panecho-signed-<tag>`.

After the run, attach the signed files to the public release (your local `gh` is
already authed — no PAT required):

```bash
gh run download -R xxshubhamxx/panecho-signing -n panecho-signed-<tag> -D /tmp/signed
gh release upload <tag> /tmp/signed/Panecho.dmg /tmp/signed/panecho-macos.zip \
  -R xxshubhamxx/cmux-panecho --clobber
```

## Verification

```bash
codesign -dvvv /Applications/Panecho.app 2>&1 | grep -E 'Authority|TeamIdentifier|Signature'
#   Authority=Developer ID Application: Browserstack Inc (YQ5FZQ855D)
#   TeamIdentifier=YQ5FZQ855D   Signature=...   (NOT adhoc)
codesign --verify --deep --strict --verbose=2 /Applications/Panecho.app
spctl -a -vvv -t exec /Applications/Panecho.app     # -> accepted, source=Notarized Developer ID
xcrun stapler validate /Applications/Panecho.app    # -> validated
```

Then: launch, Allow the TCC prompt once, quit, relaunch — it should **not**
re-prompt (consent now persists against the stable Team ID).

## Caveat: dropped web-browser entitlement (verified)

`panecho.release.entitlements` deliberately OMITS
`com.apple.developer.web-browser.public-key-credential`. That entitlement is a
RESTRICTED capability requiring a managed provisioning profile. Under a
Developer ID signature with no profile, including it makes the app **fail to
launch** — verified: `RBSRequestErrorDomain Code=5 / Launchd job spawn failed`
(errno 153, an amfi spawn rejection). Removing it lets the Developer-ID-signed
app launch and run normally.

Because the upstream `scripts/sign-cmux-bundle.sh` hard-requires that
entitlement post-sign, Panecho uses `scripts/sign-panecho-bundle.sh` instead —
same inside-out signing order, but it forbids the profile-bound entitlements
(`web-browser.public-key-credential`, `application-identifier`,
`team-identifier`) rather than requiring them.

Consequence: in-app-browser passkeys (WebAuthn) are unavailable. To restore
them, register `io.panecho.app` for that capability under team `YQ5FZQ855D`,
embed a managed provisioning profile, and add the entitlement back.
