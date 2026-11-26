import { describe, expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import { JSDOM } from "jsdom";
import { runBoardFixture } from "./fixtures";
import { RunBoard } from "./RunBoard";
import { CompareRunBoard } from "./variants/compare/CompareRunBoard";
import { TimelineRunBoard } from "./variants/timeline/TimelineRunBoard";
import { RunApiHttpError } from "./runApi";
import { attachFailureState, attachTicketExpired, attachWithFreshTicket } from "./runBoardModel";

describe("Run board attach bridge", () => {
  test("classifies expired and replayed one-use tickets for clear retry copy", () => {
    expect(attachFailureState(new RunApiHttpError(410, "expired", "run_attach_expired"))).toBe("expired");
    expect(attachFailureState(new RunApiHttpError(409, "already consumed", "run_attach_replayed"))).toBe("replayed");
    expect(attachFailureState(new Error("bridge unavailable"))).toBe("error");
  });

  test("checks both ISO and Unix expiry forms before handing a ticket to the host", () => {
    const now = Date.parse("2026-10-16T20:00:00.000Z");
    expect(
      attachTicketExpired(
        { runId: "r", attemptId: "a", sessionId: "s", cursor: "1", expiresAt: "2026-10-16T19:59:59.000Z" },
        now,
      ),
    ).toBe(true);
    expect(
      attachTicketExpired(
        { runId: "r", attemptId: "a", sessionId: "s", cursor: "1", expiresAtUnix: now / 1000 + 60 },
        now,
      ),
    ).toBe(false);
    expect(attachTicketExpired({ runId: "r", attemptId: "a", sessionId: "s", cursor: "1" }, now)).toBe(false);
  });
});

test("all Run Board views count project-relative changed files without cwd metadata", () => {
  for (const [Board, selector] of [
    [RunBoard, ".run-board-attempt"],
    [CompareRunBoard, ".compare-candidate"],
    [TimelineRunBoard, ".timeline-filmstrip-item"],
  ] as const) {
    const dom = new JSDOM(renderToStaticMarkup(<Board snapshot={runBoardFixture} recovered={runBoardFixture} />));
    try {
      const cards = [...dom.window.document.querySelectorAll(selector)];
      expect(cards).toHaveLength(runBoardFixture.attempts.length);
      for (const card of cards) expect(card.textContent).toContain("2 files");
    } finally {
      dom.window.close();
    }
  }
});

describe("Run board attach asks for a fresh ticket on its own", () => {
  const now = () => Date.parse("2026-10-16T20:00:00.000Z");
  const ticket = (n: number, expiresAtUnix: number) => ({
    runId: "r",
    attemptId: "a",
    sessionId: "s",
    cursor: `${n}`,
    expiresAtUnix,
  });

  test("an expired ticket is replaced once on the same click, and the fresh one opens", async () => {
    const asked = [ticket(1, now() / 1000 - 1), ticket(2, now() / 1000 + 60)];
    const opened: string[] = [];
    const got = await attachWithFreshTicket(
      async () => asked.shift(),
      async (t) => void opened.push(t.cursor),
      now,
    );
    expect(got?.cursor).toBe("2");
    expect(opened).toEqual(["2"]);
  });

  test("a used ticket the host refuses is replaced once; any other failure is not asked again", async () => {
    let opens = 0;
    const used = async () => {
      opens++;
      if (opens === 1) throw new RunApiHttpError(409, "already consumed", "run_attach_replayed");
    };
    expect((await attachWithFreshTicket(async () => ticket(1, now() / 1000 + 60), used, now))?.cursor).toBe("1");
    expect(opens).toBe(2);
    let requests = 0;
    const broken = attachWithFreshTicket(
      async () => {
        requests++;
        throw new Error("bridge unavailable");
      },
      async () => {},
      now,
    );
    await expect(broken).rejects.toThrow("bridge unavailable");
    expect(requests).toBe(1);
  });
});
