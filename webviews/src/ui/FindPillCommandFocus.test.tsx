// Lawrence, 2026-11-15 ("the first Cmd+F press misses"): Cmd-F sends a page its find command, and the page focuses
// this field in its own turn. The app keeps the letters typed meanwhile until focus is on the field the command
// opened, which it knows by `data-cmux-command-focus="find"` (PageInputReadiness.awaitFocus(on:)). Every find bar
// renders this one pill, so each one's field carries the mark; the replace field does not.
import { act } from "react";
import { afterAll, expect, test } from "bun:test";
import { installDom } from "../pages/settings/testDom";

const restore = installDom();
afterAll(() => restore());
const { createRoot } = await import("react-dom/client");
const { FindPill } = await import("./FindPill");

test("the find field carries the command focus mark, the replace field does not", async () => {
  const host = document.createElement("div");
  document.body.append(host);
  const root = createRoot(host);
  const none = () => undefined;
  await act(async () =>
    root.render(
      <FindPill
        query=""
        onQueryChange={none}
        status=""
        noMatches={false}
        canStep={false}
        onNext={none}
        onPrevious={none}
        onClose={none}
        labels={{ placeholder: "Find", previous: "Previous", next: "Next", close: "Close" }}
        icon={() => null}
        replace={{
          open: true,
          value: "",
          onChange: none,
          onReplace: none,
          onReplaceAll: none,
          labels: { field: "Replace", replace: "Replace", replaceAll: "All", toggle: "Toggle" },
        }}
      />,
    ),
  );
  const marked = host.querySelectorAll("[data-cmux-command-focus]");
  expect(marked.length).toBe(1);
  expect(marked[0]?.getAttribute("data-cmux-command-focus")).toBe("find");
  expect(marked[0]?.getAttribute("aria-label")).toBe("Find");
  await act(async () => root.unmount());
  host.remove();
});
