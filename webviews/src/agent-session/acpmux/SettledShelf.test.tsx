import { expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import { session } from "../../gallery/fixtures/acpmux";
import { SettledShelf } from "./SettledShelf";

test("only the rows of chats the pane holds have Unsettle; every row opens its chat", () => {
  const rows = [
    session({ sessionId: "held", title: "Held chat", archived: true, settled: "merged" }),
    session({ sessionId: "other", title: "Other chat", archived: true, settled: "closed" }),
  ];
  const html = renderToStaticMarkup(
    <SettledShelf
      rows={rows}
      total={rows.length}
      open
      onSelect={() => undefined}
      onUnsettle={() => undefined}
      holds={(entry) => entry.sessionId === "held"}
    />,
  );
  expect(html.match(/acpmux-settled-unsettle/g)?.length).toBe(1);
  expect(html.match(/class="acpmux-home-row"/g)?.length).toBe(2);
  expect(html.indexOf("acpmux-settled-unsettle")).toBeLessThan(html.indexOf("Other chat"));
});

test("the shelf starts collapsed to its count, and is absent with no settled chat", () => {
  const rows = [session({ sessionId: "a", title: "A", archived: true, settled: "idle" })];
  const collapsed = renderToStaticMarkup(
    <SettledShelf rows={rows} total={4} onSelect={() => undefined} onUnsettle={() => undefined} holds={() => true} />,
  );
  expect(collapsed).toContain('aria-expanded="false"');
  expect(collapsed).toContain(">4<");
  expect(collapsed).not.toContain("acpmux-settled-unsettle");
  const empty = renderToStaticMarkup(
    <SettledShelf rows={[]} total={0} onSelect={() => undefined} onUnsettle={() => undefined} holds={() => true} />,
  );
  expect(empty).toBe("");
});
