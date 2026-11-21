# Rust dependency policy

Cargo resolutions in this repository wait three days after a crate is published. The policy is
configured in the repository-root `.cargo/config.toml`, so it applies to `cmux-tui`, the mobile
workspace, OptChat, and the other Rust workspaces under this checkout.

The cooldown protects routine lockfile refreshes from a compromised or immediately yanked
publication. It also means a legitimate fix can wait up to three days; existing locked versions
continue to resolve. Cargo registries that do not expose publication timestamps and `cargo install`
are outside this protection.

For an urgent security update, use a one-shot override and record the advisory and selected
version in the PR:

```sh
CARGO_RESOLVER_INCOMPATIBLE_PUBLISH_AGE=allow cargo update CRATE --precise VERSION
```

Do not put the override in a checked-in config or CI environment.
