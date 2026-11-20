import { expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import { ChiefWorkPanel } from "../src/pages/home-channels/ChiefWorkPanel";
import type { HomeChiefWork } from "../src/pages/home-channels/chiefWorkTypes";
import { createStrings } from "../src/pages/shared/i18n";
import table from "../src/pages/home-channels/generated/strings.json";

const strings = createStrings(table, ["en"]);
const render = (snapshot?: HomeChiefWork, loading = false, error?: string) =>
  renderToStaticMarkup(
    <ChiefWorkPanel
      snapshot={snapshot}
      loading={loading}
      error={error}
      strings={strings}
      onRefresh={() => undefined}
      onClose={() => undefined}
    />,
  );

test("loading or failed reads never claim there is no background work", () => {
  expect(render(undefined, true)).toContain("Loading work");
  expect(render(undefined, true)).not.toContain("No background work");
  expect(render(undefined, false, "chief.work_unavailable")).toContain("Background work is unavailable");
  expect(render(undefined, false, "chief.work_unavailable")).not.toContain("No background work");
  expect(render({ agents: [], tasks: [], truncated: false })).toContain("No background work");
  expect(render({ agents: [], tasks: [], truncated: true })).toContain("Some work could not be loaded");
  expect(render({ agents: [], tasks: [], truncated: true })).not.toContain("No background work");
});

test("the snapshot keeps real states, source scope and command detail", () => {
  const snapshot: HomeChiefWork = {
    agents: [
      { id: "a", name: "Build page", state: "working" },
      { id: "b", name: "Check page", state: "waiting" },
    ],
    tasks: [
      {
        id: "t",
        sessionId: "a",
        title: "Build preview",
        status: "unknown",
        command: "bun run build",
        detail: "Process state unavailable",
      },
    ],
    truncated: false,
    taskSources: ["harness"],
  };
  const html = render(snapshot);
  expect(html.indexOf("Check page")).toBeLessThan(html.indexOf("Build page"));
  expect(html).toContain("Subagents");
  expect(html).toContain("Background commands");
  expect(html).not.toContain("Background tasks");
  expect(html).toContain("Unknown");
  expect(html).toContain("bun run build");
  expect(html).toContain("Process state unavailable");
  expect(html).not.toContain("Stop</button>");
});

test("refreshing keeps loaded work in place and failures stay text", () => {
  const snapshot: HomeChiefWork = {
    agents: [],
    tasks: [{ id: "t", sessionId: "a", title: "<script>private command</script>", status: "failed" }],
    truncated: false,
  };
  const html = render(snapshot, true);
  expect(html).toContain("&lt;script&gt;private command&lt;/script&gt;");
  expect(html).toContain("Failed");
  expect(html).toContain("disabled");
  expect(html).not.toContain("<script>");
});

test("completed commands stay in a closed history fold while active and unknown commands remain visible", () => {
  const html = render({
    agents: [],
    tasks: [
      { id: "a", sessionId: "chief", title: "Preview server", status: "running" },
      { id: "b", sessionId: "chief", title: "Lost watcher", status: "unknown" },
      { id: "c", sessionId: "chief", title: "Build page", status: "done" },
      { id: "d", sessionId: "chief", title: "Verify page", status: "failed" },
    ],
    truncated: false,
  });
  const fold = html.indexOf('<details class="hc-chief-work__finished">');
  expect(fold).toBeGreaterThan(0);
  expect(html.indexOf("Preview server")).toBeLessThan(fold);
  expect(html.indexOf("Lost watcher")).toBeLessThan(fold);
  expect(html.indexOf("Build page")).toBeGreaterThan(fold);
  expect(html.indexOf("Verify page")).toBeGreaterThan(fold);
  expect(html).toContain("Finished <span>2</span>");
});
