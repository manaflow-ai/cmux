// l10n-allow-file: assertions on the English catalog's words.
// The host's lines above the composer while the pane gets acpmux back (HostError.tsx), second by second:
// - Nothing is drawn while the pane gets its chat back by itself, however long (Leo, 2026-11-22: "i
//   dont wanna see reconnecting to the Mac in a toast, i want it to just connect"): no
//   "Reconnecting…", no "Restoring sessions…". Only the waiting line with its Restart agent service,
//   past the deadline, ever shows.
// - The ticking `m:ss` of the waiting line is the shared clock (ui/Typography.tsx `Clock`), as wide as
//   the widest time of its shape, so the Restart agent service after it holds still as the seconds tick.
import { expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import { HostUnavailableLine, HostWaitingLine } from "./HostError";
import { HOST_ERROR_DEADLINE_MS } from "./hostRetry";

const text = (markup: string) => markup.replace(/<[^>]+>/g, "");

test("a reconnect the pane makes by itself draws nothing until the waiting line, at any second", () => {
  const waitingSince = 1_200;
  for (let now = 0; now < waitingSince + HOST_ERROR_DEADLINE_MS; now += 250) {
    const line = renderToStaticMarkup(<HostWaitingLine since={waitingSince} now={now} onRestart={() => undefined} />);
    expect(text(line), String(now)).toBe("");
  }
  // The waiting line is what shows once its own wait reaches the deadline.
  const at = waitingSince + HOST_ERROR_DEADLINE_MS;
  expect(
    text(renderToStaticMarkup(<HostWaitingLine since={waitingSince} now={at} onRestart={() => undefined} />)),
  ).toContain("Waiting for the agent service (0:25)");
});

test("a wait with no Restart to offer, and a failure that clears itself, draw nothing however long", () => {
  for (const now of [HOST_ERROR_DEADLINE_MS, 10 * 60_000, 3_600_000])
    expect(renderToStaticMarkup(<HostWaitingLine since={0} now={now} />)).toBe("");
  expect(renderToStaticMarkup(<HostUnavailableLine message="Can't reach walk-remote" selfRetrying />)).toBe("");
  expect(text(renderToStaticMarkup(<HostWaitingLine since={0} now={3_600_000} />))).not.toContain("Reconnecting");
});

test("the waiting line ticks in the fixed-width clock", () => {
  const waiting = renderToStaticMarkup(<HostWaitingLine since={0} now={27_000} onRestart={() => undefined} />);
  expect(waiting).toMatch(/<span class="ui-clock" data-clock-size="0:00">0:27<\/span>/);
  // The words around the clock are the catalog's, in order.
  expect(text(waiting)).toContain("Waiting for the agent service (0:27)");
});
