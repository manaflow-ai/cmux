# Record the browser shell against a live daemon

`scripts/cmux-next/browser-next-capture.ts` records the served shell in headless
Chrome on Linux. It opens a chat through the shell, types a fresh nonce, observes
the agent's completed reply, then reloads and checks that chat and reply return.
This is an opt-in recording runner, not a CI job or merge gate.

Capture remains **pending** until the shell, ordinary account enrollment and a
same-account machine with a real Codex or Claude session are available. A test of
the recorder's evidence parser does not establish browser acceptance.

## Prior art and the gap

[#45114](https://github.com/manaflow-ai/cmux/pull/45114)'s
`scripts/cmux-next/web-device-demo.ts` provides the headless Playwright recipe:
patched system Chrome, `recordVideo`, a nonce reply, a screenshot, then close the
context to finish the WebM. Its harness supplies device enrollment and hello on
the pane's socket, and it can use a stand-in agent. The earlier local-pane video
and hub-chat refusal do not prove the signed-in browser journey.

This runner navigates the actual HTTP server. It never fulfills routes, injects
a host bridge, substitutes a socket, enrolls devices itself or sends RPC calls.
Only page-generated frames from the configured daemon origin count. A successful
browser `device_hello` with `webDevice` authorization must precede the intended
chat's attach. A user echo, unrelated chat or historical reply cannot satisfy the
nonce. A second authenticated attach and visible answer must follow reload.
The behavioral detector is `browser-next-capture.test.ts`; the live detector is
the runner's result plus its video. This closes the evidence gap between a pane
fixture or harness-authenticated transport demo and a usable browser shell.

## Prepare and run

1. Build the shell/pane and daemon at explicit commits through `cmux-ci`.
   The lane's supported artifact route is `cmux-ci test --at FULL_SHA --artifact
   LOCAL_DIR -- COMMAND`: write build outputs to `$FAST_CHECKS_OUT` in the job.
   Keep the returned job, source SHA and artifact digest receipt with the capture.
   Downloaded artifacts run on this VM; do not compile them here.
2. Start the built server using its documented invocation and a disposable test
   account's normal enrollment. The account-login lane owns this procedure.
   Never use the person's local daemon token, copied machine credential, mock
   bridge or the old demo's injected hello to unblock capture. If a storage-state
   file is needed, it must come from that ordinary account flow. The runner reads
   it but never writes or publishes it. Use a dedicated chat with no private text.
3. Install the pinned `webviews` dependencies and the browser through the supported
   fleet setup: `bun install --frozen-lockfile`,
   `scripts/ci/ensure-system-chrome.sh`, and Playwright's `install ffmpeg`.
   The runner uses `webviews/test/support/systemChrome.ts` and refuses Macs.
4. Create a private JSON file outside the checkout using the actual shell's
   selectors. The values below illustrate the shape; they are not a claim that
   these shell selectors or a server on port 4100 exist:

```json
{
  "url": "http://127.0.0.1:4100/",
  "websocketOrigin": "ws://127.0.0.1:4100",
  "target": "test-machine/test-session-id",
  "shellSelector": "nav[aria-label='Workspaces']",
  "openSelectors": ["button:has-text('Browser capture')"],
  "paneFrame": "iframe[title='Agent chat']",
  "composerSelector": "[contenteditable='true']",
  "replySelector": ".cv-assistant",
  "storageState": "/private/path/account-state.json",
  "sourceHead": "FULL_40_CHARACTER_SHELL_SOURCE_SHA",
  "daemonHead": "FULL_40_CHARACTER_DAEMON_SOURCE_SHA",
  "agent": "codex"
}
```

Omit `paneFrame` for a top-level pane and `storageState` when unnecessary.
`openSelectors` are clicked in order in the shell; choose one unambiguous target
for each. `replySelector` must select assistant text, not the whole transcript.
The artifact heads and harness are operator-supplied provenance, explicitly
separate from the observed wire results. Verify them against the CI receipt.

```sh
bun scripts/cmux-next/browser-next-capture.ts /private/path/capture.json /tmp/browser-capture-UNIQUE
```

The output directory must be new. Exit 0 requires all flow assertions and a
nonempty finalized `demo.webm`; exit 1 writes failure evidence, and exit 2 means
configuration/setup input was invalid. Each action has a deadline; the flow has
a five-minute bound. Video finalization has a separate 20-second deadline and
browser shutdown has 10 seconds; a timeout still writes a failed result. Only
the browser started by this runner is closed. It does
not stop the server, daemon or agent session.

## Read back and hand off

Inspect `01-shell.png`, `02-attached.png`, `03-reply.png`, `04-reloaded.png` and
`demo.webm`. Report `result.json` with the CI receipt and the video SHA-256.
Inspect the pictures/video for private text before publishing. The JSON includes
no URL, credential, raw socket frame, console text or exception text; failures
name the stage. Screenshots and video contain what the test account sees.

Run the parser's focused checks on the fleet, independently of live acceptance:

```sh
cmux-ci test -- bun test scripts/cmux-next/browser-next-capture.test.ts
```

If shell serving, enrollment or the agent fails, keep capture pending and report
the named stage, exact source/artifact identity and owning lane. Do not relabel
a local-pane video, stub reply or mocked WebSocket as a passing browser capture.
