# Shipped agent pane on the web listener

`acpmux web --app` opens the NEXT agent pane on the daemon's existing listener.
`acpmux --json web --app` returns its URL without opening a browser;
`acpmux web --app --no-open --show-token` prints a usable link. Without `--app`,
the dashboard is unchanged. Human output hides the token unless requested.

The launch URL is `http://<existing-listener>/app/#token=<browser-app-token>`.
This is lowercase hex HMAC-SHA256 with the listener secret as the key and
`acpmux-browser-app-v1\0/app/ws` as the message (a NUL byte before `/app/ws`).
It never exposes the reusable dashboard token. The fragment never goes to the
HTTP server. The browser connects to `/app/ws`, offering `acpmux.v1` and
`acpmux.token.<browser-app-token>` as WebSocket subprotocols; only `acpmux.v1`
is echoed. This token cannot admit a dashboard connection, and the dashboard
token cannot admit `/app/ws`. Listener token rotation invalidates both.

Admission sets `ConnAuth::BrowserApp` with Web origin. Peer credentials and a
LocalApp first-frame token cannot promote it. The browser handshake must still
prove the same owner before RPC and event streaming. Static files grant no
session access and contain no token. The same listener Host and Origin policy
applies to the dashboard and every `/app/` request.

`/app/` and `/app/index.html` serve the production pane's `index.html`. All
relative scripts, styles, workers, chunks and locales load beneath `/app/`.
Only the browser response changes `connect-src 'none'` to `connect-src 'self'`;
the native resource on disk keeps its original CSP. The native saved-chat path
`/app/__snapshot/chat.js` returns an empty script, since a browser has no native
saved chat to paint. The browser host shim and handshake ship in `pane.js`.

The Linux and macOS daemon package embeds the same production pane, packed with
`cmux_embed`. The package build runs `build-agent-pane-web.sh` and points
`ACPMUX_BUNDLED_APP_ASSETS_DIR` at its output for Cargo; `build.rs` refuses any
output the HTTP allowlist would not serve, and any missing required file. Install,
update and rollback then carry the matching pane inside the one executable. The
daemon's artifact key includes the pane's sources and inputs.

A source build without an embedded pane looks for `agent-pane` beside its
executable, then the existing `CmuxNext_CmuxNextAgentPane.bundle` in the executable
directory's parent (`Contents/Resources/agent-pane` or `agent-pane` inside that
bundle), then `share/acpmux/agent-pane` in that parent. It never searches another
installation, a checkout, the current directory, or a development server.

For a custom distribution, build the pane with
`scripts/cmux-next/build-agent-pane-web.sh --out <directory>`, then embed it by
setting `ACPMUX_BUNDLED_APP_ASSETS_DIR=<directory>` for the Rust build, package it
beside the binary as `agent-pane`, or start the daemon with
`ACPMUX_APP_ASSETS_DIR=<directory>`. That runtime directory takes precedence over
the embedded pane, including when it is missing: another build's resources are
never silently substituted. Missing resources return 503;
unknown files return 404. Only the builder's known root files and `.js` files in
`chunks/` and `locales/` are addressable. Traversal, encoded path separators and
symlinks outside the resource directory cannot expose other files.

The regression detectors are `server::app_assets::tests`, `browser_app_*`,
`app_assets_keep_the_listener_host_and_origin_policy` in `web_listener_auth`,
and `web_no_open_prints_the_link_without_its_token_unless_asked` in
`web_token_exposure`. Run them through `cmux-ci` at the integrated commit; they
cover the asset boundary, native/browser CSP separation and CLI token handling.
An end-to-end browser check must additionally load the production bundle and
complete the authenticated shell handshake; static-file tests alone do not
prove a working chat.
