// The Task Manager table's sizing (webviews/src/pages/task-manager/styles.css). At the 420px gallery
// width a percentage Task column plus fixed numeric columns once left Process about 29px, every
// executable a fragment such as `c...`. The table now keeps a minimum width and scrolls sideways in
// its scroll box, Task holds 140px at narrow widths, and a remote `host:pid` ellipsizes only its host.
import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";

const css = readFileSync(join(import.meta.dir, "../src/pages/task-manager/styles.css"), "utf8");

/** The declarations of the first rule whose selector is exactly `selector` (optionally inside `within`). */
function rule(selector: string, within = css): Record<string, string> {
  const escaped = selector.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  const match = new RegExp(`(?:^|[}\\s])${escaped}\\s*\\{([^}]*)\\}`, "m").exec(within);
  expect(match, `rule for ${selector}`).not.toBeNull();
  const body = match![1].replace(/\/\*[\s\S]*?\*\//g, "");
  return Object.fromEntries(
    body
      .split(";")
      .map((line) => line.trim())
      .filter(Boolean)
      .map((line) => [line.slice(0, line.indexOf(":")).trim(), line.slice(line.indexOf(":") + 1).trim()]),
  );
}

const px = (value: string | undefined) => Number(/^(\d+)px$/.exec(value ?? "")?.[1] ?? Number.NaN);

test("the table keeps a minimum width that leaves Task about 140px and Process about 110px", () => {
  const table = rule(".tm-table");
  expect(table["table-layout"]).toBe("fixed");
  expect(table.width).toBe("100%");
  const numeric = ["pid", "cpu", "memory"].map((column) => px(rule(`.tm-table th[data-column="${column}"]`).width));
  for (const width of numeric) expect(width).toBeGreaterThan(0);
  const narrow = /@media \(max-width: (\d+)px\)\s*\{([\s\S]*?\})\s*\}/.exec(css);
  expect(narrow).not.toBeNull();
  const task = px(rule('.tm-table th[data-column="task"]', narrow![2]).width);
  expect(task).toBeGreaterThanOrEqual(140);
  const min = px(table["min-width"]);
  const sum = numeric.reduce((a, b) => a + b, 0);
  // At the minimum width Process gets what Task and the numbers leave.
  expect(min - task - sum).toBeGreaterThanOrEqual(110);
  // Above the narrow breakpoint the two split the room evenly; each still has 140px or more.
  expect((Number(narrow![1]) - sum) / 2).toBeGreaterThanOrEqual(140);
  // No percentage Task width survives to squeeze Process.
  expect(css).not.toMatch(/data-column="task"\]\s*\{[^}]*width:\s*\d+%/);
});

test("the scroll box scrolls both ways, so the sticky header scrolls sideways with the rows", () => {
  expect(rule(".tm-table-scroll").overflow).toBe("auto");
  const header = rule(".tm-table thead th");
  expect(header.position).toBe("sticky");
  expect(header.top).toBe("0");
});

test("a remote id ellipsizes only its host; the pid never shrinks", () => {
  const cells = rule(".tm-row td");
  expect(cells["text-overflow"]).toBe("ellipsis");
  expect(rule(".tm-remote-id").display).toBe("flex");
  const hostPart = rule(".tm-remote-host");
  expect(hostPart["min-width"]).toBe("0");
  expect(hostPart["text-overflow"]).toBe("ellipsis");
  expect(hostPart.overflow).toBe("hidden");
  expect(rule(".tm-remote-pid").flex).toBe("none");
});
