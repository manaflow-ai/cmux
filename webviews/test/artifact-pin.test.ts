// W2-17: pinning preserves a document's provenance when the reader changes chats.
import { expect, test } from "bun:test";
import type { Artifact } from "../src/agent-session/acpmux/conversation/artifactPreview";
import {
  artifactVersionsForSession,
  changeArtifactPin,
  visibleArtifact,
  type OpenedArtifact,
} from "../src/agent-session/acpmux/conversation/artifactPin";

const v1: Artifact = { kind: "html", lang: "html", code: "<title>Review</title><p>Pass</p>" };
const v2: Artifact = { kind: "html", lang: "html", code: "<title>Review</title><p>Warn</p>" };
const unrelated: Artifact = { kind: "html", lang: "html", code: "<title>Review</title><p>Other chat</p>" };

test("un-pinned previews close at a session switch; Pin preserves source versions only", () => {
  const opened: OpenedArtifact = { ...v2, sessionId: "chat-a", opened: 1 };
  expect(visibleArtifact(opened, "chat-b")).toBeUndefined();

  const pinned = changeArtifactPin(opened, true, "chat-a", [v1, v2])!;
  expect(pinned.pinned).toBe(true);
  expect(visibleArtifact(pinned, "chat-b")).toBe(pinned);

  // Chat B happens to produce a document with the same title. It is never version 3 of A.
  expect(artifactVersionsForSession(pinned, "chat-b", [unrelated])).toEqual([v1, v2]);
  expect(artifactVersionsForSession(pinned, undefined, [unrelated])).toEqual([v1, v2]);
  // Returning to A during paging can temporarily expose only one version. Keep both pinned.
  expect(artifactVersionsForSession(pinned, "chat-a", [v2])).toEqual([v1, v2]);
  expect(artifactVersionsForSession(pinned, "chat-a", [])).toEqual([v1, v2]);
  // Once A's complete history is available, its genuinely new revision becomes visible.
  expect(artifactVersionsForSession(pinned, "chat-a", [v1, v2, unrelated])).toEqual([v1, v2, unrelated]);
});

test("Pin snapshots the versions, Unpin in the source chat resumes its live list", () => {
  const opened: OpenedArtifact = { ...v2, sessionId: "chat-a", opened: 3 };
  const versions = [v1, v2];
  const pinned = changeArtifactPin(opened, true, "chat-a", versions)!;
  versions.push(unrelated);
  expect(artifactVersionsForSession(pinned, "chat-b")).toEqual([v1, v2]);

  const unpinned = changeArtifactPin(pinned, false, "chat-a")!;
  expect(unpinned.pinned).toBe(false);
  expect(unpinned.pinVersions).toBeUndefined();
  expect(artifactVersionsForSession(unpinned, "chat-a", [v1, v2, unrelated])).toHaveLength(3);
  expect(visibleArtifact(unpinned, "chat-b")).toBeUndefined();
});

test("Unpin in a different chat closes; opening without an owning session cannot be pinned", () => {
  const opened: OpenedArtifact = { ...v1, sessionId: "chat-a", opened: 2 };
  const pinned = changeArtifactPin(opened, true, "chat-a")!;
  expect(artifactVersionsForSession(pinned, "chat-b")).toEqual([opened]);
  expect(changeArtifactPin(pinned, false, "chat-b")).toBeUndefined();
  expect(changeArtifactPin(undefined, true, "chat-a")).toBeUndefined();
  expect(changeArtifactPin({ ...v1, opened: 1 }, true, undefined)?.pinned).toBeUndefined();
  expect(changeArtifactPin(opened, true, "chat-b")).toBe(opened);
});
