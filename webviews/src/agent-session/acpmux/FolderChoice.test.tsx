import { expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import { FolderChoice } from "./FolderChoice";

// A new chat in a workspace without a folder says where it runs and offers Choose Folder….
test("the line names the private folder and offers Choose Folder as a button", () => {
  const html = renderToStaticMarkup(<FolderChoice onChoose={() => undefined} />);
  expect(html).toContain("New chats in this workspace start in a private folder.");
  expect(html).toContain('<button type="button" class="acpmux-folder-choice-button">Choose Folder…</button>');
});
