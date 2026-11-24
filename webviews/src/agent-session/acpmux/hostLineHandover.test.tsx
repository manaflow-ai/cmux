// l10n-allow-file: assertions on the English catalog's words.
// The host's lines above the composer while the pane gets acpmux back (HostError.tsx), second by second:
// - An automatic reconnect or restore draws nothing; "Waiting for the agent service (m:ss)" is the first
//   line, once the handshake's wait reaches the deadline.
// - The ticking `m:ss` of the waiting line is the shared clock
//   (ui/Typography.tsx `Clock`), as wide as the widest time of its shape, so the Restart agent service
//   after it holds still as the seconds tick.
import { expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import { HostRecoveringLine, HostWaitingLine } from "./HostError";
import { HOST_ERROR_DEADLINE_MS, hostRecoveryLine } from "./hostRetry";

const text = (markup: string) => markup.replace(/<[^>]+>/g, "");

// Leo, 2026-11-16: "pls no messages like this :(". An automatic reconnect draws nothing on the chat;
// the waiting line, which has the person's one action (Restart agent service), is the first thing shown.
test("an automatic reconnect draws nothing until the waiting line shows", () => {
  // The drop at 0; the first handshake, whose wait the waiting line counts, starts 1.2 s later.
  const relinkingSince = 0;
  const waitingSince = 1_200;
  const at = waitingSince + HOST_ERROR_DEADLINE_MS;
  for (let now = 10_000; now <= 40_000; now += 250) {
    const line = renderToStaticMarkup(
      <HostRecoveringLine
        relinkingSince={relinkingSince}
        waitingSince={waitingSince}
        now={now}
        otherwise={<HostWaitingLine since={waitingSince} now={now} onRestart={() => undefined} />}
      />,
    );
    expect(text(line)).not.toContain("Reconnecting");
    if (now < at) expect(text(line).trim()).toBe("");
    else expect(text(line)).toContain("Waiting for the agent service");
  }
  expect(
    text(renderToStaticMarkup(<HostWaitingLine since={waitingSince} now={at} onRestart={() => undefined} />)),
  ).toContain("Waiting for the agent service (0:25)");
});

test("a handshake that starts after the deadline brings no Reconnecting… back", () => {
  expect(hostRecoveryLine({ relinkingSince: 0, waitingSince: 26_000, now: 27_000 })).toBeUndefined();
  // Nor does a wait that has already reached it (the waiting line shows), or none at all.
  expect(hostRecoveryLine({ relinkingSince: 0, waitingSince: 1_000, now: 26_000 })).toBeUndefined();
  expect(hostRecoveryLine({ relinkingSince: 0, now: 25_000 })).toBeUndefined();
  // While the handshake that began under the line still waits short of the deadline, the line stays.
  expect(hostRecoveryLine({ relinkingSince: 0, waitingSince: 1_000, now: 25_500 })).toEqual({ kind: "reconnecting" });
});

test("the waiting line ticks in the fixed-width clock; a restore draws nothing", () => {
  const waiting = renderToStaticMarkup(<HostWaitingLine since={0} now={27_000} onRestart={() => undefined} />);
  expect(waiting).toMatch(/<span class="ui-clock" data-clock-size="0:00">0:27<\/span>/);
  // The words around the clock are the catalog's, in order.
  expect(text(waiting)).toContain("Waiting for the agent service (0:27)");
  // A restore the host reports draws nothing either: the chat comes back by itself.
  expect(renderToStaticMarkup(<HostRecoveringLine restoring={{ waitedMs: 12_000, at: 0 }} now={3_000} />)).toBe("");
});
