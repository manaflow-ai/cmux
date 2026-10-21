// The sidebar's icon rail and the chat's session rail are two components; the pane loads both
// sheets, so the session rail's 240-340px column (summary.css) must not land on the 48px icon rail.
import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { Window } from "happy-dom";
import { renderToStaticMarkup } from "react-dom/server";
import { SessionSidebar } from "../src/agent-session/acpmux/SessionSidebar";

const sheet = (path: string) => readFileSync(new URL(path, import.meta.url), "utf8");

test("the sidebar's icon rail keeps its own layout with the session rail's sheet loaded", () => {
  const markup = renderToStaticMarkup(<SessionSidebar sessions={[]} onSelect={() => {}} />);
  const window = new Window({ width: 900, height: 600 });
  const { document } = window;
  for (const css of [
    sheet("../src/agent-session/acpmux/styles.css"),
    sheet("../src/agent-session/acpmux/summary/summary.css"),
  ]) {
    const style = document.createElement("style");
    style.textContent = css;
    document.head.append(style);
  }
  document.body.innerHTML = markup;
  const rail = document.querySelector("nav.acpmux-sidebar > div")!;
  expect(rail.querySelector("button")).not.toBeNull();
  const computed = window.getComputedStyle(rail);
  // happy-dom drops the session rail's clamp() basis, so check the plain values both rules set.
  expect([computed.alignItems, computed.paddingLeft]).toEqual(["center", "0px"]);
  expect(computed.overflowY).not.toBe("auto");
  void window.happyDOM.close();
});
