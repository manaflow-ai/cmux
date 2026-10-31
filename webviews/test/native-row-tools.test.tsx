// l10n-allow-file: native toolbar descriptors and synthetic test labels, not shipped UI.
import { afterEach, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act, type ComponentProps } from "react";
import { readFileSync } from "node:fs";
import type { HeaderPullRequest } from "../src/agent-session/acpmux/header/headerState";
import type { NativeRowMenuItem } from "../src/agent-session/acpmux/header/nativeRowTools";
import { createRoot, type Root } from "react-dom/client";
import { ChatHeaderTools } from "../src/agent-session/acpmux/header/ChatHeaderTools";
import { HEADER_ACTIONS } from "../src/agent-session/acpmux/header/headerActions";
import { headerQuickTools, type HeaderQuickToolsInput } from "../src/agent-session/acpmux/header/headerQuickTools";
import { headerState, setHeaderState } from "../src/agent-session/acpmux/header/headerState";
import {
  dispatchNativeRowTool,
  nativeRowToolBindings,
  boundedNativeText,
  nativeVisibleText,
  NATIVE_MAX_VISIBLE_TEXT_GRAPHEMES,
  NATIVE_MAX_VISIBLE_TEXT_BYTES,
  NATIVE_MAX_URL_BYTES,
  NATIVE_MAX_TOOLS,
  NATIVE_MAX_MENU_ITEMS,
  NATIVE_MAX_DEPTH,
  NATIVE_MAX_TOTAL_MENU_ITEMS,
  NATIVE_MAX_TEXT_BYTES,
  NATIVE_MAX_TEXT_GRAPHEMES,
  type NativeRowTool,
} from "../src/agent-session/acpmux/header/nativeRowTools";
import { configureQuickActions, quickActions } from "../src/agent-session/acpmux/header/quickActions";
import { setTabRow, useTabRow, type TabRow } from "../src/agent-session/acpmux/header/tabRow";
import { useNativeRowTools } from "../src/agent-session/acpmux/header/useNativeRowTools";
import { NeedsYouButton } from "../src/agent-session/acpmux/needsYou/NeedsYou";
import { applyHostEvent } from "../src/agent-session/acpmux/pageHost";
import { translate } from "../src/agent-session/acpmux/i18n";
import { openPicker } from "../src/agent-session/acpmux/pickerOpeners";
import { SummaryButton } from "../src/agent-session/acpmux/summary/SummaryButton";

function deferred<T = unknown>() {
  let resolve!: (value: T) => void;
  let reject!: (error: unknown) => void;
  const promise = new Promise<T>((yes, no) => {
    resolve = yes;
    reject = no;
  });
  return { promise, resolve, reject };
}
const request = (number: number): HeaderPullRequest => ({
  url: `https://github.com/example/repo/pull/${number}`,
  number,
  title: "Fix",
  state: "open",
  review: "approved",
  mergeable: "mergeable",
  checks: { state: "passing", passed: 2, total: 2 },
  checkList: [],
});
const ask = (id: string, text = "Approve?") => ({
  id,
  kind: "approval" as const,
  sessionId: "chat",
  permissionId: id,
  ask: text,
  who: { name: "A", chief: false },
  answers: [{ id: "yes", label: "Allow", tone: "allow" as const }],
});
const flatten = (menu: readonly NativeRowMenuItem[]): NativeRowMenuItem[] =>
  menu.flatMap((item) => [item, ...flatten(item.children ?? [])]);
function nativeHarness() {
  const container = mount();
  let tools: NativeRowTool[] = [];
  const sent: string[] = [];
  const host = {
    enabled: true,
    callNative: async (_method: string, params: Record<string, unknown>) => {
      tools = params.tools as NativeRowTool[];
      sent.push(JSON.stringify(tools));
    },
  };
  const render = async (props: Partial<ComponentProps<typeof ChatHeaderTools>> = {}) => {
    const nativeNeedsYou = props.nativeNeedsYou ? { ...props.nativeNeedsYou, nativeMenu: true } : undefined;
    await act(async () =>
      root!.render(
        <ChatHeaderTools
          onTerminal={() => {}}
          onBrowser={() => {}}
          summary={null}
          menu={() => []}
          nativeRowTools={host}
          {...props}
          nativeNeedsYou={nativeNeedsYou}
        />,
      ),
    );
  };
  const tool = (id: string) => {
    const found = tools.find((item) => item.id === id);
    expect(found).toBeDefined();
    return found!;
  };
  const row = (id: string, prefix: string) => {
    const found = flatten(tool(id).menu ?? []).find((item) => item.id.startsWith(prefix));
    expect(found).toBeDefined();
    return found!;
  };
  const invoke = (id: string, menuItemId: string) =>
    applyHostEvent({ kind: "tabRowToolInvoked", value: { id, menuItemId } });
  const click = async (id: string, prefix: string) => {
    const item = row(id, prefix);
    await act(async () => invoke(id, item.id));
    return item.id;
  };
  return { container, render, tool, row, invoke, click, sent };
}

test("a native worktree without mutation handlers opens its informational menu", async () => {
  const h = nativeHarness();
  await h.render({
    folder: "/worktrees/new-chat",
    readStatus: async () => ({ branch: "feature", base: "main", worktree: { main_root: "/repo" } }),
  });
  const tool = h.tool("worktree");
  expect(tool.enabled).toBe(true);
  expect(tool.menu).toContainEqual(expect.objectContaining({ label: "feature", enabled: false }));
  expect(tool.menu).toContainEqual(
    expect.objectContaining({
      label: translate("header.worktreeFrom", { main: "/repo", base: "main" }),
      enabled: false,
    }),
  );
  expect(tool.menu!.every((item) => !item.enabled)).toBe(true);
});

