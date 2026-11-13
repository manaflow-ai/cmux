import { expect, test } from "bun:test";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";
import { translatorFor } from "../src/agent-session/acpmux/i18n";
import { turnView } from "../src/agent-session/acpmux/conversation/turns";
import { withSendPromptAgain } from "../src/agent-session/acpmux/conversation/messageMenu";
import {
  sendPromptAgain,
  sendPromptAgainMenu,
  sendPromptAgainTarget,
  type SendPromptAgainState,
} from "../src/agent-session/acpmux/conversation/sendPromptAgain";

const t = translatorFor("en");
const row = (id: string, kind: string, fields: Partial<AcpmuxRow> = {}): AcpmuxRow => ({
  id,
  kind,
  version: 1,
  at: 1,
  ...fields,
});
const prompt = row("user-1", "user", { text: "Check /$emil-color", seq: 1 });
const answer = row("answer-1", "assistant", { text: "Checked.", seq: 2 });
const footer = row("summary-3", "turnSummary", {
  status: "completed",
  answerId: answer.id,
  retryTarget: true,
  retryRowId: prompt.id,
  prompt: prompt.text,
  text: answer.text,
});
const state = (fields: Partial<SendPromptAgainState> = {}): SendPromptAgainState => ({
  sessionId: "chat-a",
  selectedSessionId: "chat-a",
  drawnSessionId: "chat-a",
  canSend: true,
  rows: [prompt, answer, footer],
  currentModel: "sonnet",
  models: [
    { id: "sonnet", name: "Sonnet" },
    { id: "opus", name: "Opus" },
  ],
  top: ["sonnet"],
  ...fields,
});
const request = { sessionId: "chat-a", rowId: footer.id };

test("the latest successful footer owns the action, preserving reply copy and pin targets", () => {
  const original = { rowId: "summary-3", sessionId: "chat-a", text: "Checked.", markdown: "**Checked.**", forkSeq: 3 };
  const report = withSendPromptAgain(original, answer.id, state(), t)!;
  expect(report).toMatchObject(original);
  expect(report.sendPromptAgain).toMatchObject({
    ...request,
    label: t("turn.retryLabel"),
    modelsLabel: "Retry with another model",
    moreModelsLabel: "More models",
  });
  expect(withSendPromptAgain(original, prompt.id, state(), t)).toBe(original);
  expect(sendPromptAgainTarget(state())?.prompt).toBe("Check /$emil-color");
});

test("a blank tool-only footer keeps resend available through the menu", () => {
  const toolOnly = { ...footer, text: undefined, answerId: undefined };
  expect(
    withSendPromptAgain(undefined, footer.id, state({ rows: [prompt, toolOnly] }), t)?.sendPromptAgain?.rowId,
  ).toBe(footer.id);
});

test("a reply that ended on tools keeps an action-only menu on its existing nonblank footer", () => {
  const workFooter = {
    ...footer,
    text: undefined,
    answerId: undefined,
    retryable: true,
    turnCopy: [{ text: "Checked before the last tool." }],
  };
  const report = withSendPromptAgain(undefined, workFooter.id, state({ rows: [prompt, workFooter] }), t)!;
  expect(report.text).toBe("");
  expect(report.sessionId).toBe("chat-a");
  expect(report.sendPromptAgain?.rowId).toBe(workFooter.id);
});

test("failed, live, stale and unavailable targets cannot offer resend", () => {
  for (const status of ["failed", "error", "running"])
    expect(sendPromptAgainMenu(state({ rows: [prompt, { ...footer, status }] }), t)).toBeUndefined();
  for (const change of [
    { canSend: false },
    { selectedSessionId: "chat-b" },
    { drawnSessionId: "chat-b" },
    { sessionId: undefined },
  ])
    expect(sendPromptAgainMenu(state(change), t)).toBeUndefined();
  expect(sendPromptAgainMenu(state({ rows: [prompt] }), t)).toBeUndefined();
  expect(
    sendPromptAgainMenu(state({ rows: [prompt, footer, row("user-4", "user", { text: "Next" })] }), t),
  ).toBeUndefined();
});

