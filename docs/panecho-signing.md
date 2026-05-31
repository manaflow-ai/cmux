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

## Hard rule: no credentials in this repo

This repo is **public**. Never commit or store in its Actions secrets any of:
`*.p12`, `*.p8`, `*.cer`, `*.pem`, certificate passwords, App Store Connect keys,
or `CROSS_REPO_TOKEN`. `.gitignore` blocks the file types; secret-scanning +
push-protection are enabled as a backstop. All signing happens in a **private
repo / self-hosted runner** that holds the credentials.

## What lives where

| Item | Location |
|---|---|
| `panecho.release.entitlements`, `scripts/sign-cmux-bundle.sh`, `scripts/notarize-and-staple-panecho.sh` | **This public repo** (no secrets) |
| Developer ID Application `.p12` + password | **Private repo secret** / Keychain only |
| App Store Connect API key `.p8` + Key ID + Issuer ID | **Private repo secret** only |
| `CROSS_REPO_TOKEN` (write to this repo's releases) | **Private repo secret** only |

## One-time credential setup (run locally, outside any repo)

```bash
# 1. Signing cert: export the Developer ID Application cert from BrowserStack's
#    MacGap2 build_assets (Developer ID Application: Browserstack Inc YQ5FZQ855D).
#    Base64 it for the private-repo secret. Do NOT commit the .p12 anywhere.
base64 -i AppleDevIDApp.p12 | pbcopy   # -> paste into APPLE_CERTIFICATE_BASE64

# 2. Notary key: generate a NEW App Store Connect API key with notarization
#    access (App Store Connect -> Users and Access -> Integrations). MacGap2
#    only has Apple-ID-password auth; the API-key route needs a fresh .p8.
base64 -i AuthKey_XXXXXX.p8 | pbcopy    # -> ASC_API_KEY_P8_BASE64

# 3. Set the secrets on the PRIVATE signing repo (NOT this public fork):
gh secret set APPLE_CERTIFICATE_BASE64   -R <org>/panecho-signing < cert.b64
gh secret set APPLE_CERTIFICATE_PASSWORD -R <org>/panecho-signing   # MacGap2 .p12 password
gh secret set APPLE_SIGNING_IDENTITY     -R <org>/panecho-signing   # Developer ID Application: Browserstack Inc (YQ5FZQ855D)
gh secret set APPLE_TEAM_ID              -R <org>/panecho-signing   # YQ5FZQ855D
gh secret set ASC_API_KEY_P8_BASE64      -R <org>/panecho-signing < key.b64
gh secret set ASC_API_KEY_ID             -R <org>/panecho-signing
gh secret set ASC_API_ISSUER_ID          -R <org>/panecho-signing
gh secret set CROSS_REPO_TOKEN           -R <org>/panecho-signing   # fine-grained PAT, contents:write on xxshubhamxx/cmux-panecho only
```

## Local signing (alternative to the private repo)

On a trusted Mac with the cert in your login Keychain and a notarytool keychain
profile, after a Panecho release is published:

```bash
gh release download <tag> -R xxshubhamxx/cmux-panecho -p '*macos.zip'
ditto -x -k *macos.zip .                     # -> Panecho.app
./scripts/sign-cmux-bundle.sh Panecho.app panecho.release.entitlements \
  "Developer ID Application: Browserstack Inc (YQ5FZQ855D)"
ASC_API_KEY_PATH=~/keys/AuthKey.p8 ASC_API_KEY_ID=XXXX ASC_API_ISSUER_ID=YYYY \
  ./scripts/notarize-and-staple-panecho.sh Panecho.app \
  "Developer ID Application: Browserstack Inc (YQ5FZQ855D)"
gh release upload <tag> Panecho.dmg panecho-macos.zip -R xxshubhamxx/cmux-panecho --clobber
```

## Private signing repo workflow

Drop this into the **private** repo (e.g. `<org>/panecho-signing`) at
`.github/workflows/sign-release.yml`. It contains **secret names only** — no
values. Trigger it manually with the Panecho release tag after a release is cut.

```yaml
name: Sign & notarize Panecho release
on:
  workflow_dispatch:
    inputs:
      release_tag:
        description: Panecho release tag to sign (e.g. panecho-v0.64.10 or panecho-nightly)
        required: true

permissions:
  contents: read

jobs:
  sign:
    runs-on: macos-15
    timeout-minutes: 30
    steps:
      - name: Checkout public Panecho repo at the release tag
        uses: actions/checkout@v4
        with:
          repository: xxshubhamxx/cmux-panecho
          ref: ${{ inputs.release_tag }}

      - name: Download the unsigned release artifact
        env:
          GH_TOKEN: ${{ secrets.CROSS_REPO_TOKEN }}
        run: |
          set -euo pipefail
          gh release download "${{ inputs.release_tag }}" \
            -R xxshubhamxx/cmux-panecho -p '*macos.zip' --dir .
          ditto -x -k *macos.zip extracted
          test -d "extracted/Panecho.app"

      - name: Import Developer ID certificate into a temp keychain
        env:
          APPLE_CERTIFICATE_BASE64: ${{ secrets.APPLE_CERTIFICATE_BASE64 }}
          APPLE_CERTIFICATE_PASSWORD: ${{ secrets.APPLE_CERTIFICATE_PASSWORD }}
        run: |
          set -euo pipefail
          KEYCHAIN_PASSWORD="$(uuidgen)"
          echo "$APPLE_CERTIFICATE_BASE64" | base64 --decode > /tmp/cert.p12
          security create-keychain -p "$KEYCHAIN_PASSWORD" build.keychain
          security set-keychain-settings -lut 21600 build.keychain
          security unlock-keychain -p "$KEYCHAIN_PASSWORD" build.keychain
          security import /tmp/cert.p12 -k build.keychain -P "$APPLE_CERTIFICATE_PASSWORD" \
            -T /usr/bin/codesign -T /usr/bin/security
          security set-key-partition-list -S apple-tool:,apple: -s -k "$KEYCHAIN_PASSWORD" build.keychain
          security list-keychains -d user -s build.keychain

      - name: Write notarization API key
        env:
          ASC_API_KEY_P8_BASE64: ${{ secrets.ASC_API_KEY_P8_BASE64 }}
        run: |
          set -euo pipefail
          echo "$ASC_API_KEY_P8_BASE64" | base64 --decode > /tmp/AuthKey.p8

      - name: Sign (Developer ID, hardened runtime)
        env:
          APPLE_SIGNING_IDENTITY: ${{ secrets.APPLE_SIGNING_IDENTITY }}
        run: |
          set -euo pipefail
          ./scripts/sign-cmux-bundle.sh \
            extracted/Panecho.app \
            panecho.release.entitlements \
            "$APPLE_SIGNING_IDENTITY"

      - name: Notarize + staple (DMG + zip)
        env:
          APPLE_SIGNING_IDENTITY: ${{ secrets.APPLE_SIGNING_IDENTITY }}
          ASC_API_KEY_PATH: /tmp/AuthKey.p8
          ASC_API_KEY_ID: ${{ secrets.ASC_API_KEY_ID }}
          ASC_API_ISSUER_ID: ${{ secrets.ASC_API_ISSUER_ID }}
        run: |
          set -euo pipefail
          ./scripts/notarize-and-staple-panecho.sh \
            extracted/Panecho.app \
            "$APPLE_SIGNING_IDENTITY"

      - name: Upload signed assets back to the public release
        env:
          GH_TOKEN: ${{ secrets.CROSS_REPO_TOKEN }}
        run: |
          set -euo pipefail
          gh release upload "${{ inputs.release_tag }}" \
            Panecho.dmg panecho-macos.zip \
            -R xxshubhamxx/cmux-panecho --clobber

      - name: Cleanup
        if: always()
        run: |
          security delete-keychain build.keychain >/dev/null 2>&1 || true
          rm -f /tmp/cert.p12 /tmp/AuthKey.p8
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

## Caveat

`com.apple.developer.web-browser.public-key-credential` is retained in
`panecho.release.entitlements` only because `scripts/sign-cmux-bundle.sh`
requires it post-sign. Under Developer ID (no provisioning profile) the
capability is inert — in-app-browser passkeys won't function — but signing and
notarization are unaffected. To make it functional, register `io.panecho.app`
with that capability under team `YQ5FZQ855D` and embed a managed provisioning
profile.