test("native worktree and PR visible text use the text track, leaving count badges free", async () => {
  const h = nativeHarness();
  await act(async () => setHeaderState({ pullRequest: request(7) }));
  await h.render({
    folder: "/worktrees/text",
    readStatus: async () => ({ branch: "feature/login", worktree: { main_root: "/repo" } }),
  });
  expect(h.tool("worktree").text).toBe("feature/login");
  expect(h.tool("pullRequest").text).toBe("#7 ✓2/2");
  expect(h.tool("worktree").badge).toBeUndefined();
  expect(h.tool("pullRequest").badge).toBeUndefined();
  const segmenter = new Intl.Segmenter(undefined, { granularity: "grapheme" });
  for (const input of [
    "",
    "x".repeat(33),
    "feature/" + "x".repeat(64) + "/login",
    "👨‍👩‍👧‍👦".repeat(32),
    "branch\nname\rwith\u2028break",
  ]) {
    const text = nativeVisibleText(input);
    expect(text.length).toBeGreaterThan(0);
    expect(Array.from(segmenter.segment(text)).length).toBeLessThanOrEqual(32);
    expect(new TextEncoder().encode(text).length).toBeLessThanOrEqual(128);
    expect(text).not.toMatch(/[\r\n\v\f\u0085\u2028\u2029]/);
  }
  expect(nativeVisibleText("x".repeat(32))).toBe("x".repeat(32));
  expect(nativeVisibleText("feature/" + "x".repeat(64) + "/login")).toMatch(/^feature\/.*….*\/login$/);
});

test("native PR links are host-owned URLs; host invocation never opens them again in the page", async () => {
  const h = nativeHarness();
  const opened: string[] = [];
  dom!.window.open = ((url: string) => {
    opened.push(url);
    return null;
  }) as Window["open"];
  const valid = [
    "https://example.test/pr/7",
    "https://example.test/" + "a".repeat(NATIVE_MAX_URL_BYTES - "https://example.test/".length),
  ];
  const invalid = [
    "javascript:alert(1)",
    "file:///tmp/a",
    "not a URL",
    "https://example.test/" + "a".repeat(NATIVE_MAX_URL_BYTES),
  ];
  for (const url of ["http://example.test/check", ...valid, ...invalid]) {
    const [binding] = nativeRowToolBindings([], undefined, {
      pullRequest: {
        value: { ...request(7), url, checkList: [{ name: "Build", state: "passed", url }] },
        ops: { identity: "pr", merging: { step: "idle" }, messages: [] },
      },
    });
    for (const row of binding!.tool.menu!) {
      expect(row.url).toBe(invalid.includes(url) ? undefined : url);
      expect(row.enabled).toBe(!invalid.includes(url));
      expect(binding!.menuRuns?.has(row.id)).toBe(false);
    }
  }
  for (const url of [...valid, ...invalid]) {
    const prURL = valid.includes(url) ? url : request(7).url;
    await act(async () =>
      setHeaderState({
        pullRequest: { ...request(7), url: prURL, checkList: [{ name: "Build", state: "passed", url }] },
      }),
    );
    await h.render();
    for (const prefix of ["pullRequest.open:", "pullRequest.check:"]) {
      const row = h.row("pullRequest", prefix);
      const expected = prefix === "pullRequest.open:" ? prURL : valid.includes(url) ? url : undefined;
      expect(row.enabled).toBe(!!expected);
      expect(row.url).toBe(expected);
      await act(async () => h.invoke("pullRequest", row.id));
    }
  }
  expect(opened).toEqual([]);
});

test("native and DOM PR labels retain aggregate failure and pending state without failed check rows", async () => {
  const h = nativeHarness();
  await h.render();
  for (const state of ["failing", "pending"]) {
    for (const total of [0, 2]) {
      for (const checkList of [[], [{ name: "Only returned check", state: "passed" }]]) {
        await act(async () =>
          setHeaderState({ pullRequest: { ...request(7), checks: { state, passed: total, total }, checkList } }),
        );
        const status = translate(state === "failing" ? "rail.checksFailing" : "rail.checksPending");
        expect(h.tool("pullRequest").label).toContain(status);
        await h.render({ nativeRowTools: { enabled: false, callNative: async () => {} } });
        expect(h.container.querySelector(".acpmux-header-pr")?.getAttribute("aria-label")).toContain(status);
        await h.render();
      }
    }
  }
});

