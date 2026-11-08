// "Post to GitHub" in a review worktree's diff viewer (review from link): the host lists the pull
// request the worktree reviews with its comments, and Post sends every draft as one GitHub review.
// Only the drafts posted and unchanged since leave; a refused post keeps them all and says so; a
// retry after a lost reply reuses the post's opid, so the pull request never gets the review twice.
import { afterAll, beforeAll, beforeEach, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";

const scope = globalThis as Record<string, unknown>;
const keys = [
  "window",
  "document",
  "navigator",
  "HTMLElement",
  "customElements",
  "localStorage",
  "IS_REACT_ACT_ENVIRONMENT",
] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);

beforeAll(() => {
  const { window } = new JSDOM("<!doctype html><div id=root></div>", { url: "http://localhost/" });
  Object.assign(scope, {
    window,
    document: window.document,
    navigator: window.navigator,
    HTMLElement: window.HTMLElement,
    customElements: window.customElements,
    localStorage: window.localStorage,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
});

// An unfinished post outlives its page (in the page's storage): each test starts with none.
beforeEach(() => (scope.localStorage as Storage | undefined)?.clear());

afterAll(() => {
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

type Comment = import("../src/comments/types").DiffCommentRecord;
type Review = import("../src/comments/types").DiffReviewTarget;

const REVIEW: Review = {
  url: "https://github.com/acme/net/pull/482",
  repo: "acme/net",
  number: 482,
  title: "Retry uploads with backoff",
  head: "4f1c2e9",
  base: "9a0b3d1",
};

const comment = (id: string, filePath: string, line: number): Comment => ({
  id,
  filePath,
  side: "additions",
  startLine: line,
  endLine: line,
  lineText: "x",
  message: `fix ${id}`,
  createdAt: "2026-11-07T00:00:00.000Z",
  updatedAt: "2026-11-07T00:00:00.000Z",
});

type Call = { method: string; params: Record<string, unknown>; opid?: string };

/** The page host's comments op, answered by `answer`; every call is recorded. */
async function withHost(answer: (call: Call) => Promise<unknown> | unknown, run: (calls: Call[]) => Promise<void>) {
  const { installPageDiffComments } = await import("../src/comments/bridge");
  const calls: Call[] = [];
  installPageDiffComments({
    call: async (
      _op: string,
      body: { method: string; params: Record<string, unknown> },
      options?: { opid?: string },
    ) => {
      const call = { method: body.method, params: body.params, opid: options?.opid };
      calls.push(call);
      return answer(call);
    },
  } as never);
  try {
    await run(calls);
  } finally {
    installPageDiffComments(null);
  }
}

/** The comments hook on `/repo`, its review loaded as the bootstrap loads it. */
async function mountHook(comments: Comment[], review: Review | null = REVIEW, canPostReview = true) {
  const { createRoot } = await import("react-dom/client");
  const { useDiffComments } = await import("../src/diff-viewer/useDiffComments");
  const { initialAppState } = await import("../src/diff-viewer/state");
  type Hook = ReturnType<typeof useDiffComments>;
  const state = { current: { ...initialAppState({ payload: {} } as never, "ready" as never), comments } };
  const dispatched: Array<{ type: string; ids?: readonly string[] }> = [];
  let hook!: Hook;
  function Probe() {
    hook = useDiffComments({
      bridgeAvailable: true,
      canPostReview,
      canSend: true,
      dispatch: ((action: { type: string; ids?: readonly string[] }) => dispatched.push(action)) as never,
      latestState: state as never,
      repoRoot: "/repo",
    });
    return null;
  }
  const root = createRoot(document.createElement("div"));
  act(() => root.render(<Probe />));
  act(() => hook.onLoaded(comments, review ?? undefined));
  // The load's own replace-comments is the bootstrap's, not the post's.
  dispatched.length = 0;
  return { hook: () => hook, state, dispatched, unmount: () => act(() => root.unmount()) };
}

test("the list carries the pull request a review worktree reviews, and none for an ordinary one", async () => {
  const { listCommentsAndReview, listComments } = await import("../src/comments/bridge");
  let review: unknown = { ...REVIEW, extra: true };
  await withHost(
    () => ({ comments: [comment("c1", "a.ts", 1)], review }),
    async () => {
      const listed = await listCommentsAndReview("/repo");
      expect(listed.comments.map((entry) => entry.id)).toEqual(["c1"]);
      expect(listed.review).toEqual(REVIEW);
      // The older reader still gets just the comments.
      expect((await listComments("/repo")).map((entry) => entry.id)).toEqual(["c1"]);
      review = undefined;
      expect((await listCommentsAndReview("/repo")).review).toBeUndefined();
      // A partial answer is no review target.
      review = { url: REVIEW.url, repo: REVIEW.repo };
      expect((await listCommentsAndReview("/repo")).review).toBeUndefined();
    },
  );
});

test("Post sends every draft as one review and clears only those unchanged since", async () => {
  let finish!: (value: unknown) => void;
  await withHost(
    (call) => (call.method === "comments.post" ? new Promise((resolve) => (finish = resolve)) : {}),
    async (calls) => {
      const probe = await mountHook([comment("c1", "a.ts", 1), comment("c2", "a.ts", 2)]);
      expect(probe.hook().canPost).toBe(true);
      expect(probe.hook().review).toEqual(REVIEW);
      act(() => probe.hook().post());
      expect(probe.hook().postState).toBe("posting");
      expect(calls).toHaveLength(1);
      expect(calls[0]!.method).toBe("comments.post");
      expect(calls[0]!.opid).toBeString();
      expect(calls[0]!.params).toEqual({
        repoRoot: "/repo",
        ids: ["c1", "c2"],
        versions: { c1: "2026-11-07T00:00:00.000Z", c2: "2026-11-07T00:00:00.000Z" },
      });
      // A second press while it is on its way posts nothing more.
      act(() => probe.hook().post());
      expect(calls).toHaveLength(1);
      // c2 is edited while the review is on its way; the host kept it (its version moved on).
      probe.state.current.comments = [
        comment("c1", "a.ts", 1),
        { ...comment("c2", "a.ts", 2), updatedAt: "2026-11-07T00:01:00.000Z" },
      ];
      const url = `${REVIEW.url}#pullrequestreview-1`;
      await act(async () => finish({ url, posted: 1, in_body: 1, cleared: ["c1", "c2"] }));
      expect(probe.dispatched).toEqual([{ type: "remove-comments", ids: ["c1"] }]);
      expect(probe.hook().postState).toBe("posted");
      expect(probe.hook().posted).toEqual({ url, posted: 1, inBody: 1 });
      probe.unmount();
    },
  );
});

test("a refused post keeps the drafts, says why, and its retry reuses the opid", async () => {
  let refuse = true;
  await withHost(
    () => {
      if (refuse) throw Object.assign(new Error("gh: HTTP 401: Bad credentials"), { code: "cmux.diff.post_failed" });
      return { url: `${REVIEW.url}#pullrequestreview-2`, posted: 1, in_body: 0, cleared: ["c1"] };
    },
    async (calls) => {
      const probe = await mountHook([comment("c1", "a.ts", 1)]);
      await act(async () => probe.hook().post());
      expect(probe.hook().postState).toBe("failed");
      expect(probe.hook().postError).toBe("gh: HTTP 401: Bad credentials");
      expect(probe.dispatched).toEqual([]);
      // A draft added before the retry does not change the review GitHub may already have.
      probe.state.current.comments = [...probe.state.current.comments, comment("c2", "b.ts", 2)];
      refuse = false;
      await act(async () => probe.hook().post());
      expect(probe.hook().postState).toBe("posted");
      expect(probe.hook().postError).toBeUndefined();
      expect(calls).toHaveLength(2);
      expect(calls[1]!.opid).toBe(calls[0]!.opid!);
      expect(calls[1]!.params.ids).toEqual(["c1"]);
      expect(probe.dispatched).toEqual([{ type: "remove-comments", ids: ["c1"] }]);
      // The next post is a new review: a new opid.
      await act(async () => probe.hook().post());
      expect(calls[2]!.opid).not.toBe(calls[0]!.opid!);
      probe.unmount();
    },
  );
});

test("a draft edited after an uncertain post is retried under that post's opid and kept", async () => {
  let refuse = true;
  await withHost(
    () => {
      if (refuse) throw new Error("the session host did not answer");
      // The host found the first post's review by its marker: nothing was posted again or cleared.
      return { url: `${REVIEW.url}#pullrequestreview-2`, posted: 0, in_body: 0, cleared: [] };
    },
    async (calls) => {
      const probe = await mountHook([comment("c1", "a.ts", 1)]);
      await act(async () => probe.hook().post());
      expect(probe.hook().postState).toBe("failed");
      probe.state.current.comments = [{ ...comment("c1", "a.ts", 1), updatedAt: "2026-11-07T00:05:00.000Z" }];
      refuse = false;
      await act(async () => probe.hook().post());
      expect(calls[1]!.opid).toBe(calls[0]!.opid!);
      expect(calls[1]!.params.versions).toEqual(calls[0]!.params.versions);
      expect(probe.dispatched).toEqual([]);
      probe.unmount();
    },
  );
});

test("a retry the host says never reached GitHub posts the edited drafts as a new review", async () => {
  const refusal = (reason: string, message: string) =>
    Object.assign(new Error("operation.failed"), {
      code: "operation.failed",
      details: { operation: "git.review.post", reason, extra: { message } },
    });
  let answers = 0;
  await withHost(
    () => {
      answers += 1;
      if (answers === 1) throw refusal("gh_failed", "gh: HTTP 401: Bad credentials");
      if (answers === 2) throw refusal("nothing_to_post", "none of the named drafts is still listed unchanged");
      return { url: `${REVIEW.url}#pullrequestreview-3`, posted: 1, in_body: 0, cleared: ["c1"] };
    },
    async (calls) => {
      const probe = await mountHook([comment("c1", "a.ts", 1)]);
      await act(async () => probe.hook().post());
      // The session host's own words, not its code.
      expect(probe.hook().postError).toBe("gh: HTTP 401: Bad credentials");
      const edited = { ...comment("c1", "a.ts", 1), updatedAt: "2026-11-07T00:05:00.000Z" };
      probe.state.current.comments = [edited];
      await act(async () => probe.hook().post());
      // The refusal, then the new review: two answers.
      await act(async () => {});
      expect(calls).toHaveLength(3);
      expect(calls[1]!.opid).toBe(calls[0]!.opid!);
      expect(calls[2]!.opid).not.toBe(calls[0]!.opid!);
      expect(calls[2]!.params.versions).toEqual({ c1: edited.updatedAt });
      expect(probe.hook().postState).toBe("posted");
      expect(probe.dispatched).toEqual([{ type: "remove-comments", ids: ["c1"] }]);
      probe.unmount();
    },
  );
});

test("a page reopened after a lost reply posts the same drafts under the same opid", async () => {
  await withHost(
    () => {
      throw new Error("the session host did not answer");
    },
    async (calls) => {
      const first = await mountHook([comment("c1", "a.ts", 1), comment("c2", "a.ts", 2)]);
      await act(async () => first.hook().post());
      first.unmount();
      const reopened = await mountHook([comment("c2", "a.ts", 2), comment("c1", "a.ts", 1)]);
      await act(async () => reopened.hook().post());
      expect(calls[1]!.opid).toBe(calls[0]!.opid!);
      reopened.unmount();
      // A draft added before the page opened again waits: the unfinished post goes first, as it was.
      const added = await mountHook([
        comment("c1", "a.ts", 1),
        comment("c2", "a.ts", 2),
        comment("c3", "b.ts", 3),
      ]);
      await act(async () => added.hook().post());
      expect(calls[2]!.opid).toBe(calls[0]!.opid!);
      expect(calls[2]!.params.ids).toEqual(["c1", "c2"]);
      added.unmount();
    },
  );
});

test("a draft edited after a post stops the header saying it posted", async () => {
  await withHost(
    (call) =>
      call.method === "comments.post"
        ? { url: `${REVIEW.url}#pullrequestreview-4`, posted: 1, in_body: 0, cleared: [] }
        : { comment: call.params.comment },
    async () => {
      const probe = await mountHook([comment("c1", "a.ts", 1)]);
      await act(async () => probe.hook().post());
      expect(probe.hook().postState).toBe("posted");
      await act(async () => probe.hook().editMessage(comment("c1", "a.ts", 1), "fix it now", null));
      expect(probe.hook().postState).toBe("idle");
      probe.unmount();
    },
  );
});

test("Post waits for an edit still being saved, so the review never has the older wording", async () => {
  let release!: () => void;
  const held = new Promise<void>((resolve) => (release = resolve));
  await withHost(
    async (call) => {
      if (call.method === "comments.save") {
        await held;
        return { comment: call.params.comment };
      }
      return { url: `${REVIEW.url}#pullrequestreview-5`, posted: 1, in_body: 0, cleared: [] };
    },
    async (calls) => {
      const probe = await mountHook([comment("c1", "a.ts", 1)]);
      act(() => probe.hook().editMessage(comment("c1", "a.ts", 1), "fix it now", null));
      act(() => probe.hook().post());
      await act(async () => await Promise.resolve());
      expect(calls.map((call) => call.method)).toEqual(["comments.save"]);
      expect(probe.hook().postState).toBe("posting");
      await act(async () => {
        release();
        await held;
        await new Promise((resolve) => setTimeout(resolve, 0));
      });
      expect(calls.map((call) => call.method)).toEqual(["comments.save", "comments.post"]);
      probe.unmount();
    },
  );
});

test("a review on another machine shows no Post: only this Mac's daemon takes the person's post", async () => {
  await withHost(
    () => ({}),
    async (calls) => {
      const probe = await mountHook([comment("c1", "a.ts", 1)], REVIEW, false);
      expect(probe.hook().canPost).toBe(false);
      probe.unmount();
      expect(calls).toEqual([]);
    },
  );
});

test("an ordinary worktree cannot post", async () => {
  await withHost(
    () => ({}),
    async (calls) => {
      const probe = await mountHook([comment("c1", "a.ts", 1)], null);
      expect(probe.hook().canPost).toBe(false);
      act(() => probe.hook().post());
      expect(calls).toEqual([]);
      probe.unmount();
    },
  );
});

test("the header posts to GitHub and names the pull request only for a review worktree", async () => {
  const { createRoot } = await import("react-dom/client");
  const { CommentsSidebarSection } = await import("../src/comments/CommentsSection");
  const { resolveCommentLabels } = await import("../src/comments/labels");
  const labels = resolveCommentLabels(undefined);
  const entries = [comment("c1", "a.ts", 1)].map((entry) => ({
    comment: entry,
    anchor: { state: "anchored" as const, line: entry.endLine },
    pending: false,
    itemId: entry.filePath,
  }));
  const host = document.createElement("div");
  const root = createRoot(host);
  const render = (props: Partial<Parameters<typeof CommentsSidebarSection>[0]>) =>
    act(() =>
      root.render(
        <CommentsSidebarSection
          entries={entries}
          hasDraft={false}
          labels={labels}
          onSelect={() => {}}
          onSend={() => {}}
          {...props}
        />,
      ),
    );

  render({});
  expect(host.querySelector("#comments-post")).toBeNull();
  expect(host.querySelector("#comments-review")).toBeNull();
  expect(host.querySelector("#comments-header #comments-send")?.className).toContain("comment-button-primary");

  render({ review: REVIEW, onPost: () => {}, postState: "idle" });
  const post = host.querySelector<HTMLButtonElement>("#comments-header #comments-post")!;
  expect(post.textContent).toContain("Post to GitHub");
  // Both labels share one cell, so the button keeps its width while posting.
  expect([...post.children].map((label) => label.getAttribute("aria-hidden"))).toEqual(["false", "true"]);
  const link = host.querySelector<HTMLAnchorElement>("#comments-review-link")!;
  expect(link.textContent).toBe("Reviewing acme/net#482");
  expect(link.href).toBe(REVIEW.url);
  // Send to agent stays, quieter, on the pull request's line.
  const send = host.querySelector("#comments-review #comments-send")!;
  expect(send.className).not.toContain("comment-button-primary");

  render({ review: REVIEW, onPost: () => {}, postState: "posting" });
  expect(host.querySelector<HTMLButtonElement>("#comments-post")!.disabled).toBe(true);
  expect([...host.querySelector("#comments-post")!.children].map((label) => label.getAttribute("aria-hidden"))).toEqual(
    ["true", "false"],
  );

  render({ review: REVIEW, onPost: () => {}, postState: "failed", postError: "HTTP 422" });
  expect(host.querySelector("#comments-post-error")?.textContent).toBe("Not posted. Your drafts are kept.HTTP 422");
  expect(host.querySelectorAll(".comment-entry")).toHaveLength(1);

  // Posted, with every draft gone: the section stays and its line links the posted review.
  const url = `${REVIEW.url}#pullrequestreview-1`;
  act(() =>
    root.render(
      <CommentsSidebarSection
        entries={[]}
        hasDraft={false}
        labels={labels}
        onSelect={() => {}}
        review={REVIEW}
        onPost={() => {}}
        postState="posted"
        posted={{ url, posted: 1, inBody: 0 }}
      />,
    ),
  );
  const posted = host.querySelector<HTMLAnchorElement>("#comments-review-link")!;
  expect(posted.textContent).toBe("Posted to acme/net#482");
  expect(posted.href).toBe(url);
  expect(host.querySelector<HTMLButtonElement>("#comments-post")!.disabled).toBe(true);
  act(() => root.unmount());
});
