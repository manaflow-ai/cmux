// Popups keep below the deepest thing covering the page's top: the tab row, and Find in Chat's bar
// while it shows (Leo 2026-11-07: "we don't want it to be coverable by other sorts of things").
import { afterEach, expect, test } from "bun:test";
import { renderToString } from "react-dom/server";
import { setPopupInsetTop, usePopupPadding } from "./popupInset";

function Padding() {
  return <i>{usePopupPadding().top}</i>;
}

const top = () => renderToString(<Padding />).replace(/<\/?i>/g, "");

afterEach(() => {
  setPopupInsetTop(0);
  setPopupInsetTop(0, "findBar");
});

test("an open find bar deeper than the tab row keeps popups below the bar", () => {
  setPopupInsetTop(28);
  setPopupInsetTop(52, "findBar");
  expect(top()).toBe("57");
});

test("closing the find bar gives popups back the tab row's inset", () => {
  setPopupInsetTop(28);
  setPopupInsetTop(52, "findBar");
  setPopupInsetTop(0, "findBar");
  expect(top()).toBe("33");
});