test("native worktree uses the DOM refusal, retry, exclusion and removed state machine", async () => {
  const h = nativeHarness();
  const removes: { key: string; discard: boolean; reply: ReturnType<typeof deferred> }[] = [];
  const applies: { key: string; reply: ReturnType<typeof deferred> }[] = [];
  const props = {
    folder: "/worktrees/ops",
    readStatus: async () => ({ branch: "feature", base: "main", worktree: { main_root: "/repo" } }),
    onRemoveWorktree: (key: string, discard: boolean) => {
      const reply = deferred();
      removes.push({ key, discard, reply });
      return reply.promise;
    },
    onApplyWorktree: (key: string) => {
      const reply = deferred();
      applies.push({ key, reply });
      return reply.promise;
    },
  };
  await h.render(props);
  expect(h.tool("worktree").text).toBe("feature");
  const applyId = h.row("worktree", "worktree.apply:").id;
  await act(async () => {
    h.invoke("worktree", h.row("worktree", "worktree.remove:").id);
    h.invoke("worktree", applyId);
  });
  expect(removes).toHaveLength(1);
  expect(applies).toHaveLength(0);
  expect(h.row("worktree", "worktree.apply:").enabled).toBe(false);
  await act(async () => removes[0]!.reply.reject({ details: { reason: "uncommitted_changes" } }));
  expect(h.row("worktree", "worktree.removeAnyway:").label).toBe(translate("header.worktreeRemoveAnyway"));
  expect(h.tool("worktree").menu).toContainEqual(
    expect.objectContaining({ label: translate("header.worktreeRemoveUncommittedAny"), enabled: false }),
  );
  await h.click("worktree", "worktree.removeAnyway:");
  expect(removes[1]!.discard).toBe(true);
  expect(removes[1]!.key).not.toBe(removes[0]!.key);
  await act(async () => removes[1]!.reply.reject(new Error("network")));
  await h.click("worktree", "worktree.removeAnyway:");
  expect(removes[2]!.key).toBe(removes[1]!.key);
  await act(async () => removes[2]!.reply.resolve({ value: { root: "/worktrees/ops" } }));
  expect(flatten(h.tool("worktree").menu ?? []).filter((item) => item.enabled)).toEqual([]);

  await h.render({ ...props, folder: "/worktrees/new" });
  await h.click("worktree", "worktree.remove:");
  await act(async () => removes[3]!.reply.reject(new Error("network")));
  expect(h.tool("worktree").menu?.some((item) => item.id.startsWith("worktree.removeAnyway:"))).toBe(false);
  expect(h.tool("worktree").menu).toContainEqual(
    expect.objectContaining({ label: translate("header.worktreeRemoveFailed"), enabled: false }),
  );
  await h.click("worktree", "worktree.remove:");
  expect(removes[4]!.key).toBe(removes[3]!.key);
  await act(async () => removes[4]!.reply.reject(new Error("network")));
  await h.click("worktree", "worktree.apply:");
  expect(h.row("worktree", "worktree.remove:").enabled).toBe(false);
  const removeCount = removes.length;
  await h.click("worktree", "worktree.remove:");
  expect(removes).toHaveLength(removeCount);
  await act(async () => applies[0]!.reply.reject(new Error("network")));
  expect(h.tool("worktree").menu).toContainEqual(
    expect.objectContaining({ label: translate("header.worktreeApplyFailed"), enabled: false }),
  );
  await h.click("worktree", "worktree.apply:");
  expect(applies[1]!.key).toBe(applies[0]!.key);
  await act(async () => applies[1]!.reply.resolve({ value: { files: ["file"] } }));
});

test("switching native tools off keeps the pending worktree operation in its DOM popover", async () => {
  const h = nativeHarness(),
    reply = deferred();
  const props = {
    folder: "/worktrees/toggle",
    readStatus: async () => ({ branch: "feature", worktree: { main_root: "/repo" } }),
    onApplyWorktree: () => reply.promise,
    onRemoveWorktree: async () => ({ value: { root: "/worktrees/toggle" } }),
  };
  await h.render(props);
  await h.click("worktree", "worktree.apply:");
  await h.render({ ...props, nativeRowTools: undefined });
  await act(async () => h.container.querySelector<HTMLButtonElement>(".acpmux-header-worktree")!.click());
  const apply = document.querySelector<HTMLButtonElement>(".acpmux-worktree-apply button")!;
  const remove = document.querySelector<HTMLButtonElement>(".acpmux-worktree-remove button")!;
  expect(apply.disabled).toBe(true);
  expect(remove.disabled).toBe(true);
  await act(async () => reply.reject(new Error("network")));
  expect(document.querySelector(".acpmux-worktree-apply [role=alert]")?.textContent).toBe(
    translate("header.worktreeApplyFailed"),
  );
});

test("worktree target switches reject stale menu ids and late unsaved authorization", async () => {
  const h = nativeHarness(),
    pending = deferred();
  let calls = 0;
  const props = {
    readStatus: async () => ({ branch: "same", worktree: { main_root: "/repo" } }),
    onRemoveWorktree: async () => {
      calls++;
      return pending.promise;
    },
  };
  await h.render({ ...props, folder: "/worktrees/A" });
  const oldId = await h.click("worktree", "worktree.remove:");
  await h.render({ ...props, folder: "/worktrees/B" });
  await act(async () => h.invoke("worktree", oldId));
  expect(calls).toBe(1);
  await act(async () => pending.reject({ details: { reason: "unpushed_commits" } }));
  expect(h.tool("worktree").menu?.some((item) => item.id.startsWith("worktree.removeAnyway:"))).toBe(false);
  expect(h.row("worktree", "worktree.remove:").enabled).toBe(true);
});

test("native PR confirmation and completion stay scoped to the PR and share failure text", async () => {
  const h = nativeHarness(),
    pending = deferred<{ queued: boolean }>();
  const merged: number[] = [];
  const props = {
    onMergePullRequest: async ({ number }: { number: number; url: string }) => {
      merged.push(number);
      return pending.promise;
    },
  };
  await act(async () => setHeaderState({ pullRequest: request(1) }));
  await h.render(props);
  const oldId = await h.click("pullRequest", "pullRequest.merge:");
  expect(merged).toEqual([]);
  const confirmId = await h.click("pullRequest", "pullRequest.confirm:");
  await act(async () => h.invoke("pullRequest", confirmId));
  expect(merged).toEqual([1]);
  expect(h.row("pullRequest", "pullRequest.confirm:").enabled).toBe(false);
  await act(async () => setHeaderState({ pullRequest: request(2) }));
  await act(async () => {
    h.invoke("pullRequest", oldId);
    h.invoke("pullRequest", confirmId);
  });
  await act(async () => pending.resolve({ queued: false }));
  expect(h.row("pullRequest", "pullRequest.merge:").enabled).toBe(true);
  expect(merged).toEqual([1]);
  const failure = deferred<{ queued: boolean }>();
  await h.render({ onMergePullRequest: () => failure.promise });
  await h.click("pullRequest", "pullRequest.merge:");
  await h.click("pullRequest", "pullRequest.confirm:");
  await act(async () => failure.reject(new Error("Host refused this merge")));
  expect(h.tool("pullRequest").menu).toContainEqual(
    expect.objectContaining({ label: "Host refused this merge", enabled: false }),
  );
  await h.click("pullRequest", "pullRequest.merge:");
  expect(h.row("pullRequest", "pullRequest.cancel:").enabled).toBe(true);
  await h.click("pullRequest", "pullRequest.cancel:");
  expect(h.row("pullRequest", "pullRequest.merge:").enabled).toBe(true);
});

