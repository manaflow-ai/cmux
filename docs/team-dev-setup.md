# Team dev setup

For cmux team members with development accounts. Outside contributors use the local path in [CONTRIBUTING.md](../CONTRIBUTING.md#getting-started).

DEBUG builds can sign in automatically and attach an iOS build to your Mac. Configure a personal dogfood profile and a separate simulator/test profile; both accounts may belong to you.

Each profile requires an account password. If you normally sign in with an email code, first set your own password through the Hexclave account portal for the matching cmux environment. A one-time sign-in code cannot replace the password in this setup.

```bash
scripts/setup-team-dev.sh
```

The script prompts separately for the two development profiles, hides password input, verifies each account against the development sign-in service, and writes `~/.secrets/cmuxterm-dev.env` with mode `0600`. Rerunning it preserves complete profiles and prompts for any missing profile. Replace only the profile you need:

```bash
scripts/setup-team-dev.sh --refresh        # personal dogfood
scripts/setup-team-dev.sh --refresh-agent  # simulator/test
```

Setup also offers optional production credentials for developers who may want to verify against production. Press Enter or answer `no` to skip. Before opting in, set your own production account password through the Hexclave account portal for cmux production. Verified credentials go in `~/.secrets/cmuxterm-prod.env`; use `--refresh-production` to configure or replace them later. Production verification requires a launcher configured for production and an explicit `--credentials-file` selection. See [credential verification](contributor-verification.md#4-exercise-an-isolated-runtime) for profile and legacy-file details.

After development setup, launch a tagged build:

```bash
scripts/dev-setup.sh --tag <your-initials>
```

That builds the tagged macOS DEBUG app signed in with your personal profile, enables the iOS pairing host, mints an attach ticket, and launches the iOS dev build attached to your Mac. Use `--surface mac` for macOS only, or `--agent` to select the simulator/test profile for both the tagged Mac app and iOS Simulator. See `scripts/dev-setup.sh --help` for all flags.

This is DEBUG-only and per-user. Credential files live outside the repo and are never committed; `scripts/cmuxterm-dev.env.example` is the development template. Release builds never read these credentials (the sign-in automation is compiled out of release).
