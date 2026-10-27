# Program links: where a terminal program's browser opens

When a program in a cmux-next terminal opens a web page in "the browser" (`aws
login`, `gh auth login`, `gcloud auth login`, `npm login`, a dev server's "open in
browser", Python's `webbrowser`, `open https://…`), cmux opens it in a cmux browser
tab beside that terminal by default, instead of the macOS default browser. The
macOS default browser is never changed. OAuth sign-ins that redirect to
`http://127.0.0.1:<port>/…` still work: the tab runs on the same Mac.

## How it is caught

Every cmux-next terminal starts with:

- `BROWSER=cmux-open-url`, unless `BROWSER` is already set. Tools that honor
  `BROWSER` (Python `webbrowser`, so the AWS CLI and gcloud; gh) run it. A
  `BROWSER` you set in your shell startup files wins.
- The app's `Contents/Resources/bin` first on `PATH` (kept first after your
  startup files). It holds `open` and `xdg-open` shims. `open` with only http(s)
  URLs (optionally `-g`, `-W`, `--`) goes to `cmux-open-url`; files, folders,
  apps (`open -a`) and every other option go to `/usr/bin/open` unchanged. When
  `BROWSER` is set to something other than `cmux-open-url`, every `open` goes to
  `/usr/bin/open`.

`cmux-open-url` passes the URL on stdin (never in argv) to `cmux open --link -`
with the names of the processes that asked (the program and its parents, such
as `aws`, `gh`, `python3`). The app decides where it goes. When the app cannot
be reached, the URL goes to `/usr/bin/open` (the default browser).

## Settings

Settings > Terminal > Opening Links, or `~/.config/cmux/cmux.json`:

```jsonc
"terminal": {
  "linkOpener": {
    // cmux | system | chrome | safari | arc | firefox | edge | brave
    // | app:<name, bundle ID or .app path> | command:<shell command>
    // A profile follows @: chrome@Profile 1, app:Firefox@work.
    "default": "cmux",
    // Checked in order before the default; the first match wins.
    "rules": [
      "caller:aws -> chrome@Profile 1",             // everything the AWS CLI opens
      "caller:gh,git github.com/login -> safari",   // gh or git, on that page
      "re:^https://[^/]*\\.corp\\.example\\.com/ -> system",
      "* -> command:~/bin/pick-browser"             // a script decides the rest
    ]
  }
}
```

- `cmux` as the default follows the link rules for clicked links
  (`browser.openLinksInCmuxBrowser`, `browser.hostsToOpenInEmbeddedBrowser`,
  `browser.urlsToAlwaysOpenExternally`) and opens where `layout.linkPlacement`
  puts a terminal's link (split right by default). A rule or hook that names
  `cmux` opens a cmux tab whatever those link rules say. The tab opens without
  taking the keyboard from the terminal.
- A rule is `<match> -> <target>`. The match is any number of
  `caller:<glob>[,<glob>…]` terms and an optional URL pattern. A caller glob
  (`*`, `?`, any case) matches the name of the program that opened the URL or of
  one of its parent processes. The URL pattern has the syntax of
  `browser.urlsToAlwaysOpenExternally`: plain text matches anywhere in the URL,
  `*` and `?` are wildcards, `re:` starts a regular expression. No pattern, or
  `*`, matches every URL.
- A profile is passed to Chromium browsers (`--profile-directory=`: use the
  profile's folder name, such as `Default` or `Profile 1`) and to Firefox (`-P`).
  Other apps ignore it.

## The command hook

`command:<shell command>` runs in the terminal's shell environment (its `PATH`
and working directory) with:

- the URL in `CMUX_LINK_URL` and on stdin (never in argv);
- the caller names, comma-separated, in `CMUX_LINK_CALLERS`.

It either opens the URL itself (exit 0, print nothing), or prints one target on
its first line (`cmux`, `system`, `chrome@Work`, `app:Arc`) for cmux to open the
URL in. It may not print another `command:` target. A non-zero exit falls back to
the default browser.

```sh
#!/bin/sh
# ~/bin/pick-browser
case "$CMUX_LINK_CALLERS,$CMUX_LINK_URL" in
  *aws*) echo "chrome@Profile 2" ;;
  *zoom.us*) echo system ;;
  *) echo cmux ;;
esac
```

## Coverage

| Tool | How it opens a browser | Lands in cmux |
| --- | --- | --- |
| AWS CLI v2 (`aws login`, `aws sso login`) | Python `webbrowser`, `BROWSER` | yes |
| gcloud (`gcloud auth login`) | Python `webbrowser`, `BROWSER` | yes |
| Python `webbrowser` | `BROWSER` | yes |
| gh (`gh auth login --web`, `gh browse`) | `GH_BROWSER`/`BROWSER`, else `open` | yes |
| Node `open` package (npm login, many CLIs) | `open` on `PATH` | yes |
| Go `pkg/browser`, `cli/browser` | `open` on `PATH` | yes |
| Claude Code (`claude` sign-in) | Node `open` package | yes |
| Shell scripts calling `open <url>` / `xdg-open <url>` | `PATH` shims | yes |
| Programs that run `/usr/bin/open` by absolute path, or LaunchServices directly (Rust `webbrowser`/`open` crates, so the Codex CLI's sign-in; native macOS apps) | not through `PATH` or `BROWSER` | no: they open the default browser; copy the printed URL |

## Turning it off

Set `"terminal.linkOpener.default": "system"` (and no rules): every program link
goes to the default browser. To stop cmux from catching program links at all,
set `BROWSER` in your shell startup files (for example
`export BROWSER=open`); `open` then passes everything to `/usr/bin/open` too.
