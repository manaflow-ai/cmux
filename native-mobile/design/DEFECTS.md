# cmux-next native iOS: QA defect log

Found by the looped QA pass (simulators `cmux-native-qa`, `cmux-native-qa2` on
the build Mac, headless host `nxdemo`). Severity: S1 blocks a core flow, S2
wrong behavior with a workaround, S3 polish. Status: fixed (commit), open,
owner-handoff (written up for the owning agent).

| # | Area | Defect (repro, expected vs actual) | Sev | Status |
| --- | --- | --- | --- | --- |
| 1 | Connectivity | Restart the host bridge while the app is open: the link reconnects and terminals reattach, but the `svc` channel is never reopened, so Files, Changes, attachments and Feed replies fail until the app is relaunched. Cause: `HostConnection.openControl` only opened `svc` when `services == nil`. | S1 | fixed: reopen `svc` when the old channel ended; `ServiceClient.isClosed` |
| 2 | Errors | Link failures surfaced as "The operation couldn't be completed. (CmuxNativeLink.LinkError error 1.)". | S2 | fixed: `LinkError` is `LocalizedError` with plain copy |
| 3 | Connectivity | Every `.connected(path)` change (direct to relay, ICE restart) re-ran `openControl`: a second control channel, re-subscribe and terminal reattach, while the old control channel leaked. | S2 | fixed: keep live channels on a path change; close the old control before replacing it |
