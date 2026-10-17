# Search-active terminal close freeze report

## Summary

I have been hitting frequent cmux freezes where the macOS app becomes unresponsive and shows the spinner. The clearest sampled occurrence happened while terminal search/find state was active or recently active and a terminal surface was being torn down.

This document records the observed failure and links a possible fix. The proposed fix is entirely AI-suggested and should be reviewed as a hypothesis-backed patch, not as a fully human-audited Ghostty threading change.

## Observed hang

A local sample of the hung cmux process showed the app/main thread blocked in Ghostty teardown:

```text
Main Thread
  ghostty_surface_free
  Surface.deinit
  pthread_join
```

The join location corresponds to Ghostty's per-surface search thread shutdown, before renderer and IO thread joins.

## Suspected deadlock

The suspected sequence is:

1. cmux closes or frees a terminal surface on the app/main thread.
2. Ghostty `Surface.deinit` asks the per-surface search thread to stop and then synchronously joins it.
3. While exiting, the search thread emits final search UI callbacks such as clearing selected match, viewport highlights, and match counts.
4. Those callbacks can enqueue messages into renderer/app mailboxes.
5. If a mailbox is full and the callback waits indefinitely, the search thread waits for queue progress while the app/main thread is already waiting for the search thread to exit.

That produces a full app freeze.

## Proposed fix

A proposed Ghostty-side patch is open here:

- https://github.com/manaflow-ai/ghostty/pull/55

The patch changes search-thread callback delivery so it no longer waits forever on renderer/app mailbox pushes:

- normal search callback delivery gets a short bounded wait to preserve ordering in ordinary cases;
- once surface teardown has started, search callback delivery becomes instant/best-effort;
- arena-backed renderer messages deinitialize their arena if they cannot be enqueued.

Search UI notifications are stale/recoverable state. During teardown the surface is already closing, so dropping a final search reset is preferable to deadlocking the application.

## Local validation performed

The AI-suggested patch was built locally with:

```bash
zig fmt --check ghostty/src/Surface.zig
zig build -Demit-xcframework=true -Demit-macos-app=false -Dxcframework-target=universal -Doptimize=ReleaseFast
./scripts/reload.sh --tag fix-search-shutdown-hang
```

The tagged cmux debug build completed successfully.

## Caveat

The freeze is real and has been happening often locally, but the proposed fix and root-cause analysis are AI-assisted. Please treat the linked Ghostty PR as a concrete candidate fix that needs careful review by someone familiar with Ghostty's search, mailbox, and surface teardown threading model.