test("native PR status uses aggregate checks, preserves Merge and rejects replaced check selections", async () => {
  const h = nativeHarness(),
    opened: string[] = [];
  dom!.window.open = ((url: string) => {
    opened.push(url);
    return null;
  }) as Window["open"];
  const checks = Array.from({ length: 31 }, (_, i) => ({
    name: `Check ${i}`,
    state: "passed",
    url: `https://example.test/check/${i}`,
  }));
  const pr = { ...request(42), checks: { state: "passing", passed: 31, total: 31 }, checkList: checks };
  await act(async () => setHeaderState({ pullRequest: pr }));
  await h.render({ onMergePullRequest: async () => ({ queued: false }) });
  expect(h.row("pullRequest", "pullRequest.merge:").enabled).toBe(true);
  expect(h.tool("pullRequest").menu).toHaveLength(32);
  expect(h.tool("pullRequest").menu?.some((item) => item.label.includes("more"))).toBe(true);
  const oldId = h.row("pullRequest", "pullRequest.check:").id;
  await act(async () =>
    setHeaderState({
      pullRequest: {
        ...pr,
        checks: { state: "pending", passed: 30, total: 31 },
        checkList: [{ name: "Check 0", state: "pending" }, ...checks.slice(1)],
      },
    }),
  );
  expect(h.tool("pullRequest").text).not.toContain("✓");
  expect(h.row("pullRequest", "pullRequest.check:").enabled).toBe(false);
  await act(async () => h.invoke("pullRequest", oldId));
  expect(opened).toEqual([]);
  await act(async () =>
    setHeaderState({
      pullRequest: {
        ...pr,
        checks: { state: "failing", passed: 30, total: 31, failingOnBase: 1 },
        checkList: [{ name: "Check 0", state: "failed", onBase: true }, ...checks.slice(1)],
      },
    }),
  );
  expect(h.tool("pullRequest").text).not.toContain("✓");
  expect(h.tool("pullRequest").text).toContain("30/31");
  expect(h.row("pullRequest", "pullRequest.check:").label).toContain(translate("header.prCheckOnBase"));
  for (const state of ["failing", "pending"]) {
    await act(async () =>
      setHeaderState({ pullRequest: { ...pr, checks: { state, passed: 2, total: 2 }, checkList: [] } }),
    );
    expect(h.tool("pullRequest").text).not.toContain("✓");
    expect(h.tool("pullRequest").text).toContain("2/2");
  }
});

test("native Needs You compact policy and same-target replacements use the DOM action set", async () => {
  const h = nativeHarness(),
    calls: string[] = [];
  const items = [ask("one"), ask("two")];
  const actions = {
    answer: async (item: (typeof items)[number]) => {
      calls.push("answer:" + item.id);
    },
    ask: async (item: (typeof items)[number]) => {
      calls.push("ask:" + item.id);
    },
    goTo: (item: (typeof items)[number]) => {
      calls.push("go:" + item.id);
    },
  };
  await h.render({ nativeNeedsYou: { items, mode: "pinned", actions } });
  const first = h.tool("needsYou").menu![0]!.children!;
  const second = h.tool("needsYou").menu![1]!.children!;
  for (const entry of [first[0]!, second[0]!, first[1]!, second[2]!])
    await act(async () => h.invoke("needsYou", entry.id));
  expect(calls).toEqual(["answer:one", "answer:two", "go:one", "ask:two"]);
  await h.render({
    nativeNeedsYou: { items: [ask("one", "A different request"), ask("two")], mode: "pinned", actions },
  });
  await act(async () => h.invoke("needsYou", first[0]!.id));
  expect(calls).toHaveLength(4);
  await h.render({ nativeNeedsYou: { items, mode: "compact", actions } });
  for (const entry of h.tool("needsYou").menu!) expect(entry.children).toHaveLength(1);
  await act(async () => h.invoke("needsYou", first[0]!.id));
  expect(calls).toHaveLength(4);
  await act(async () => h.invoke("needsYou", h.tool("needsYou").menu![1]!.children![0]!.id));
  expect(calls.at(-1)).toBe("go:two");
});

test("native Needs You keeps colliding ask and answer identifiers distinct", async () => {
  const h = nativeHarness();
  const calls: string[] = [];
  const items = [ask("costarring"), ask("liquid")];
  const actions = {
    answer: async (item: (typeof items)[number], choice: { id: string }) => {
      calls.push(`answer:${item.id}:${choice.id}`);
    },
    goTo: (item: (typeof items)[number]) => {
      calls.push(`go:${item.id}`);
    },
    ask: async () => {},
  };
  await h.render({ nativeNeedsYou: { items, mode: "pinned", actions } });
  const rows = h.tool("needsYou").menu!;
  const ids = flatten(rows).map(({ id }) => id);
  expect(new Set(ids).size).toBe(ids.length);
  for (const row of rows) {
    await act(async () => h.invoke("needsYou", row.children!.find(({ id }) => id.includes(":answer:"))!.id));
    await act(async () => h.invoke("needsYou", row.children!.find(({ id }) => id.endsWith(":goToSource"))!.id));
  }
  expect(calls).toEqual(["answer:costarring:yes", "go:costarring", "answer:liquid:yes", "go:liquid"]);
  calls.length = 0;
  const choices = ["costarring", "liquid"].map((id) => ({ id, label: id, tone: "allow" as const }));
  await h.render({ nativeNeedsYou: { items: [{ ...ask("choice"), answers: choices }], mode: "pinned", actions } });
  const answers = h.tool("needsYou").menu![0]!.children!.filter(({ id }) => id.includes(":answer:"));
  expect(answers[0]!.id).not.toBe(answers[1]!.id);
  for (const row of answers) await act(async () => h.invoke("needsYou", row.id));
  expect(calls).toEqual(["answer:choice:costarring", "answer:choice:liquid"]);
});

