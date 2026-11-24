// l10n-allow-file: sender/session fixtures.
import { expect, test } from "bun:test";
import { sessionEntry, sessionTitle, formerName } from "./sessionList";
import { newestFormerName } from "./AgentIdentityChip";
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

test("legacy remote hosts survive an omitted kind while known local hosts stay hidden", () => {
  const legacyRemote = sessionEntry({ sessionId: "legacy-remote", name: "chief-ui", host: "studio-mac" });
  expect(resolveSenderIdentity({ name: "chief-ui", sessionId: "legacy-remote" }, legacyRemote).host).toBe("studio-mac");

  const local = sessionEntry({ sessionId: "local", name: "coordinator", host: "This Mac", hostKind: "local" });
  expect(resolveSenderIdentity({ name: "coordinator", sessionId: "local" }, local).host).toBeUndefined();
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
            center: 0,
            viewportHeight: 700,
            prompt: "Review ready.",
            from: "syntax-check",
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

// Leo, 2026-11-23: "the send/recieve messages are still only the older names".
test("a received line names its sender by the given name, listed or carried by the message", () => {
  const listed = sessionEntry({
    sessionId: "coord-old",
    name: "studio-mac/claude-sr2-coord-old",
    peer: "studio-mac",
    displayName: "Mango",
  });
  const identity = resolveSenderIdentity({ name: "studio-mac/claude-sr2-coord-old", sessionId: "coord-old" }, listed);
  expect(identity.name).toBe("Mango");
  expect(identity.host).toBe("studio-mac");
  // Not listed here (an older peer's row): the name its message carried.
  expect(resolveSenderIdentity({ name: "claude-sr2-coord-old", displayName: "Mango" }).name).toBe("Mango");
  // No given name: the session's name, as before.
  expect(resolveSenderIdentity({ name: "lane-a" }).name).toBe("lane-a");

  const message = incomingPrompt("PR is green", {
    client: "acpmux-peer#fixture",
    _meta: {
      provenance: {
        kind: "agent_message",
        from: "fromAgent",
        fromName: "studio-mac/claude-sr2-coord-old",
        fromDisplayName: "Mango",
      },
    },
  });
  expect(message?.kind === "message" && message.message.displayName).toBe("Mango");
  expect(message?.kind === "message" && message.message.name).toBe("studio-mac/claude-sr2-coord-old");
});

// Leo, 2026-11-22: "BUT WHO IS MANGO? ... RENAMES NEED TO BE PROPAGATED TO THE VISIBLE AREAS".
test("a given name (acpmux displayName) is the title and the sender's name everywhere", () => {
  const entry = sessionEntry({
    sessionId: "mango",
    name: "claude-sr2-coord",
    title: "Coordinate the fleet",
    harness: "claude",
    displayName: "Mango",
    formerNames: ["claude-sr2-7", "claude-sr2-coord-old"],
    icon: { kind: "emoji", text: "🥭", source: "session" },
  });
  expect(entry.displayTitle).toBe("Mango");
  expect(entry.displayName).toBe("Mango");
  expect(entry.formerNames).toEqual(["claude-sr2-7", "claude-sr2-coord-old"]);
  expect(entry.icon).toEqual({ kind: "emoji", text: "🥭", source: "session" });
  expect(sessionTitle({ sessionId: "x", name: "lane-name", displayName: "  Mango " })).toBe("Mango");
  const identity = resolveSenderIdentity(
    { name: "claude-sr2-coord", sessionId: "mango" },
    { ...entry, shortName: "coord" },
  );
  expect(identity.name).toBe("Mango");
  expect(identity.icon?.kind).toBe("emoji");
  expect(identity.formerNames).toEqual(["claude-sr2-7", "claude-sr2-coord-old"]);
});

test("no given name reads as before; a blank one and malformed fields are ignored", () => {
  const entry = sessionEntry({
    sessionId: "plain",
    name: "pr-row",
    displayName: "   ",
    formerNames: ["", 3, "old-row"],
    icon: { kind: "image", mime: "text/html", data: "PHNjcmlwdD4=" },
  });
  expect(entry.displayTitle).toBe("pr-row");
  expect(entry.formerNames).toEqual(["old-row"]);
  expect(entry.icon).toBeUndefined();
  expect(resolveSenderIdentity({ name: "pr-row", sessionId: "plain" }, entry).name).toBe("pr-row");
  expect(sessionEntry({ sessionId: "never", name: "x" }).formerNames).toBeUndefined();
});

test("fka is the newest former name that is not the name shown", () => {
  expect(newestFormerName("Mango", ["claude-sr2-7", "claude-sr2-coord-old"])).toBe("claude-sr2-coord-old");
  expect(newestFormerName("Mango", ["old", "Mango"])).toBe("old");
  expect(newestFormerName("Mango", ["Mango"])).toBeUndefined();
  expect(newestFormerName("Mango", undefined)).toBeUndefined();
  expect(formerName({ displayTitle: "Mango", formerNames: ["a", "b"] })).toBe("b");
});

test("a sender signed with its given name or a former name finds its chat; a current name wins", () => {
  const store = new SubsessionStore();
  store.set([
    sessionEntry({
      sessionId: "mango",
      name: "claude-sr2-coord",
      displayName: "Mango",
      formerNames: ["coord-old", "taken"],
    }),
    sessionEntry({ sessionId: "other", name: "taken" }),
  ]);
  expect(store.find("Mango")).toBe("mango");
  expect(store.find("coord-old")).toBe("mango");
  expect(store.find("taken")).toBe("other");
  expect(store.sender("mango")?.displayName).toBe("Mango");
});
