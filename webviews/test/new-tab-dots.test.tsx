// New Tab uses the standard controls even in gallery previews of the former chat layout.
import { afterAll, expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import { setPreviewComposerLook, useComposerLook } from "../src/agent-session/acpmux/composerLook";
import { OnNewTab } from "../src/agent-session/acpmux/newTabComposer";

function Look() {
  return <span>{useComposerLook()}</span>;
}

afterAll(() => setPreviewComposerLook());

for (const look of ["claude", "codex"] as const) {
  test(`New Tab keeps Claude when the preview look is ${look}`, () => {
    setPreviewComposerLook(look);
    expect(
      renderToStaticMarkup(
        <OnNewTab.Provider value={true}>
          <Look />
        </OnNewTab.Provider>,
      ),
    ).toBe("<span>claude</span>");
    expect(renderToStaticMarkup(<Look />)).toBe(`<span>${look}</span>`);
  });
}