test("unchanged menu inputs do not resend, and returning to an old target never reuses its action IDs", async () => {
  const h = nativeHarness();
  const calls: string[] = [];
  const actions = {
    answer: async (item: { id: string }) => {
      calls.push(item.id);
    },
    goTo: () => {},
    ask: async () => {},
  };
  const first = { items: [ask("costarring")], mode: "pinned" as const, actions };
  await h.render({ nativeNeedsYou: first });
  const firstId = h.tool("needsYou").menu![0]!.children![0]!.id;
  const count = h.sent.length;
  await h.render({ nativeNeedsYou: { ...first, items: [...first.items], actions: { ...actions } } });
  expect(h.sent).toHaveLength(count);
  expect(h.tool("needsYou").menu![0]!.children![0]!.id).toBe(firstId);
  await h.render({ nativeNeedsYou: { ...first, items: [ask("liquid")] } });
  const secondId = h.tool("needsYou").menu![0]!.children![0]!.id;
  expect(secondId).not.toBe(firstId);
  await act(async () => h.invoke("needsYou", firstId));
  await h.render({ nativeNeedsYou: first });
  const returnedId = h.tool("needsYou").menu![0]!.children![0]!.id;
  expect(returnedId).not.toBe(firstId);
  await act(async () => {
    h.invoke("needsYou", firstId);
    h.invoke("needsYou", secondId);
  });
  expect(calls).toEqual([]);
  await act(async () => h.invoke("needsYou", returnedId));
  expect(calls).toEqual(["costarring"]);
});

test("native Needs You surfaces rejected answer and ask actions while keeping retry enabled", async () => {
  const h = nativeHarness();
  const item = ask("failure");
  let rejectAnswer!: (error: Error) => void;
  let rejectAsk!: (error: Error) => void;
  const actions = {
    answer: async () => new Promise((_, reject) => (rejectAnswer = reject)),
    ask: async () => new Promise((_, reject) => (rejectAsk = reject)),
    goTo: () => {},
  };
  await h.render({ nativeNeedsYou: { items: [item], mode: "pinned", actions } });
  const answer = h.tool("needsYou").menu![0]!.children!.find((entry) => entry.id.includes(":answer:"))!;
  await act(async () => h.invoke("needsYou", answer.id));
  await act(async () => rejectAnswer(new Error("answer refused")));
  await new Promise((resolve) => setTimeout(resolve, 0));
  expect(h.tool("needsYou").menu![0]!.children).toContainEqual(
    expect.objectContaining({ label: "answer refused", enabled: false }),
  );
  expect(h.tool("needsYou").menu![0]!.children!.some((entry) => entry.id.includes(":answer:") && entry.enabled)).toBe(
    true,
  );

  const askItemId = h.tool("needsYou").menu![0]!.children!.find((entry) => entry.id.includes(":askAbout"))!.id;
  await act(async () => h.invoke("needsYou", askItemId));
  await act(async () => rejectAsk(new Error("ask refused")));
  await new Promise((resolve) => setTimeout(resolve, 0));
  expect(h.tool("needsYou").menu![0]!.children).toContainEqual(
    expect.objectContaining({ label: "ask refused", enabled: false }),
  );
});

test("component descriptors meet the Swift decoder's text and global menu limits", async () => {
  const h = nativeHarness();
  const swift = readFileSync(
    new URL("../../Packages/macOS/CmuxNext/Sources/CmuxNextAgentPane/AgentPaneTabRowTools.swift", import.meta.url),
    "utf8",
  );
  const limit = (name: string) => Number(swift.match(new RegExp(`static let ${name} = (\\d+)`))![1]);
  expect(NATIVE_MAX_TOOLS).toBe(limit("maximumTools"));
  expect(NATIVE_MAX_MENU_ITEMS).toBe(limit("maximumMenuItems"));
  expect(NATIVE_MAX_DEPTH).toBe(limit("maximumDepth"));
  expect(NATIVE_MAX_TOTAL_MENU_ITEMS).toBe(limit("maximumTotalMenuItems"));
  expect(NATIVE_MAX_TEXT_BYTES).toBe(limit("maximumTextBytes"));
  expect(NATIVE_MAX_TEXT_GRAPHEMES).toBe(limit("maximumText"));
  const emoji = "👨‍👩‍👧‍👦".repeat(64);
  const items = Array.from({ length: 40 }, (_, i) => ({
    ...ask(String(i), i ? emoji : ""),
    answers: Array.from({ length: 4 }, (_, j) => ({ id: String(j), label: j ? emoji : "", tone: "allow" as const })),
  }));
  await act(async () =>
    setHeaderState({
      pullRequest: {
        ...request(2),
        checkList: Array.from({ length: 31 }, (_, i) => ({
          name: i ? emoji : "",
          state: "passed",
          url: `https://example.test/${i}`,
        })),
      },
    }),
  );
  await h.render({
    folder: "/worktrees/budget",
    readStatus: async () => ({ branch: emoji, worktree: { main_root: "/repo" } }),
    onApplyWorktree: async () => ({ value: { files: [] } }),
    onRemoveWorktree: async () => ({ value: { root: "/worktrees/budget" } }),
    onMergePullRequest: async () => ({ queued: false }),
    nativeNeedsYou: { items, mode: "pinned", actions: { answer: async () => {}, ask: async () => {}, goTo: () => {} } },
  });
  const segmenter = new Intl.Segmenter(undefined, { granularity: "grapheme" });
  const checkText = (value: string) => {
    expect(value.length).toBeGreaterThan(0);
    expect(new TextEncoder().encode(value).length).toBeLessThanOrEqual(limit("maximumTextBytes"));
    expect(Array.from(segmenter.segment(value)).length).toBeLessThanOrEqual(limit("maximumText"));
  };
  let total = 0;
  const checkMenu = (rows: NativeRowMenuItem[], depth = 0) => {
    expect(depth).toBeLessThanOrEqual(limit("maximumDepth"));
    expect(rows.length).toBeLessThanOrEqual(limit("maximumMenuItems"));
    for (const row of rows) {
      total++;
      checkText(row.id);
      checkText(row.label);
      if (row.children) checkMenu(row.children, depth + 1);
    }
  };
  for (const id of ["worktree", "pullRequest", "needsYou"]) {
    const tool = h.tool(id);
    for (const value of [tool.id, tool.symbol, tool.label, ...(tool.badge ? [tool.badge] : [])]) checkText(value);
    if (tool.text) {
      expect(Array.from(segmenter.segment(tool.text)).length).toBeLessThanOrEqual(NATIVE_MAX_VISIBLE_TEXT_GRAPHEMES);
      expect(new TextEncoder().encode(tool.text).length).toBeLessThanOrEqual(NATIVE_MAX_VISIBLE_TEXT_BYTES);
      expect(tool.badge).toBeUndefined();
    }
    checkMenu(tool.menu!);
  }
  expect(total).toBeLessThanOrEqual(limit("maximumTotalMenuItems"));
  expect(total).toBeGreaterThan(240);
  expect(h.row("pullRequest", "pullRequest.merge:").enabled).toBe(true);
  expect(h.tool("needsYou").menu?.some((item) => item.label.includes("more"))).toBe(true);
  expect(boundedNativeText("")).toBe("…");
});

