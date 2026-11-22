// l10n-allow-file: assertions on the English catalog's words.
// The host's lines above the composer while the pane gets acpmux back (HostError.tsx), second by second:
// - "Reconnecting…" hands over to the waiting line ("Can't reach the agent service.") with no second between them
//   that draws neither. The reconnect's line ended 25 s after the drop, the waiting line began 25 s
//   after the first handshake, which starts a moment later: the line went for a second and came back.
// - The ticking `m:ss` of "Restoring sessions…" is the shared clock (ui/Typography.tsx `Clock`); the
//   waiting line has no timer at all, so its Restart agent service holds still.
import { expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import { HostRecoveringLine, HostWaitingLine } from "./HostError";
import { HOST_ERROR_DEADLINE_MS, hostRecoveryLine } from "./hostRetry";

const text = (markup: string) => markup.replace(/<[^>]+>/g, "");

test("Reconnecting… stays until the waiting line replaces it: no second draws neither", () => {
  // The drop at 0; the first handshake, whose wait the waiting line counts, starts 1.2 s later.
  const relinkingSince = 0;
  const waitingSince = 1_200;
  const blank: number[] = [];
  for (let now = 10_000; now <= 40_000; now += 250) {
    const line = renderToStaticMarkup(
      <HostRecoveringLine
        relinkingSince={relinkingSince}
        waitingSince={waitingSince}
        now={now}
        otherwise={<HostWaitingLine since={waitingSince} now={now} onRestart={() => undefined} />}
      />,
    );
    if (!text(line).trim()) blank.push(now);
  }
  expect(blank).toEqual([]);
  // And the waiting line is what shows once its own wait reaches the deadline.
  const at = waitingSince + HOST_ERROR_DEADLINE_MS;
  expect(
    text(renderToStaticMarkup(<HostWaitingLine since={waitingSince} now={at} onRestart={() => undefined} />)),
  ).toContain("Can't reach the agent service.");
});

test("a handshake that starts after the deadline brings no Reconnecting… back", () => {
  expect(hostRecoveryLine({ relinkingSince: 0, waitingSince: 26_000, now: 27_000 })).toBeUndefined();
  // Nor does a wait that has already reached it (the waiting line shows), or none at all.
  expect(hostRecoveryLine({ relinkingSince: 0, waitingSince: 1_000, now: 26_000 })).toBeUndefined();
  expect(hostRecoveryLine({ relinkingSince: 0, now: 25_000 })).toBeUndefined();
  // While the handshake that began under the line still waits short of the deadline, the line stays.
  expect(hostRecoveryLine({ relinkingSince: 0, waitingSince: 1_000, now: 25_500 })).toEqual({ kind: "reconnecting" });
});

test("the restoring line ticks in the fixed-width clock; the waiting line has no timer", () => {
  const waiting = renderToStaticMarkup(<HostWaitingLine since={0} now={27_000} onRestart={() => undefined} />);
  expect(waiting).not.toContain("ui-clock");
  const restoring = renderToStaticMarkup(<HostRecoveringLine restoring={{ waitedMs: 12_000, at: 0 }} now={3_000} />);
  expect(restoring).toMatch(/<span class="ui-clock" data-clock-size="0:00">0:15<\/span>/);
  // The words around the clock are the catalog's, in order.
  expect(text(waiting)).toBe("Can't reach the agent service.Restart agent service");
  expect(text(restoring)).toContain("Restoring sessions… 0:15");
});
