# Team dev setup

For cmux team members with a Stack account. Outside contributors use the local path in [CONTRIBUTING.md](../CONTRIBUTING.md#getting-started).

DEBUG builds can auto-sign-in as you and auto-attach an iOS build to your Mac with no manual steps. Each developer does a one-time setup with their own Stack account.

Run this once:

```bash
scripts/setup-team-dev.sh
```

It prompts for your Stack email and password (the password is never echoed), verifies them against Stack, and writes `~/.secrets/cmuxterm-dev.env` with `chmod 600`. Re-running it is safe; if you are already configured it prints the account and exits. To reset, delete `~/.secrets/cmuxterm-dev.env` and run it again.

After that, every dev build signs you in automatically:

```bash
scripts/dev-setup.sh --tag <your-initials>
```

That builds the tagged macOS DEBUG app auto-signed-in as you, enables the iOS pairing host, mints an attach ticket, and launches the iOS dev build auto-attached to your Mac. Use `--surface mac` for macOS only. See `scripts/dev-setup.sh --help` for all flags.

This is DEBUG-only and per-user. The credentials file lives outside the repo and is never committed; `scripts/cmuxterm-dev.env.example` is the in-repo template. Release builds never read these credentials (the auto-sign-in path is compiled out of release).
