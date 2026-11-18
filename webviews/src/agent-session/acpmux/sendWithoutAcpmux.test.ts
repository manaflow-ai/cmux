// A send made while the page still connects waits in the pane for acpmux (sendWhenReady.ts
// `untilAcpmuxTakesSends`). When the host then answers that this page has no acpmux to reach (a
// preview host), none will ever come: each waiting send comes back to the composer, in the order
// they were sent, with its files and why (cmux#45759 follow-up F3). Before, they waited forever.
import { afterEach, expect, test } from "bun:test";
import type { ComposerAttachment } from "./attachments";
import { acpmuxMayCome, noAcpmuxForSends, untilAcpmuxTakesSends } from "./sendWhenReady";
import { StartingSends } from "./startingSends";

afterEach(() => acpmuxMayCome());

type Page = { cmuxAcpmuxActions?: Record<string, unknown> };

function harness(page: Page) {
  const given: { text: string; attachments: string[]; why?: string }[] = [];
  const sent: string[] = [];
  const sends = new StartingSends(
    () => undefined,
    (text, attachments, error) =>
      given.push({
        text,
        attachments: attachments.map((chip) => chip.path ?? chip.name),
        ...(error ? { why: (error as Error).message } : {}),
      }),
    () => ({ chat: "chat", visit: 1 }),
  );
  const go = async (text: string) => {
    await untilAcpmuxTakesSends(page);
    sent.push(text);
  };
  const settle = async () => {
    for (let i = 0; i < 20; i++) await Promise.resolve();
  };
  return { sends, given, sent, go, settle };
}

test("sends waiting for acpmux come back in order, with why, once the host says none comes", async () => {
  const page: Page = {};
  const h = harness(page);
  h.sends.add("first", [], h.go, undefined, "first", { asSent: true });
  h.sends.add("second", [], h.go, undefined, "second", { asSent: true });
  await h.settle();
  expect(h.given).toEqual([]);
  noAcpmuxForSends(new Error("Not sent: Can't reach the agent service."));
  await h.settle();
  expect(h.sent).toEqual([]);
  // Each goes back before what the composer holds: the last first, so they read first, second.
  expect(h.given).toEqual([
    { text: "second", attachments: [] },
    { text: "first", attachments: [], why: "Not sent: Can't reach the agent service." },
  ]);
  expect(h.sends.busy).toBe(false);
});

test("a send still waiting for its files when the host says no acpmux comes is refused once they are made", async () => {
  const page: Page = {};
  const h = harness(page);
  let made!: (chips: ComposerAttachment[]) => void;
  const ready = new Promise<ComposerAttachment[]>((resolve) => (made = resolve));
  const standIn = { id: "rec", kind: "link", name: "rec.mov", mimeType: "", size: 0 } as ComposerAttachment;
  h.sends.add("with a file", [standIn], h.go, undefined, "file", { ready, asSent: true });
  await h.settle();
  noAcpmuxForSends(new Error("Not sent: Can't reach the agent service."));
  await h.settle();
  made([{ ...standIn, path: "/up/rec.mov", size: 7 }]);
  await h.settle();
  expect(h.sent).toEqual([]);
  expect(h.given).toEqual([
    { text: "with a file", attachments: ["/up/rec.mov"], why: "Not sent: Can't reach the agent service." },
  ]);
});

test("once a later handshake may bring acpmux, a send waits for it again and goes when it connects", async () => {
  const page: Page = {};
  const h = harness(page);
  noAcpmuxForSends(new Error("Not sent: Can't reach the agent service."));
  acpmuxMayCome();
  h.sends.add("later", [], h.go, undefined, "later", { asSent: true });
  await h.settle();
  expect(h.given).toEqual([]);
  page.cmuxAcpmuxActions = { "chat.send": () => Promise.resolve() };
  const { acpmuxSendsReady } = await import("./sendWhenReady");
  acpmuxSendsReady();
  await h.settle();
  expect(h.sent).toEqual(["later"]);
});
