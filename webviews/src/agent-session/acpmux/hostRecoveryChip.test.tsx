// l10n-allow-file: assertions on the English catalog's words.
// The host's chip above the composer while the pane gets acpmux back (HostError.tsx), second by second:
// a reconnect or a handshake that waits for acpmux shows nothing for its first 10 s, then only the quiet
// "Reconnecting…" chip for as long as it lasts: no clock, no button, no words about the service.
// "Restoring sessions…" keeps its ticking `m:ss` in the shared clock (ui/Typography.tsx `Clock`).
import { expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import { HostRecoveringLine } from "./HostError";
import { RECONNECT_LINE_AFTER_MS, hostRecoveryLine } from "./hostRetry";

const text = (markup: string) => markup.replace(/<[^>]+>/g, "");
const NEVER = /Waiting for|Restart agent service|\d:\d\d/;

test("a reconnect under 10 s shows nothing", () => {
  for (let now = 0; now < RECONNECT_LINE_AFTER_MS; now += 250) {
    const line = renderToStaticMarkup(<HostRecoveringLine relinkingSince={0} waitingSince={1_200} now={now} />);
    expect(line).toBe("");
    expect(hostRecoveryLine({ relinkingSince: 0, waitingSince: 1_200, now })).toBeUndefined();
  }
});

test("a 90 s handshake wait shows the Reconnecting chip from 10 s on, and nothing else", () => {
  for (let now = 0; now <= 90_000; now += 250) {
    const line = renderToStaticMarkup(<HostRecoveringLine waitingSince={0} now={now} />);
    expect(text(line)).not.toMatch(NEVER);
    expect(line).not.toContain("<button");
    if (now < RECONNECT_LINE_AFTER_MS) expect(line).toBe("");
    else expect(text(line).trim()).toBe("Reconnecting…");
  }
  // A drop whose handshake starts later counts from the drop, and the chip stays past the old 25 s deadline.
  expect(hostRecoveryLine({ relinkingSince: 0, waitingSince: 26_000, now: 27_000 })).toEqual({ kind: "reconnecting" });
  expect(hostRecoveryLine({ relinkingSince: 0, now: 90_000 })).toEqual({ kind: "reconnecting" });
  // A failure the pane already says keeps the line to itself.
  expect(hostRecoveryLine({ waitingSince: 0, failureShown: true, now: 90_000 })).toBeUndefined();
});

test("the restoring chip ticks in the fixed-width clock", () => {
  const restoring = renderToStaticMarkup(<HostRecoveringLine restoring={{ waitedMs: 12_000, at: 0 }} now={3_000} />);
  expect(restoring).toMatch(/<span class="ui-clock" data-clock-size="0:00">0:15<\/span>/);
  expect(text(restoring)).toContain("Restoring sessions… 0:15");
});