const ids = ["newTab", "changes", "files", "preview", "splitDown", "terminal", "browser"] as const;
function quickInput(calls: string[]): HeaderQuickToolsInput {
  return {
    actions: ids.map((id) => ({ id, mode: "toggle" })),
    tabTools: true,
    sideTabs: true,
    lit: [HEADER_ACTIONS.changes, HEADER_ACTIONS.files, HEADER_ACTIONS.terminal],
    browserOpensPreview: true,
    hasChanges: true,
    previewUrl: "http://localhost:5173/",
    onTerminal: (mode) => void calls.push(`terminal:${mode}`),
    onBrowser: (mode) => void calls.push(`browser:${mode}`),
    onSplitDown: (mode) => void calls.push(`splitDown:${mode}`),
    onChanges: (mode) => void calls.push(`changes:${mode}`),
    onFiles: (mode) => void calls.push(`files:${mode}`),
    onPreview: (url, mode) => void calls.push(`preview:${mode}:${url}`),
    onSideTabs: () => void calls.push("newTab"),
    t: (key) => key,
  };
}

test("native descriptors preserve quick-action order, toolbar symbols, state and panel semantics", () => {
  const input = quickInput([]);
  const bindings = nativeRowToolBindings(headerQuickTools(input), {
    id: "summary",
    label: "Chat summary",
    toggled: true,
    run: () => {},
  });
  expect(bindings.map(({ tool }) => tool.id)).toEqual(["summary", ...ids]);
  expect(bindings.map(({ tool }) => tool.symbol)).toEqual([
    "list.bullet",
    "sidebar.right",
    "plusminus",
    "folder",
    "play",
    "rectangle.split.1x2",
    "terminal",
    "globe",
  ]);
  expect(bindings.map(({ tool }) => tool.toggled)).toEqual([true, true, true, true, false, false, true, false]);
  expect(bindings.every(({ tool }) => tool.enabled)).toBe(true);
  expect(bindings[0]!.tool).not.toHaveProperty("badge");
  expect(bindings.some(({ tool }) => tool.id === "needsYou")).toBe(false);
  const disabled = nativeRowToolBindings(headerQuickTools({ ...input, onSideTabs: undefined }), {
    id: "inspector",
    label: "Session Info",
    toggled: false,
  });
  expect(disabled[0]!.tool).toMatchObject({ id: "inspector", enabled: false, toggled: false });
  expect(disabled[1]!.tool.enabled).toBe(false);
  const open = nativeRowToolBindings(headerQuickTools({ ...input, actions: [{ id: "terminal", mode: "open" }] }));
  expect(open[0]!.tool.toggled).toBe(false);
  expect(nativeRowToolBindings(headerQuickTools({ ...input, sideTabs: false }))[0]!.tool.symbol).toBe("plus");
});

test("every native id dispatches the shared handler; invalid, disabled and menu invocations do nothing", () => {
  const calls: string[] = [];
  const bindings = nativeRowToolBindings(headerQuickTools(quickInput(calls)), {
    id: "summary",
    label: "Summary",
    toggled: false,
    run: () => void calls.push("summary"),
  });
  for (const { tool } of bindings) dispatchNativeRowTool({ id: tool.id }, bindings);
  expect(calls).toEqual([
    "summary",
    "newTab",
    "changes:toggle",
    "files:toggle",
    "preview:toggle:http://localhost:5173/",
    "splitDown:toggle",
    "terminal:toggle",
    "browser:toggle",
  ]);
  const disabled = [{ tool: { ...bindings[0]!.tool, enabled: false }, run: () => void calls.push("disabled") }];
  dispatchNativeRowTool({ id: "summary" }, disabled);
  for (const value of [
    null,
    undefined,
    true,
    "terminal",
    {},
    { id: 7 },
    { id: "missing" },
    { id: "terminal", menuItemId: "x" },
    { id: "terminal", menuItemId: null },
  ])
    dispatchNativeRowTool(value, bindings);
  expect(calls).toHaveLength(8);
  dispatchNativeRowTool(
    { id: "inspector" },
    nativeRowToolBindings([], {
      id: "inspector",
      label: "Session Info",
      toggled: true,
      run: () => void calls.push("inspector"),
    }),
  );
  expect(calls.at(-1)).toBe("inspector");
});

