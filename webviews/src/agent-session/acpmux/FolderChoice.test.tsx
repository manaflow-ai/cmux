import { expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import { FolderChoice, showsFolderChoice } from "./FolderChoice";

// A new chat in a workspace without a folder says where it runs and offers Choose Folder….
test("the line names the private folder and offers Choose Folder as a button", () => {
  const html = renderToStaticMarkup(<FolderChoice onChoose={() => undefined} />);
  expect(html).toContain("New chats in this workspace start in a private folder.");
  expect(html).toContain('<button type="button" class="acpmux-folder-choice-button">Choose Folder…</button>');
  expect(html).not.toContain('role="alert"');
});

// The host's refusal (an older background service) is shown, never swallowed.
test("a refusal shows the host's text after the button", () => {
  const message = "Restart cmux's background service to use Choose Folder.";
  const html = renderToStaticMarkup(<FolderChoice onChoose={() => undefined} error={message} />);
  expect(html).toContain('<span role="alert">Restart cmux&#x27;s background service to use Choose Folder.</span>');
});

// hq5cah live check (cmux-lawrence-2, 03-chat.png): a new chat starts its session at once (the
// prewarmed process, `ensureSession`), and the line was hidden as soon as the chat had a session.
// The line shows while the chat is new and runs in agent-home, with or without its session.
test("a new agent-home chat shows the line also after its session started", () => {
  const offered = { offered: true, freshChat: true, quick: false, projectDraft: undefined };
  expect(showsFolderChoice({ ...offered, sessionId: undefined })).toBe(true);
  expect(showsFolderChoice({ ...offered, sessionId: "s-prewarmed" })).toBe(true);
});

// No line where it would be wrong: the host did not offer it (the workspace has a folder), a chat
// with turns, the Quick Composer, or a project the user already picked for this draft.
test("the line hides without the offer, after the first turn, in the Quick Composer or with a picked project", () => {
  const base = { offered: true, freshChat: true, quick: false, projectDraft: undefined, sessionId: "s" };
  expect(showsFolderChoice({ ...base, offered: false })).toBe(false);
  expect(showsFolderChoice({ ...base, freshChat: false })).toBe(false);
  expect(showsFolderChoice({ ...base, quick: true })).toBe(false);
  expect(showsFolderChoice({ ...base, projectDraft: "/Users/me/project" })).toBe(false);
});
