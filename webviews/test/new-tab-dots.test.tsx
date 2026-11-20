// New Tab fixes the shared controls to Claude without changing the saved chat look.
import { afterAll, expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import { savedComposerLook, setComposerLook, useComposerLook } from "../src/agent-session/acpmux/composerLook";
import { OnNewTab } from "../src/agent-session/acpmux/newTabComposer";

function Look() {
  return <span>{useComposerLook()}</span>;
}

afterAll(() => setComposerLook("codex"));

for (const look of ["claude", "codex"] as const) {
  test(`New Tab keeps Claude when the chat look is ${look}`, () => {
    setComposerLook(look);
    expect(
      renderToStaticMarkup(
        <OnNewTab.Provider value={true}>
          <Look />
        </OnNewTab.Provider>,
      ),
    ).toBe("<span>claude</span>");
    expect(renderToStaticMarkup(<Look />)).toBe(`<span>${look}</span>`);
    expect(savedComposerLook()).toBe(look);
  });
}
