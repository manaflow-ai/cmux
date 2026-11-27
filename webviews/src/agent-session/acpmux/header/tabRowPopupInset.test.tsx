// While a chat's header tools sit in the pane's tab row, the native row draws over the page's top,
// so menus and popovers keep below it (ui/popupInset.ts): a model menu that reached into it opened
// under the tabs with its top cut off (Leo 2026-10-25).
import { afterEach, expect, test } from "bun:test";
import { renderToString } from "react-dom/server";
import { usePopupPadding } from "../../../ui/popupInset";
import { setTabRow } from "./tabRow";

function Padding() {
  const padding = usePopupPadding();
  return <i>{`${padding.top} ${padding.right} ${padding.bottom} ${padding.left}`}</i>;
}

const padding = () => renderToString(<Padding />).replace(/<\/?i>/g, "");

afterEach(() => setTabRow({ height: 0 }));

test("with no tab row, popups keep Base UI's padding on every edge", () => {
  setTabRow({ height: 0 });
  expect(padding()).toBe("5 5 5 5");
});

test("an offered tab row keeps popups below it", () => {
  setTabRow({ height: 28, trailingInset: 40 });
  expect(padding()).toBe("33 5 5 5");
});

test("the row ending gives the page's top back", () => {
  setTabRow({ height: 28, trailingInset: 0 });
  setTabRow({});
  expect(padding()).toBe("5 5 5 5");
});
