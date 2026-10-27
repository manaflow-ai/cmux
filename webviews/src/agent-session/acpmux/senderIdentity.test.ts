// l10n-allow-file: sender/session fixtures.
import { expect, test } from "bun:test";
import { sessionEntry, sessionTitle } from "./sessionList";
import { incomingPrompt } from "./conversation/incomingMessage";
import { resolveSenderIdentity } from "./senderIdentity";
import { SubsessionStore } from "./subagents/subsessions";
import { createElement } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { SubsessionContext } from "./subagents/subsessions";
import { PromptMarksSession } from "./threadMinimap/promptMarks";
import { PreviewCard } from "./threadMinimap/PreviewCard";

test("a peer's session name is the headline, not the peer machine", () => {
  const remote = sessionEntry({
    sessionId: "peer-review",
    name: "gcp-codex-lane-10/pr-row",
    peer: "gcp-codex-lane-10",
    harness: "codex",
  });
  expect(sessionTitle(remote)).toBe("pr-row");
  expect(remote.displayTitle).toBe("pr-row");
  expect(remote.peer).toBe("gcp-codex-lane-10");
});

test("an ordinary slash in a session name is preserved without peer metadata", () => {
  expect(sessionTitle({ sessionId: "local", name: "team/review" })).toBe("team/review");
});

test("qualified short names and blank candidates cannot replace the session headline with its host", () => {
  const sender = { name: "recorded-sender" };
  const entry = sessionEntry({ sessionId: "peer-review", name: "peer/canonical", peer: "peer" });
  for (const shortName of ["peer/pr-row", "  peer/pr-row  "])
    expect(resolveSenderIdentity(sender, { ...entry, shortName }).name).toBe("pr-row");
  for (const shortName of ["", "   ", "peer/"])
    expect(resolveSenderIdentity(sender, { ...entry, shortName }).name).toBe("canonical");
  expect(resolveSenderIdentity(sender, { ...entry, name: " ", shortName: " " }).name).toBe("recorded-sender");
});

test("a body signature cannot replace the recorded sender's identity", () => {
  const message = incomingPrompt("From gcp-codex-lane-10. The review is ready.", {
    client: "acpmux-peer#fixture",
    _meta: {
      provenance: {
        kind: "agent_message",
        from: "fromAgent",
        fromName: "gcp-codex-lane-10/pr-row",
      },
    },
  });
  expect(message?.kind === "message" && message.message.name).toBe("gcp-codex-lane-10/pr-row");
});

test("session metadata names the harness and child relationship without guessing from the name", () => {
  const entry = sessionEntry({
    sessionId: "child",
    name: "gcp-codex-lane-10/pr-row",
    peer: "gcp-codex-lane-10",
    harness: "codex",
    startedBy: "parent",
  });
  expect(resolveSenderIdentity({ name: "gcp-codex-lane-10", sessionId: "child" }, entry, "parent")).toEqual({
    name: "pr-row",
    sessionId: "child",
    harness: "codex",
    host: "gcp-codex-lane-10",
    relation: "subsession",
    known: true,
  });
  const unrelated = resolveSenderIdentity({ name: "codex-reviewer" }, undefined, "parent");
  expect(unrelated).toEqual({ name: "codex-reviewer", known: false });
  expect(resolveSenderIdentity({ name: "pr-row" }, entry, "elsewhere").relation).toBeUndefined();
  // A name lookup may find an existing chat, but cannot prove that chat authored this message.
  expect(resolveSenderIdentity({ name: "pr-row" }, entry, "parent").relation).toBeUndefined();
});

test("a peer session leaving the list cannot leave its harness or machine on another sender", () => {
  const store = new SubsessionStore();
  const remote = sessionEntry({ sessionId: "remote", name: "peer/review", peer: "peer", harness: "codex" });
  store.set([remote]);
  expect(store.sender("remote")).toBe(remote);
  const identity = resolveSenderIdentity({ name: "review", sessionId: "remote" }, store.sender("remote"));
  expect(identity).toMatchObject({ name: "review", harness: "codex", host: "peer" });
  store.set([sessionEntry({ sessionId: "local", name: "review", harness: "claude" })]);
  expect(store.sender("remote")).toBeUndefined();
  expect(resolveSenderIdentity({ name: "review", sessionId: "remote" }, store.sender("remote"))).toEqual({
    name: "review",
    sessionId: "remote",
    known: true,
  });
  expect(store.find("review")).toBe("local");
});

test("the minimap reads the same current-session relationship as the transcript", () => {
  const store = new SubsessionStore();
  store.set([sessionEntry({ sessionId: "child", name: "syntax-check", spawnedBy: "parent", harness: "claude" })]);
  const render = (viewer: string) =>
    renderToStaticMarkup(
      createElement(
        SubsessionContext.Provider,
        { value: { store, open: () => {} } },
        createElement(
          PromptMarksSession.Provider,
          { value: viewer },
          createElement(PreviewCard, {
            id: "card",
            x: 0,
            y: 0,
            prompt: "Review ready.",
            reply: [],
            metadata: { at: 1, links: [], sender: { name: "syntax-check", sessionId: "child" } },
            onPointerLeave: () => {},
          }),
        ),
      ),
    );
  expect(render("parent")).toContain("Sub-session · syntax-check");
  expect(render("another-session")).toContain("syntax-check · Other session");
});
