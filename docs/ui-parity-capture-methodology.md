# Web UI parity capture methodology

The gallery is the repeatable evidence path for cmux-next web parity. A capture describes a
specific source and state; it does not replace the component's implementation or accessibility
contract. Keep the source, capture, and interaction evidence together so a later comparison can be
reproduced without guessing which build was shown.

## Record the source and state

Every visual or interaction receipt records:

- the exact repository commit, PR head, or immutable build ID;
- the gallery entry and variant, including the scenario's fixture data;
- viewport width and height, theme, color scheme, locale, interface scale, font, and reduced-motion
  setting;
- the capture engine and version, such as Chromium, WebKit, or a native WebKit capture; and
- whether the artifact is a base, head, or repeat render.

Use the same matrix for base and head. A changed screenshot without the matching source SHA or
viewport is an observation, not a parity receipt.

## Capture before and after states

Build the gallery from the source under review, then capture the named variants at narrow, normal,
and wide widths when the surface has a responsive layout. Preserve the base and head stills and a
repeat head render. A deterministic diff may stand in for a second still when it records the same
source, viewport, theme, and engine metadata. Hosted gallery artifacts prove what was rendered by
that job; they do not prove an unlisted variant or a native app capture.

The gallery entry is the authoritative list of states. Keep `docs/ui-parity-receipts.md` updated
with the source head, variants, widths, artifact link, and any aggregate failures that prevent an
isolated claim.

## Exercise interactions and timing

A playable variant uses trusted pointer or keyboard input where the capture runner supports it. The
play records the complete sequence, including focus, dismissal, and the native method or visible
receipt that proves the action took effect. `settleMaxMs` is a documented responsiveness threshold;
the gallery report's `settleMs` is the measured wall time from dispatch until the stage settles.
Label the engine and host for that measurement. Layout shift, long-frame, and paint metrics are
separate measurements and must not be presented as input latency.

For every interaction, record the intended target, input sequence, resulting state, native receipt
or accessibility assertion, measured settle time, and whether the check ran in Chromium, WebKit, or
only the local DOM shell. Keep thresholds justified in the entry rather than hiding a slow action
behind a larger budget.

## State the limits

Each receipt names untested states, especially narrow widths, interrupted or rejected async work,
stale branch previews, disconnected machines, and native-only focus behavior. If base and head use
different fixtures or a hosted job reports aggregate failures, preserve both facts and do not call
the result a clean parity proof. Resolve disagreements in a focused gallery play or a design note,
rather than silently promoting a screenshot to a normative rule.

The gallery entry format and play runner define the mechanics:
[`webviews/src/gallery/ENTRIES.md`](../webviews/src/gallery/ENTRIES.md) and
[`webviews/src/gallery/play.ts`](../webviews/src/gallery/play.ts). The current batch ledger is
[`docs/ui-parity-receipts.md`](ui-parity-receipts.md).