test("model groups retain curated latest, older choices and the checked alias", () => {
  const offer = sendPromptAgainMenu(
    state({
      currentModel: "release-sonnet",
      models: [
        { id: "sonnet", name: "Sonnet", release: "release-sonnet" },
        { id: "release-sonnet", name: "Sonnet" },
        { id: "opus", name: "Opus" },
        { id: "old", name: "Old model" },
        { id: "blocked", name: "Unavailable", unavailable: "not offered" },
      ],
      top: ["sonnet", "opus"],
    }),
    t,
  )!;
  expect(offer.currentModel).toBe("release-sonnet");
  expect(offer.latestModels?.map((model) => model.id)).toEqual(["release-sonnet", "opus"]);
  expect(offer.moreModels?.map((model) => model.id)).toEqual(["old"]);
  expect(sendPromptAgainMenu(state({ models: [{ id: "sonnet", name: "Sonnet" }] }), t)?.latestModels).toBeUndefined();
});

function runner() {
  let current = state();
  const calls: unknown[] = [];
  const draft = { input: prompt.text!, attachments: [{ id: "original-image" }] };
  const deps = {
    read: () => current,
    pickModel: async (model: string) => {
      calls.push(["model", model]);
      current = { ...current, currentModel: model };
      return true;
    },
    restore: async (id: string, input: string) => {
      calls.push(["restore", id, input]);
      return draft;
    },
    send: async (sent: typeof draft, sessionId: string) => {
      calls.push(["send", sent, sessionId]);
    },
  };
  return {
    deps,
    calls,
    draft,
    set: (change: Partial<SendPromptAgainState>) => {
      current = { ...current, ...change };
    },
  };
}

test("sending again restores original text and attachments before the existing send path", async () => {
  const run = runner();
  expect(await sendPromptAgain(request, run.deps)).toBe(true);
  expect(run.calls).toEqual([
    ["restore", prompt.id, prompt.text],
    ["send", run.draft, "chat-a"],
  ]);
});

test("another model is picked before restore; invalid or refused picks send nothing", async () => {
  const run = runner();
  expect(await sendPromptAgain({ ...request, model: "opus" }, run.deps)).toBe(true);
  expect(run.calls[0]).toEqual(["model", "opus"]);
  const invalid = runner();
  expect(await sendPromptAgain({ ...request, model: "unoffered" }, invalid.deps)).toBe(false);
  expect(invalid.calls).toEqual([]);
  expect(await sendPromptAgain({ ...request, model: "opus" }, { ...invalid.deps, pickModel: async () => false })).toBe(
    false,
  );
  expect(invalid.calls).toEqual([]);
});

test("stale native session and row identifiers are rejected before restoring attachments", async () => {
  const run = runner();
  expect(await sendPromptAgain({ ...request, sessionId: "chat-b" }, run.deps)).toBe(false);
  expect(await sendPromptAgain({ ...request, rowId: "old-summary" }, run.deps)).toBe(false);
  expect(run.calls).toEqual([]);
});

for (const phase of ["model", "restore"] as const)
  test(`a chat switch during ${phase} sends nothing to the newly selected chat`, async () => {
    const run = runner();
    const deps = { ...run.deps };
    if (phase === "model")
      deps.pickModel = async () => {
        run.set({ selectedSessionId: "chat-b" });
        return true;
      };
    else
      deps.restore = async () => {
        run.set({ selectedSessionId: "chat-b" });
        return run.draft;
      };
    expect(await sendPromptAgain({ ...request, model: "opus" }, deps)).toBe(false);
    expect(run.calls.some((call) => Array.isArray(call) && call[0] === "send")).toBe(false);
  });

test("lost send permission, a removed model or a new latest prompt during restore cancels the send", async () => {
  for (const change of [
    { canSend: false },
    { models: [{ id: "sonnet", name: "Sonnet" }] },
    { rows: [prompt, footer, row("user-new", "user", { text: "New prompt" })] },
  ]) {
    const run = runner();
    expect(
      await sendPromptAgain(
        { ...request, model: "opus" },
        {
          ...run.deps,
          restore: async () => {
            run.set(change);
            return run.draft;
          },
        },
      ),
    ).toBe(false);
    expect(run.calls.some((call) => Array.isArray(call) && call[0] === "send")).toBe(false);
  }
});

