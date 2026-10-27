# Web Page Replay for corpus stories

`wpr.py` gives the Chromium tabs of a corpus story the same pages on every run, with no network:
it runs [Web Page Replay](https://chromium.googlesource.com/webpagereplay) (`wpr`) next to a
bench app and points the app's Chromium at it
([p12-perf-process.md](../../../plans/cmux-next/chrome-parity/p12-perf-process.md) section 3.8, task 113).
The story manifest names the archive in `web_archive` (see [perf-corpus/README.md](../../../perf-corpus/README.md)).

```sh
python3 -I scripts/perf-lab/corpus/wpr.py spki
python3 -I scripts/perf-lab/corpus/wpr.py record --app BUNDLE --urls pages.txt --archive browse-heavy.wprgo
python3 -I scripts/perf-lab/corpus/wpr.py verify --app BUNDLE --urls pages.txt --manifest perf-corpus/browse-heavy.json
python3 -m unittest scripts/perf-lab/tests/test_corpus_wpr.py
```

## How the app reaches wpr

Chrome's Telemetry does the same (catapult `webpagereplay_go_server.py` and
`chrome_startup_args.py`):

1. `wpr replay` (or `record`) starts on free loopback ports. `wpr.py` reads the ports from its
   `Starting server on http(s)://127.0.0.1:PORT` lines.
2. The bench app starts with `CMUX_NEXT_BENCH_CEF_SWITCHES`, one switch on each line:
   - `host-resolver-rules=MAP *:80 127.0.0.1:HTTP,MAP *:443 127.0.0.1:HTTPS,MAP * ~NOTFOUND,EXCLUDE localhost,EXCLUDE 127.0.0.1`.
     Every page request goes to wpr. A host on any other port fails to resolve, so nothing
     goes to the network.
   - `ignore-certificate-errors-spki-list=SPKI`, where SPKI is the base64 SHA-256 of the
     public key of wpr's certificate (`wpr.py spki`). Chromium accepts that one certificate
     and no others.

These switches go only to the bench app:

- `wpr.py` puts the variable in the environment of the bench app only. It refuses to run when its
  own environment already has the variable.
- `CEFSwitches` (task 221) reads the variable only in Debug and bench builds, and only for a
  development bundle (`.debug` in the bundle id, or a `.dev` suffix).
- From the variable, `CEFSwitches` keeps only these two switch names.
- `wpr.py` refuses any other bundle id. A shipped app ignores the switches and loads the live
  sites.

## Record (lab host, public URLs)

`record` runs only on a lab host in `pool.json`. The URL list has one URL on each line; `#`
starts a comment. Each URL must be a public page:

- http or https, on the default port
- no credentials, no query and no fragment
- a public DNS name whose addresses are all global (no `.local`, `.test`, `.ts.net` or private
  address)

A fresh bench app opens each URL in its own Chromium tab while `wpr record` records. When every
page has loaded, wpr stops with SIGINT and writes the archive. `wpr.py` then adds the archive to
the corpus blob cache and prints `WPR-RECORD ok ... web_archive={...}`. To use the archive:

1. Copy the printed `web_archive` into the story manifest.
2. Keep the URL list with the story's recorder task (`--out` also gets `wpr-record.json`, which
   holds the URL list).
3. Run `manifest.py --upload` to put the blob in R2.

## Verify

`verify` replays a story's archive (fetched into the blob cache), or an `--archive`, `--runs`
times (default 2). Each run does these steps:

1. Launch a fresh bench app. Hibernation and freezing are off, so each tab keeps its page.
   Before the launch, `wpr.py` moves the app's Chromium storage
   (`~/Library/Application Support/<bundle id>/Chromium`) to `Chromium.wpr-prev`. Thus each run
   starts with no HTTP cache, cookies or service workers, and every request goes to wpr.
   `record` does the same, so that no cached file is left out of the archive.
2. Check `debug.cef`: Chromium is available, and no tab fell back to WebKit.
3. Open `--tabs` tabs (default 30), round-robin over the URL list.
4. Wait for each tab with `browser.page.wait` (`load_state: complete`).
5. Check each tab with `debug.browser.page_status`: no error page, no certificate warning, no
   Chromium error page and no sad tab.

The verify passes only when all of these are true:

- every run loads all its tabs, and the runs load the same number of pages
- wpr logged 0 `msg="Proxy: FAILED to find request"` lines (network misses). wpr logs with
  Go's `log/slog` text format; a hit is `msg="Proxy: SERVING response"`, and each request line
  has its `url=` attribute
- wpr logged 0 TLS handshake errors
- wpr served at least one response, which proves that the resolver rules applied

A certificate warning or a TLS handshake error means that Chromium did not accept the spki.
`wpr.py verify` stops when the story's spki is not the spki of the wpr build. In that case, the
archive was recorded with another pinned wpr commit, and you must record it again.

`--out DIR` gets the wpr logs (`wpr-replay-N.log`), the app logs and `wpr-verify.json`.

## wpr itself

`scripts/perf-lab/host-setup.sh` builds wpr at the commit that `pool.json` pins (`wpr.commit`),
in `~/Library/Application Support/cmux-perf-lab/wpr/<commit>`. This folder is a checkout of the
repository: `wpr`, `wpr_cert.pem`, `wpr_key.pem` and `deterministic.js`. `wpr.py` refuses a build
of another commit. `--wpr DIR` selects another build of the same commit. wpr runs with that
folder's certificate, key and `deterministic.js` (Telemetry's injected script, which makes
`Date` and `Math.random` repeatable).
