// A hidden idle chat that gave back its page (HiddenChatPages) comes back from its wake state, which carries the
// composer's draft but not an edit elsewhere on the page, such as a queued message being edited
// (review F1 on #37895). `pageEditHold` names such an edit so the release keeps the page.
import { expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { holdWebSwap, pageEditHold, pageReleaseHold, WEB_SWAP_KEPT_TEXT } from "./webSwap";

const page = (body: string) => new JSDOM(`<!doctype html><body>${body}</body>`).window.document;

test("an edited queued message holds the page while the kept composer is empty", () => {
  const doc = page(
    `<div ${WEB_SWAP_KEPT_TEXT}=""><textarea></textarea></div><textarea id="queued">send this</textarea>`,
  );
  const queued = doc.getElementById("queued") as HTMLTextAreaElement;
  queued.value = "send this, edited";
  expect(pageEditHold(doc)).toBe("field");
});

test("clearing a queued message is an edit too", () => {
  const doc = page(`<textarea id="queued">send this</textarea>`);
  (doc.getElementById("queued") as HTMLTextAreaElement).value = "";
  expect(pageEditHold(doc)).toBe("field");
});

test("a page with only its kept composer holds nothing", () => {
  const doc = page(`<div ${WEB_SWAP_KEPT_TEXT}=""><textarea>a saved draft</textarea></div>`);
  expect(pageEditHold(doc)).toBeNull();
});

// Review F1 on #42978: shell mode comes back from the wake state (`shell`, `shellText`), so a chat left
// in it is still let go; a web swap, which carries no wake state, keeps waiting on it.
test("shell mode alone does not hold a hidden chat's page, but an unsaved edit beside it does", () => {
  const doc = page(`<div ${WEB_SWAP_KEPT_TEXT}=""><textarea>make</textarea></div>`);
  const release = holdWebSwap(() => "composer.shell");
  try {
    expect(pageEditHold(doc)).toBeNull();
    expect(pageReleaseHold(doc)).toBe("composer.shell");
    const sending = holdWebSwap(() => "composer.sending");
    try {
      expect(pageEditHold(doc)).toBe("composer.sending");
    } finally {
      sending();
    }
  } finally {
    release();
  }
});