test("an attachment-only successful prompt keeps its empty text and original attachments", async () => {
  const attachment = {
    id: "image-1",
    kind: "image" as const,
    name: "frame.png",
    mimeType: "image/png",
    size: 1,
    data: "YQ==",
  };
  const attachmentPrompt = { ...prompt, text: "", retryAttachments: [attachment] };
  const current = state({ rows: [attachmentPrompt, answer, { ...footer, prompt: "" }] });
  const calls: unknown[] = [];
  expect(
    await sendPromptAgain(request, {
      read: () => current,
      pickModel: async () => false,
      restore: async (id, text) => {
        calls.push([id, text]);
        return { input: text, attachments: [attachment] };
      },
      send: async (draft) => {
        calls.push(draft);
      },
    }),
  ).toBe(true);
  expect(calls).toEqual([[prompt.id, ""], { input: "", attachments: [attachment] }]);
});

test("a plain resend cannot race an independent model change while attachments restore", async () => {
  const run = runner();
  expect(
    await sendPromptAgain(request, {
      ...run.deps,
      restore: async () => {
        run.set({ currentModel: "opus" });
        return run.draft;
      },
    }),
  ).toBe(false);
  expect(run.calls).toEqual([]);
});

test("an explicit model choice is cancelled if the composer changes models while attachments restore", async () => {
  const run = runner();
  expect(
    await sendPromptAgain(
      { ...request, model: "opus" },
      {
        ...run.deps,
        restore: async () => {
          run.set({ currentModel: "sonnet" });
          return run.draft;
        },
      },
    ),
  ).toBe(false);
  expect(run.calls).toEqual([["model", "opus"]]);
});

test("an explicit model alias remains selected when the agent reports its known release", async () => {
  const run = runner();
  run.set({
    models: [
      { id: "sonnet", name: "Sonnet" },
      { id: "opus", name: "Opus", release: "release-opus" },
      { id: "release-opus", name: "Opus" },
    ],
  });
  expect(
    await sendPromptAgain(
      { ...request, model: "opus" },
      {
        ...run.deps,
        pickModel: async () => {
          run.set({ currentModel: "release-opus" });
          return true;
        },
      },
    ),
  ).toBe(true);
  expect(run.calls).toEqual([
    ["restore", prompt.id, prompt.text],
    ["send", run.draft, "chat-a"],
  ]);
});

test("stopped and interrupted turns retain resend through the menu", () => {
  for (const status of ["cancelled", "interrupted"]) {
    const stopped = state({ rows: [prompt, answer, { ...footer, status }] });
    expect(sendPromptAgainMenu(stopped, t)?.rowId).toBe(footer.id);
    expect(withSendPromptAgain({ text: answer.text! }, answer.id, stopped, t)?.sendPromptAgain?.rowId).toBe(footer.id);
  }
});

test("a landed personal steer retains its own resend in the menu", async () => {
  const steer = row("steer", "user", { at: 3, text: "Also check the caller.", steer: "landed" });
  const projected = turnView([prompt, steer, answer, { ...footer, at: 5 }], new Set(), { working: false, now: 10 });
  const current = state({ rows: projected });
  const target = sendPromptAgainTarget(current)!;
  expect(target.promptId).toBe(steer.id);
  expect(target.prompt).toBe(steer.text!);
  expect(sendPromptAgainMenu(current, t)?.rowId).toBe(footer.id);
  const restored: string[] = [];
  expect(
    await sendPromptAgain(
      { sessionId: "chat-a", rowId: footer.id },
      {
        read: () => current,
        pickModel: async () => true,
        restore: async (id, text) => {
          restored.push(id);
          return text;
        },
        send: async (text) => {
          expect(text).toBe(steer.text!);
        },
      },
    ),
  ).toBe(true);
  expect(restored).toEqual([steer.id]);
});
