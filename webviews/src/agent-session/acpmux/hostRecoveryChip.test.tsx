// l10n-allow-file: assertions on the English catalog's words.
// The host's chip above the composer while the pane gets acpmux back (HostError.tsx). It follows the
// connection's state, never a clock (Leo, 2026-11-22: "surely we can think of better fixes than random
// timing which can shift"): a drop, a handshake that waits for acpmux, or a planned restart shows nothing
// however long it lasts; a failed attempt (`linkDown`) shows only the quiet "Reconnecting…" chip until a
// connect: no clock, no button, no words about the service. "Restoring sessions…" keeps its ticking
// `m:ss` in the shared clock (ui/Typography.tsx `Clock`).
import { expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import { HostRecoveringLine } from "./HostError";
import { hostRecoveryLine } from "./hostRetry";

const text = (markup: string) => markup.replace(/<[^>]+>/g, "");
const NEVER = /Waiting for|Restart agent service|\d:\d\d/;

test("a link that is not down shows nothing at any time", () => {
  for (let now = 0; now <= 90_000; now += 250) {
    expect(renderToStaticMarkup(<HostRecoveringLine now={now} />)).toBe("");
    expect(hostRecoveryLine({ now })).toBeUndefined();
  }
});

test("a link down shows the Reconnecting chip from its first frame to the connect, and nothing else", () => {
  for (let now = 0; now <= 90_000; now += 250) {
    const line = renderToStaticMarkup(<HostRecoveringLine linkDown now={now} />);
    expect(text(line)).not.toMatch(NEVER);
    expect(line).not.toContain("<button");
    expect(text(line).trim()).toBe("Reconnecting…");
  }
  // The connect clears it.
  expect(renderToStaticMarkup(<HostRecoveringLine linkDown={false} now={90_000} />)).toBe("");
  // A failure the pane already says keeps the line to itself.
  expect(hostRecoveryLine({ linkDown: true, failureShown: true, now: 90_000 })).toBeUndefined();
});

test("the restoring chip ticks in the fixed-width clock", () => {
  const restoring = renderToStaticMarkup(
    <HostRecoveringLine linkDown restoring={{ waitedMs: 12_000, at: 0 }} now={3_000} />,
  );
  expect(restoring).toMatch(/<span class="ui-clock" data-clock-size="0:00">0:15<\/span>/);
  expect(text(restoring)).toContain("Restoring sessions… 0:15");
});
