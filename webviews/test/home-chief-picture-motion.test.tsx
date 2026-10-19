// home.chiefPictureMotion (backgrounds plan phase 5): a Chief's GIF moves always, only while
// pointed at (the default), or never; the app says which with data-picture-motion on <html>.
import { act } from "react";
import { afterAll, expect, test } from "bun:test";
import { installDom } from "../src/pages/settings/testDom";

const restore = installDom();
afterAll(() => restore());
const { createRoot } = await import("react-dom/client");
const { Avatar, PicturesContext } = await import("../src/pages/home-channels/Avatar");
const { mayAnimate, pictureMotion } = await import("../src/pages/home-channels/pictureMotion");

const GIF = "data:image/gif;base64,R0lGODlhAQABAAAAACw=";
const PNG = "data:image/png;base64,iVBORw0KGgo=";

function render(picture: string) {
  const host = document.createElement("div");
  document.body.append(host);
  const root = createRoot(host);
  act(() =>
    root.render(
      <PicturesContext.Provider value={new Map([["agent_1", picture]])}>
        <Avatar participant={{ id: "agent_1", kind: "agent", name: "Ada", chief: true }} size={32} />
      </PicturesContext.Provider>,
    ),
  );
  return { host, unmount: () => act(() => root.unmount()) };
}

test("only GIF and WebP pictures may move, and the motion defaults to hover", () => {
  expect(mayAnimate(GIF)).toBe(true);
  expect(mayAnimate("data:image/webp;base64,AAAA")).toBe(true);
  expect(mayAnimate("https://example.com/cat.gif?x=1")).toBe(true);
  expect(mayAnimate(PNG)).toBe(false);
  document.documentElement.removeAttribute("data-picture-motion");
  expect(pictureMotion()).toBe("hover");
  document.documentElement.setAttribute("data-picture-motion", "never");
  expect(pictureMotion()).toBe("never");
});

test("a GIF moves when the app says always, and is never shown moving when it says never", async () => {
  document.documentElement.setAttribute("data-picture-motion", "always");
  const always = render(GIF);
  expect(always.host.querySelector("img")?.getAttribute("src")).toBe(GIF);
  always.unmount();
  document.documentElement.setAttribute("data-picture-motion", "never");
  const never = render(GIF);
  await act(async () => new Promise((resolve) => setTimeout(resolve, 20)));
  expect(never.host.querySelector("img")?.getAttribute("src")).not.toBe(GIF);
  never.unmount();
  // A still picture is never held back.
  const still = render(PNG);
  expect(still.host.querySelector("img")?.getAttribute("src")).toBe(PNG);
  still.unmount();
});

test("on hover, a GIF moves only while pointed at", async () => {
  document.documentElement.setAttribute("data-picture-motion", "hover");
  const view = render(GIF);
  const tile = view.host.querySelector<HTMLElement>(".hc-avatar")!;
  expect(view.host.querySelector("img")?.getAttribute("src")).not.toBe(GIF);
  await act(async () => tile.dispatchEvent(new window.PointerEvent("pointerover", { bubbles: true })));
  expect(view.host.querySelector("img")?.getAttribute("src")).toBe(GIF);
  await act(async () => tile.dispatchEvent(new window.PointerEvent("pointerout", { bubbles: true })));
  expect(view.host.querySelector("img")?.getAttribute("src")).not.toBe(GIF);
  view.unmount();
});
