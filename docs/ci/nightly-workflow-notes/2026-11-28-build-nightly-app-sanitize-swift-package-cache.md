# 2026-11-28-build-nightly-app-sanitize-swift-package-cache

Where: `.github/workflows/nightly.yml`, job `build-nightly-app`, step "Sanitize Swift package cache": above `- &restore-bun-web-bundles`.

Every restore here sets TOOLCHAIN_R2_ALL: the nightly Macs are not Freestyle runners, and github.com refuses setup-bun's anonymous download from them (403, runs 45765712386 and 45756842046).