test("conditional quick actions and Browser's preview delegation keep the web behavior", () => {
  const calls: string[] = [];
  const input = quickInput(calls);
  expect(headerQuickTools({ ...input, tabTools: false })).toEqual([]);
  expect(
    headerQuickTools({
      ...input,
      hasChanges: false,
      previewUrl: undefined,
      lit: [],
      onFiles: undefined,
      onSplitDown: undefined,
    }).map(({ id }) => id),
  ).toEqual(["newTab", "terminal", "browser"]);
  const browser = headerQuickTools({
    ...input,
    actions: [{ id: "browser", mode: "toggle" }],
    lit: [HEADER_ACTIONS.preview],
  });
  expect(nativeRowToolBindings(browser)[0]!.tool.toggled).toBe(true);
  dispatchNativeRowTool({ id: "browser" }, nativeRowToolBindings(browser));
  expect(calls).toEqual(["preview:toggle:http://localhost:5173/"]);
});

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, { had: boolean; value: unknown }>();
let previousHeader: ReturnType<typeof headerState> | undefined;
let previousQuick: ReturnType<typeof quickActions> | undefined;
let previousTabRow: TabRow | undefined;
function mount() {
  previousHeader = headerState();
  previousQuick = quickActions();
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", {
    url: "http://localhost/",
    pretendToBeVisual: true,
  });
  const replacements = {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    Node: dom.window.Node,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    MutationObserver: dom.window.MutationObserver,
    getComputedStyle: dom.window.getComputedStyle.bind(dom.window),
    requestAnimationFrame: dom.window.requestAnimationFrame.bind(dom.window),
    cancelAnimationFrame: dom.window.cancelAnimationFrame.bind(dom.window),
    IS_REACT_ACT_ENVIRONMENT: true,
  };
  for (const [key, value] of Object.entries(replacements)) {
    saved.set(key, { had: key in scope, value: scope[key] });
    scope[key] = value;
  }
  configureQuickActions({ quickActions: ["terminal", "browser"] });
  setHeaderState({ lit: [], pullRequest: null, browserOpensPreview: true });
  const container = dom.window.document.getElementById("root")!;
  root = createRoot(container);
  return container;
}

