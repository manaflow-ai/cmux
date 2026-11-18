import { expect, test } from "bun:test";
import { prFeedbackDispatcher, prFeedbackKinds, pullRequestReference, type PrFeedbackKind } from "./prFeedback";

const URL = "https://github.com/example/project/pull/42";

test("Fix Failing Checks needs a red of the branch's own; Send Review Comments any open pull request", () => {
  // Three red, one of them red on base too: two are the branch's own.
  expect(prFeedbackKinds(false, 3, 1)).toEqual(["checks", "comments"]);
  // Every red also fails on base: nothing of its own to fix.
  expect(prFeedbackKinds(false, 2, 2)).toEqual(["comments"]);
  expect(prFeedbackKinds(false, 0, 0)).toEqual(["comments"]);
  // Failing with no count read yet: offered.
  expect(prFeedbackKinds(false, -1, 0)).toEqual(["checks", "comments"]);
  // Merged or closed: neither.
  expect(prFeedbackKinds(true, 3, 0)).toEqual([]);
});

test("a pull request's reference is owner/repo#N, else its address", () => {
  expect(pullRequestReference(URL)).toBe("example/project#42");
  expect(pullRequestReference(`${URL}/files`)).toBe("example/project#42");
  expect(pullRequestReference("https://example.com/x")).toBe("https://example.com/x");
});

function harness(answer: (url: string, kind: PrFeedbackKind) => Promise<unknown>, shown = () => true) {
  const calls: string[] = [];
  const asked: string[] = [];
  const draft = prFeedbackDispatcher({
    request: (url, kind) => {
      asked.push(`${kind} ${url}`);
      return { answer: answer(url, kind), stillShown: shown };
    },
    quote: (markdown) => calls.push(`quote:${markdown}`),
    notice: (text) => calls.push(`notice:${text}`),
    failed: (text) => calls.push(`failed:${text}`),
  });
  return { draft, calls, asked };
}

test("a message goes into the composer, unsent; an empty answer and a failure are toasts", async () => {
  const message = "Fix the failing checks of example/project#42:\n\n- lint";
  const ok = harness(async () => ({ draft: message, empty: false, kind: "checks" }));
  await ok.draft(URL, "checks");
  expect(ok.calls).toEqual([`quote:${message}`]);

  const empty = harness(async () => ({
    draft: "No failing checks of this branch's own: 2 also fail on base",
    empty: true,
  }));
  await empty.draft(URL, "checks");
  expect(empty.calls).toEqual(["notice:No failing checks of this branch's own: 2 also fail on base"]);

  const refused = harness(() => Promise.reject(new Error("gh: not signed in")));
  await refused.draft(URL, "comments");
  expect(refused.calls).toEqual(["failed:Could not read example/project#42: gh: not signed in"]);

  // An answer with no message is a failure, never an empty quote.
  const blank = harness(async () => ({ empty: false }));
  await blank.draft(URL, "comments");
  expect(blank.calls).toHaveLength(1);
  expect(blank.calls[0]).toStartWith("failed:Could not read example/project#42: ");
});

test("a second click on the same item does nothing until its request settles", async () => {
  const settle: ((value: unknown) => void)[] = [];
  const { draft, calls, asked } = harness(() => new Promise((resolve) => settle.push(resolve)));
  const first = draft(URL, "checks");
  expect(draft(URL, "checks")).toBeUndefined();
  // The other item, or another pull request, is its own request.
  expect(draft(URL, "comments")).toBeDefined();
  expect(asked).toEqual([`checks ${URL}`, `comments ${URL}`]);
  settle[0]!({ draft: "go", empty: false });
  await first;
  expect(calls).toEqual(["quote:go"]);
  expect(draft(URL, "checks")).toBeDefined();
  expect(asked).toHaveLength(3);
});

test("a message for a chat the person left while it was read is dropped", async () => {
  let shown = true;
  const left = harness(
    async () => ({ draft: "Fix it", empty: false }),
    () => shown,
  );
  const settled = left.draft(URL, "checks");
  shown = false;
  await settled;
  expect(left.calls).toEqual([]);
});
