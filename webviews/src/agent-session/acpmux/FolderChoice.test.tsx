import { expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import { FolderChoice } from "./FolderChoice";

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
