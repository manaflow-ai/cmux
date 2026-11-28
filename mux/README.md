# mux brain host

The local mux for cmux-next Home (plans/cmux-next/home.md section 4): a Bun
process that is a client of the cmux daemon's local conversation owner and of
acpmux, and listens on nothing.

Run from source: `bun host/src/main.ts host --daemon-socket <cmux-tui socket> --mux-home <dir>`.
Single executable: `bun run build` writes `dist/mux` (gitignored); the app
starts it through `CMUX_NEXT_MUX_HOST`. Env: `ACPMUX_SOCKET`, `ACPMUX_HOME`,
`ACPMUX_BIN` (the host starts `$ACPMUX_BIN daemon run` when the socket does not
answer), `CMUX_SOCKET_PATH`, `MUX_HARNESS` (claude-sr), `CMUX_MCP_COMMAND`.
A second launch for the same MUX_HOME exits 0. `mux --help` lists the CLI the
mux uses from its shell (`mux agents`, `mux memory`, `mux hook`, `mux compact`).

The host is a thin I/O shell: every decision (wake rule, catch-up, turns,
replies, outbox, child agents) is the sans-I/O core in
`packages/brain/src/core` (`core.step(input, now) -> effects`). The shared
behavior corpus `packages/brain/conformance/chief-cases.json` is generated from
it (`bun packages/brain/conformance/generate.ts`); the Rust Chief
(`cmux-tui/crates/cmux-chief`) must pass the same file.

Tests: `bun test` (fake daemon and fake acpmux under host/tests/fakes, and the
corpus against the core).