afterEach(async () => {
  if (root) await act(async () => root!.unmount());
  root = undefined;
  if (previousQuick) configureQuickActions({ quickActions: previousQuick });
  if (previousHeader) setHeaderState({ ...previousHeader, pullRequest: previousHeader.pullRequest ?? null });
  previousQuick = undefined;
  if (previousTabRow) setTabRow(previousTabRow);
  previousTabRow = undefined;
  previousHeader = undefined;
  dom?.window.close();
  dom = undefined;
  for (const [key, { had, value }] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
  saved.clear();
});

test("host events switch the header to native tools and invoke the same web handlers", async () => {
  const container = mount();
  const sent: { method: string; tools: NativeRowTool[] }[] = [];
  const called: string[] = [];
  const callNative = async (method: string, params: Record<string, unknown>) => {
    sent.push({ method, tools: params.tools as NativeRowTool[] });
  };
  function Header({ generation }: { generation: string }) {
    const row = useTabRow();
    previousTabRow ??= row;
    const panel = () => void called.push(`summary:${generation}`);
    return (
      <ChatHeaderTools
        onTerminal={() => void called.push(`terminal:${generation}`)}
        onBrowser={() => void called.push(`browser:${generation}`)}
        summary={(native) => (
          <SummaryButton
            native={native}
            card={{
              shown: false,
              column: false,
              reserve: false,
              collapsed: false,
              toggle: panel,
              show: panel,
              close: panel,
              fold: () => {},
            }}
          />
        )}
        inbox={
          <NeedsYouButton
            items={[]}
            actions={{
              answer: async () => {},
              ask: async () => {},
              goTo: () => {},
            }}
          />
        }
        nativeNeedsYou={{
          nativeMenu: true,
          mode: "pinned",
          items: [
            {
              id: "needs-1",
              kind: "approval",
              sessionId: "chat-1",
              ask: "Approve",
              who: { name: "A", chief: false },
              answers: [{ id: "allow", label: "Allow", tone: "allow" }],
              permissionId: "p-1",
            },
          ],
          actions: { answer: async () => {}, ask: async () => {}, goTo: () => {} },
        }}
        menu={() => [
          {
            key: "rename",
            label: "Rename",
            icon: "action.edit",
            onSelect: () => {},
          },
        ]}
        nativeRowTools={{
          enabled: row.height > 0 && row.nativeRowTools === true,
          callNative,
          panel: {
            id: "summary",
            label: "Chat summary",
            toggled: false,
            run: panel,
          },
        }}
      />
    );
  }
  const render = async (enabled: boolean, generation: string) => {
    await act(async () => root!.render(<Header generation={generation} />));
    await act(async () =>
      applyHostEvent({
        kind: "tabRow",
        value: { height: 28, nativeRowTools: enabled },
      }),
    );
  };
  await render(false, "off");
  expect(sent).toHaveLength(0);
  expect(container.querySelectorAll("[data-quick-action]")).toHaveLength(2);
  expect(container.querySelector(".acpmux-summary-button")).not.toBeNull();
  act(() => {
    container.querySelector<HTMLButtonElement>('[data-quick-action="terminal"]')!.click();
    container.querySelector<HTMLButtonElement>(".acpmux-summary-button")!.click();
  });
  expect(called).toEqual(["terminal:off", "summary:off"]);
  act(() => {
    applyHostEvent({ kind: "tabRowToolInvoked", value: { id: "terminal" } });
    applyHostEvent({ kind: "tabRowToolInvoked", value: { id: "summary" } });
  });
  expect(called).toHaveLength(2);
  called.length = 0;
  await render(true, "first");
  expect(sent).toHaveLength(1);
  expect(sent[0]!.method).toBe("pane.tabRowTools.set");
  expect(sent[0]!.tools.map(({ id }) => id)).toEqual(["summary", "needsYou", "terminal", "browser"]);
  expect(container.querySelectorAll("[data-quick-action]")).toHaveLength(0);
  expect(container.querySelector(".acpmux-summary-button")).toBeNull();
  expect(container.querySelector(".acpmux-needs-you-button")).toBeNull();
  expect(container.querySelector('button[aria-label="Chat actions"]')).not.toBeNull();
  await render(true, "latest");
  expect(sent).toHaveLength(1);
  act(() => {
    applyHostEvent({ kind: "tabRowToolInvoked", value: { id: "terminal" } });
    applyHostEvent({ kind: "tabRowToolInvoked", value: { id: "summary" } });
  });
  expect(called).toEqual(["terminal:latest", "summary:latest"]);
  act(() => expect(openPicker(translate("summary.open"))).toBe(true));
  expect(called.at(-1)).toBe("summary:latest");
  called.pop();
  // The App uses enabled=false both for the off tunable and a covered/hidden header.
  await render(false, "hidden");
  expect(container.querySelectorAll("[data-quick-action]")).toHaveLength(2);
  expect(container.querySelector(".acpmux-summary-button")).not.toBeNull();
  expect(sent.at(-1)!.tools).toEqual([]);
  const count = sent.length;
  act(() => applyHostEvent({ kind: "tabRowToolInvoked", value: { id: "terminal" } }));
  expect(called).toHaveLength(2);
  await render(false, "still-hidden");
  expect(sent).toHaveLength(count);
  await render(true, "shown");
  expect(sent.at(-1)!.tools).toHaveLength(4);
  await act(async () => root!.unmount());
  root = undefined;
  expect(sent.at(-1)!.tools).toEqual([]);
  act(() => applyHostEvent({ kind: "tabRowToolInvoked", value: { id: "terminal" } }));
  expect(called).toHaveLength(2);
});

test("a failed native set restores web buttons and recovers on changed state", async () => {
  const container = mount();
  const sent: NativeRowTool[][] = [];
  const calls: string[] = [];
  let reject = true;
  const callNative = async (_method: string, params: Record<string, unknown>) => {
    const tools = params.tools as NativeRowTool[];
    sent.push(tools);
    if (reject && tools.length) throw new Error("unsupported native host");
  };
  await act(async () =>
    root!.render(
      <ChatHeaderTools
        onTerminal={() => void calls.push("terminal")}
        onBrowser={() => {}}
        summary={
          <button type="button" data-summary-fixture>
            Summary
          </button>
        }
        menu={() => []}
        nativeRowTools={{
          enabled: true,
          callNative,
          panel: { id: "summary", label: "Summary", toggled: false, run: () => {} },
        }}
      />,
    ),
  );
  expect(sent[0]).toHaveLength(3);
  expect(sent.at(-1)).toEqual([]);
  expect(container.querySelectorAll("[data-quick-action]")).toHaveLength(2);
  expect(container.querySelector("[data-summary-fixture]")).not.toBeNull();
  act(() => applyHostEvent({ kind: "tabRowToolInvoked", value: { id: "terminal" } }));
  expect(calls).toEqual([]);
  reject = false;
  await act(async () => setHeaderState({ lit: [HEADER_ACTIONS.terminal] }));
  expect(container.querySelectorAll("[data-quick-action]")).toHaveLength(0);
  await act(async () => setHeaderState({ lit: [] }));
  expect(container.querySelectorAll("[data-quick-action]")).toHaveLength(0);
  act(() => applyHostEvent({ kind: "tabRowToolInvoked", value: { id: "terminal" } }));
  expect(calls).toEqual(["terminal"]);
});

test("tab-row native opt-in requires a true flag and an offered positive height", async () => {
  const container = mount();
  const sent: NativeRowTool[][] = [];
  const callNative = async (_method: string, params: Record<string, unknown>) => {
    sent.push(params.tools as NativeRowTool[]);
  };
  function SaveRow() {
    previousTabRow = useTabRow();
    return null;
  }
  await act(async () => root!.render(<SaveRow />));
  await act(async () => root!.render(null));
  setTabRow(null);
  function Row() {
    const row = useTabRow();
    const native = useNativeRowTools({ enabled: row.height > 0 && row.nativeRowTools === true, callNative }, [
      { id: "terminal", icon: "terminal", label: "Terminal", run: () => {} },
    ]);
    return <span data-native={String(native)} />;
  }
  await act(async () => root!.render(<Row />));
  for (const value of [
    null,
    {},
    { height: 28 },
    { height: 40, nativeRowTools: false },
    { height: 28, nativeRowTools: "true" },
    { height: 0, nativeRowTools: true },
    { height: -1, nativeRowTools: true },
  ]) {
    await act(async () => applyHostEvent({ kind: "tabRow", value }));
    expect(container.querySelector("[data-native]")?.getAttribute("data-native")).toBe("false");
  }
  expect(sent).toEqual([]);
  await act(async () => applyHostEvent({ kind: "tabRow", value: { height: 28, nativeRowTools: true } }));
  expect(container.querySelector("[data-native]")?.getAttribute("data-native")).toBe("true");
  expect(sent).toHaveLength(1);
  await act(async () => applyHostEvent({ kind: "tabRow", value: { height: 40, nativeRowTools: true } }));
  expect(sent).toHaveLength(1);
  await act(async () => applyHostEvent({ kind: "tabRow", value: { height: 40 } }));
  expect(container.querySelector("[data-native]")?.getAttribute("data-native")).toBe("false");
  expect(sent.at(-1)).toEqual([]);
});
