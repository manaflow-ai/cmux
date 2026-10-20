import { expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { renderToStaticMarkup } from "react-dom/server";
import { annotateDiffMetadata, DiffHeaderMetadata, resolveDiffHeaderMetadata } from "../src/diff-metadata";
import { createDiffViewerLabelResolver } from "../src/labels";

test("binary and mode-only diffs render explicit localized header metadata", () => {
  const binary = {
    type: "change",
    hunks: [],
    prevObjectId: "1111111",
    newObjectId: "2222222",
    mode: "100644",
  };
  const mode = {
    type: "change",
    hunks: [],
    prevMode: "100644",
    mode: "100755",
  };
  annotateDiffMetadata(binary, "GIT binary patch\n");
  annotateDiffMetadata(mode);
  const label = createDiffViewerLabelResolver({
    binaryFile: "Localized binary",
    modeChange: "Permissions {old} to {new}",
  });
  expect(resolveDiffHeaderMetadata(binary, label)).toBe("Localized binary");
  expect(resolveDiffHeaderMetadata(mode, label)).toBe("Permissions 100644 to 100755");

  const html = renderToStaticMarkup(
    <>
      <DiffHeaderMetadata fileDiff={binary} label={label} />
      <DiffHeaderMetadata fileDiff={mode} label={label} />
    </>,
  );
  const dom = new JSDOM(`<div id="root">${html}</div>`);
  const container = dom.window.document.getElementById("root")!;
  expect(container.querySelector('[data-cmux-diff-metadata="binary"]')?.textContent).toBe("Localized binary");
  expect(container.querySelector('[data-cmux-diff-metadata="mode"]')?.textContent).toBe("Permissions 100644 to 100755");
  dom.window.close();
});
