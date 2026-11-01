// l10n-allow-file: fixture workflow actions, not shipped UI.
// Session Info's workflow agent rows (session-info/WorkflowTasks.tsx) in the gallery's compact
// alternative (agent-pane.chat-inspector, workflow-agent-row-compact): the name and the current
// action share one line. Before, the row's text was a block, so the action was an inline span that
// `overflow: hidden` and `text-overflow` do not clip, and a long action ran past the panel with no
// ellipsis (#28774's review). Now the action shrinks inside the row and ends in an ellipsis; the
// detail and grid rows keep theirs inside too.
//
// The rows are the real WorkflowTasks, rendered to markup, then laid out in real Chromium from the
// Session Info's stylesheets. CI fails the file when Chromium cannot launch (requireBrowserLane).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import { readFileSync } from "node:fs";
import path from "node:path";
import type { Browser } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("workflow-agent-compact-browser.test.tsx", async () => {
  setDefaultTimeout(60_000);
  const { renderToStaticMarkup } = await import("react-dom/server");
  const { WorkflowTasks } = await import("../src/agent-session/acpmux/session-info/WorkflowTasks");
  const { createWorkflowAdapter } = await import("../src/agent-session/acpmux/summary/foldWorkflows");
  const { workflowFixture } = await import("../src/agent-session/acpmux/summary/workflowFixture");
  const { chromium } = await import("playwright");

  const NOW = 1_800_000_000_000;
  const action = `Reading ${"webviews/src/agent-session/acpmux/inspector/".repeat(4)}WorkflowTasks.tsx`;
  const workflows = createWorkflowAdapter()(workflowFixture("running", NOW), "s1").map((workflow) => ({
    ...workflow,
    agents: workflow.agents.map((agent) => ({ ...agent, doing: action, lastMessage: action })),
  }));
  const html = Object.fromEntries(
    (["compact", "detail", "grid"] as const).map((variant) => [
      variant,
      renderToStaticMarkup(
        <WorkflowTasks workflows={workflows} onOpenWorkflowAgent={() => undefined} agentRowVariant={variant} />,
      ),
    ]),
  );

  const src = path.resolve(import.meta.dir, "../src");
  const css = [
    "agent-session/acpmux/styles.css",
    "agent-session/acpmux/session-info/sessionInfo.css",
    "agent-session/acpmux/summary/workflowDots.css",
    "agent-session/acpmux/session-info/WorkflowTasks.css",
  ]
    .map((file) => readFileSync(path.join(src, file), "utf8").replace(/^@import[^;]*;$/gm, ""))
    .join("\n");
  const tokens = ":root { --text-detail: 12px; --text-detail--letter-spacing: 0; }";

  let browser: Browser;
  beforeAll(async () => {
    browser = await chromium.launch({ headless: true });
  });
  afterAll(async () => {
    await browser?.close();
  });

  describe("workflow agent rows in a 280px panel with a long current action", () => {
    for (const variant of Object.keys(html))
      test(`${variant}: the current action stays inside the row and ends in an ellipsis`, async () => {
        expect(html[variant]).toContain("acpmux-workflow-agent__doing");
        const page = await browser.newPage({ viewport: { width: 400, height: 900 } });
        try {
          await page.setContent(
            `<style>${tokens}\n${css}\nbody { margin: 0; font: 13px system-ui, sans-serif }</style>` +
              `<div class="acpmux-shell" style="display: block; width: 280px">${html[variant]}</div>`,
          );
          const rows = await page.evaluate(() =>
            [...document.querySelectorAll<HTMLElement>(".acpmux-workflow-agent__button")].flatMap((row) => {
              const doing = row.querySelector<HTMLElement>(".acpmux-workflow-agent__doing");
              if (!doing) return [];
              const edge = row.getBoundingClientRect();
              const box = doing.getBoundingClientRect();
              const style = getComputedStyle(doing);
              return [
                {
                  inside: box.left >= edge.left - 0.5 && box.right <= edge.right + 0.5,
                  rowInsidePanel: edge.right <= 280.5,
                  width: box.width,
                  truncated: doing.scrollWidth > doing.clientWidth,
                  ellipsis: style.textOverflow === "ellipsis" && style.overflow === "hidden",
                },
              ];
            }),
          );
          expect(rows.length).toBeGreaterThan(0);
          for (const row of rows) {
            expect(row.rowInsidePanel).toBe(true);
            expect(row.inside).toBe(true);
            expect(row.width).toBeGreaterThan(0);
            // The action is longer than the row, so it is clipped with the ellipsis, not run past.
            expect(row.truncated).toBe(true);
            expect(row.ellipsis).toBe(true);
          }
        } finally {
          await page.close();
        }
      });
  });
});
