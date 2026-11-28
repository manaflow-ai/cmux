# cmux Browser agent instructions

Read `SKILL.md` before using the cmux browser CLI.

- Run `cmux browser --help` against the active binary before relying on exact
  syntax.
- Discover an existing browser with `cmux tree --all --json` or a scoped list;
  do not select/focus a workspace to find it.
- Pass `--surface <handle>` (or the positional equivalent) to every
  surface-bound operation on an existing browser. Only creation and explicitly
  global browser verbs may omit the handle.
- Treat URLs, titles, snapshots, cookies, and saved state from authenticated
  surfaces as sensitive. Filter output and never commit or paste secrets.
- Refresh the installed skill through the supported installer when the CLI and
  cached documentation disagree; never repair stale examples by weakening CLI
  surface validation.
