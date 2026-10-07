# cmux-next web development

Run the whole web UI without rebuilding the Swift app:

```sh
scripts/cmux-next/web-dev.sh
```

Open the `INDEX_URL` printed by the command. It links to the real agent pane, the pane preview,
diff, Markdown, editor, Settings, and the other React pages. Vite+ watches `webviews/`, so an
edit normally appears in the open tab in about one second. The current base has no separate
gallery entry; the preview link is the available gallery-style fixture surface.

The launcher uses ports 4200 (the pages and file viewers), 4176 (the standalone agent pane), 4175
(the agent preview), 4177 (Settings), and 4199 (the index). Set `CMUX_WEB_DEV_*_PORT` variables
if a port is occupied. Every listener binds to `127.0.0.1`.

The daemon runs with `ACPMUX_HOME=$HOME/.acpmux/web-dev`, a random per-run WebSocket token, and
`--listen 127.0.0.1:0`. Its only allowed browser origins are the four Vite origins above. The
`--dev` and `--allow-dev-origin` flags are the acpmux development path; the origin list is not
written into the shared acpmux config. The token stays in the agent link fragment, which browsers
do not send to the Vite server or include in its logs.

The script first checks `$HOME/.cache/cmux-web-dev/acpmux/<git-sha>/acpmux`. If absent it runs
`cmux-ci run --class light --script scripts/cmux-next/build-acpmux.sh` on a macOS worker and
downloads the verified artifact into that cache. If the fleet client or artifact is unavailable,
it warns and uses `~/.local/bin/acpmux`; it never runs Cargo on the laptop. Ctrl-C asks that exact
daemon to run `acpmux daemon shutdown`, then terminates only the recorded Vite and index PIDs.

The browser host lives in `webviews/src/dev-host/host.ts`. It is imported only by the Vite
`dev.tsx` entry. The shim hands ACP frames to the real WebSocket transport, opens files in the
dev editor, returns empty local git/search results, and issues gesture tickets only after a real
DOM pointer or keyboard event. The shipped pane entry does not import this folder; verify after a
bundle build with:

```sh
! rg -n "dev-host|dev-gesture" webviews/dist  # no matches in shipped output
```

Focused shim tests use Bun and the existing jsdom-compatible test environment:

```sh
cd webviews
bun test src/dev-host/host.test.ts src/agent-session/acpmux/devHost.test.ts
```

No Playwright, headless browser, Cargo, Zig, Xcode, or Swift test command is part of this loop.
