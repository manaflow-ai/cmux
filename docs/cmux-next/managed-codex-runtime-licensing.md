# Managed Codex runtime: packaging, license and app-server compatibility

The first step of competitor-teardown row 5 (`plans/next-ux/competitor-teardown.md` §5, ledger
5e18c4832b): before cmux offers an explicitly selected managed Codex runtime, establish whether it may
ship one and which app-server versions it can speak. This page records what was found on
2026-11-22. It is a finding, not a decision: redistribution is Leo's call.

## License

- The Codex CLI (`github.com/openai/codex`) is Apache-2.0. Its `NOTICE` names OpenAI and code
  derived from Ratatui (MIT).
- Apache-2.0 permits redistributing the unmodified release binaries, commercially included, on
  these conditions: ship the license text, keep the `NOTICE`, and do not use OpenAI's marks beyond
  naming the origin. It grants no trademark rights, so the runtime must be labelled as "Codex by OpenAI,
  managed by cmux", never presented as cmux's own.
- Using the binary does not license the service: a person still signs in with their own ChatGPT or
  API account. The runtime keeps the person's `CODEX_HOME`, and cmux copies no credentials.

## Redistributable artifacts

- OpenAI publishes per-platform release archives on GitHub Releases
  (`codex-{aarch64,x86_64}-apple-darwin.tar.gz`, `codex-{aarch64,x86_64}-unknown-linux-musl.tar.gz`)
  and through `https://chatgpt.com/codex/install.sh` (from `releases.openai.com/codex`, falling back
  to GitHub). npm (`@openai/codex`) and Homebrew (`brew install --cask codex`) ship the same builds.
- cmux already downloads one of these on explicit request without bundling it: `acpmux harness
  codex-runtime install` (`managed_codex.rs`) fetches the pinned official 0.156.1 archive, checks its
  SHA-256, and activates it by an atomic symlink swap. A Codex found on PATH is still preferred.
  Download-on-request is plain use under the license. Shipping the binary inside cmux.app is
  redistribution, which Apache-2.0 allows under the conditions above, with the notice files added to
  the app's acknowledgements.

## App-server compatibility

- Codex's app-server docs (`learn.chatgpt.com/docs/app-server`) define a stable surface and an
  `experimentalApi` capability. A client that does not opt in gets only stable methods, and the
  server rejects experimental methods and fields.
- No cross-version guarantee is published. The generated schemas (`codex app-server
  generate-json-schema`) are "specific to the Codex version you ran", and deprecations
  (`thread/resume` full history, `supportsPersonality`) are announced inline (`deprecationNotice`).
  The WebSocket transport is "experimental and unsupported"; stdio is the supported transport.
- What follows for cmux: pin the managed runtime to versions acpmux's translator was tested
  against. Speak only the stable surface over stdio. Identify as cmux in `initialize.clientInfo`.
  Treat any other version as a user CLI: run it, but do not call it known-compatible.

## Recommendation (for Leo to decide)

Redistribution is permitted. The recommendation is to keep download-on-request (what
`managed_codex.rs` does today) rather than bundle the binary in the app. Download-on-request keeps
the app smaller, needs no license-file bundling, and leaves the update cadence to a pinned,
hash-checked manifest. The opt-in path is:

1. Settings > Agents offers "Managed Codex (version X, by OpenAI)" next to the detected CLI. It is
   selected explicitly, and the current CLI stays the default.
2. Install stages a versioned directory, verifies size, SHA-256 and `--version`, then activates it
   by atomic swap. A failure (corruption, cancel, disk full) leaves the previous runtime selected.
3. Each session records the runtime path and version it started on. Removing a runtime a session
   or profile uses is refused, with the next step named.
4. #45370 (the bundled app-server prototype behind `labs.bundledCodexAppServer`, off by default)
   already covers manifest, protocol and fallback checks. The runtime owner (acpmux) merges the two
   paths, so cmux has one managed runtime, not two.

This step builds nothing beyond this note. It changes no default, and nothing migrates PATH or
credentials.
