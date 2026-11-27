# 2026-11-26-workflow_dispatch-2

Above `NIGHTLY_NEXT_RETIRED_FEED_BASE: https://files-next.cmux.com/nightly-next/next` (job `workflow_dispatch`) in `.github/workflows/nightly.yml`.

The retired cmux NEXT-identity feed (com.cmuxterm.app.nightly.cmux-next).
It gets no builds, only the handover item that sends a stray install to
cmux NIGHTLY (publish-nightly). The canary verdicts and pulled.json stay
in its folder, where the app reads them (UpdaterService.channelFolder).
