import { afterEach, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act, useState } from "react";
import { createRoot, type Root } from "react-dom/client";
import { EditFeedback, SaveConflictDialog } from "../src/App";

let dom: JSDOM | null = null;
let root: Root | null = null;
const originalWindow = globalThis.window;
const originalDocument = globalThis.document;
const originalNavigator = globalThis.navigator;
const originalActEnvironment = (globalThis as any).IS_REACT_ACT_ENVIRONMENT;

afterEach(async () => {
  if (root) {
    await act(async () => root?.unmount());
  }
  root = null;
  await new Promise((resolve) => setTimeout(resolve, 0));
  dom?.window.close();
  dom = null;
  (globalThis as any).window = originalWindow;
  (globalThis as any).document = originalDocument;
  (globalThis as any).navigator = originalNavigator;
  (globalThis as any).IS_REACT_ACT_ENVIRONMENT = originalActEnvironment;
});

test("save conflict feedback opens a disk-versus-draft comparison and can overwrite", async () => {
  installDom();
  let overwriteCount = 0;

  function Harness() {
    const [open, setOpen] = useState(false);
    return (
      <>
        <EditFeedback
          error
          label={(key) => key}
          message="story.txt changed on disk"
          recovery="conflict"
          saving={false}
          onCompare={() => setOpen(true)}
          onOverwrite={() => { overwriteCount += 1; }}
          onRetry={() => {}}
        />
        {open ? (
          <SaveConflictDialog
            conflict={{
              diskContents: "external\n",
              draftContents: "draft\n",
              itemId: "story.txt",
              path: "story.txt",
            }}
            label={(key) => key}
            saving={false}
            onClose={() => setOpen(false)}
            onOverwrite={() => { overwriteCount += 1; }}
          />
        ) : null}
      </>
    );
  }

  act(() => root?.render(<Harness />));
  const feedbackButtons = dom!.window.document.querySelectorAll<HTMLButtonElement>("#edit-feedback button");
  expect(Array.from(feedbackButtons, (button) => button.textContent)).toEqual(["compare", "overwrite"]);

  await act(async () => feedbackButtons[0]?.click());

  const dialog = dom!.window.document.getElementById("edit-conflict-dialog");
  expect(dialog?.getAttribute("role")).toBe("dialog");
  expect(dialog?.textContent).toContain("story.txt");
  expect(dialog?.textContent).toContain("external");
  expect(dialog?.textContent).toContain("draft");
  (dialog?.querySelector(".edit-conflict-overwrite") as HTMLButtonElement).click();
  expect(overwriteCount).toBe(1);
});

test("generic save feedback exposes retry without discarding the message", () => {
  installDom();
  let retryCount = 0;

  act(() => root?.render(
    <EditFeedback
      error
      label={(key) => key}
      message="Your edits are still available"
      recovery="retry"
      saving={false}
      onCompare={() => {}}
      onOverwrite={() => {}}
      onRetry={() => { retryCount += 1; }}
    />,
  ));

  expect(dom!.window.document.getElementById("edit-feedback")?.textContent).toContain("Your edits are still available");
  const retry = dom!.window.document.querySelector("#edit-feedback button") as HTMLButtonElement;
  expect(retry.textContent).toBe("retry");
  retry.click();
  expect(retryCount).toBe(1);
});

function installDom() {
  dom = new JSDOM("<!doctype html><html><body><div id='root'></div></body></html>", {
    url: "http://127.0.0.1/diff",
  });
  (globalThis as any).window = dom.window;
  (globalThis as any).document = dom.window.document;
  (globalThis as any).navigator = dom.window.navigator;
  (globalThis as any).IS_REACT_ACT_ENVIRONMENT = true;
  root = createRoot(dom.window.document.getElementById("root")!);
}
