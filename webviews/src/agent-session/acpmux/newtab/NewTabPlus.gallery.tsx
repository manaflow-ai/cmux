// l10n-allow-file: synthetic gallery content, not shipped labels.
import { useState } from "react";
import { componentEntry } from "../../../gallery/format";
import { noChat } from "../../../gallery/fixtures/acpmux";
import type { Play } from "../../../gallery/play";
import { NewTabScreen } from "./NewTabScreen";

const open: Play = async (ctx) => {
  await ctx.click({ selector: ".acpmux-newtab-plus .acpmux-picker-button" });
};
const ready: Play = async (ctx) => {
  await open(ctx);
  for (const id of ["add.screenshot", "add.window", "add.project", "add.mode.plan", "add.goal", "add.skill.review"])
    await ctx.waitFor(() => Boolean(document.querySelector(`[data-value="${id}"]`)));
};
const skill: Play = async (ctx) => {
  await ctx.type("Keep the complete draft", { selector: ".nt-field" });
  await open(ctx);
  await ctx.click({ selector: '[data-value="add.skill.review"]' });
  await ctx.waitFor(
    () => (ctx.find({ selector: ".nt-field" }) as HTMLTextAreaElement).value === "/review Keep the complete draft",
  );
  if (ctx.document.querySelector('.nt-row[data-type="open"]'))
    throw new Error("a selected skill was offered as a file URL");
  await ctx.click({ selector: ".nt-send" });
  await ctx.waitFor(
    () => ctx.document.querySelector("[data-skill-sent]")?.textContent === "/review Keep the complete draft",
  );
};
function Fixture({ variant }: { variant: string }) {
  const [sent, setSent] = useState("");
  const modes = {
    currentModeId: variant === "planning" ? "plan" : "default",
    availableModes: [{ id: "default" }, { id: "plan" }],
  };
  const snapshot = noChat([], {
    summary: { sessionId: "deferred", harness: "claude", cwd: "/project", model: "claude-opus-5-5", modes },
    commands:
      variant === "files"
        ? []
        : [
            { name: "review", source: "skill", description: "Review the current draft" },
            { name: "goal", description: "Keep pursuing the current task" },
          ],
  });
  const capabilities =
    variant === "files"
      ? {}
      : {
          capture: async () => undefined,
          onBrowseProject: async () => "/project",
          onPlusMode: async () => undefined,
        };
  return (
    <>
      <output hidden data-skill-sent>
        {sent}
      </output>
      <NewTabScreen
        snapshot={snapshot}
        cwd="/project"
        startCwd="/project"
        template="default"
        onAsk={(_harness, text) => setSent(text)}
        onOpen={() => {}}
        onSearch={() => {}}
        onShell={() => {}}
        onJump={() => {}}
        onOpenSession={() => {}}
        onShowAll={() => {}}
        {...capabilities}
      />
    </>
  );
}
export default componentEntry<{ variant: string }>({
  id: "agent-pane.newtab-plus-capabilities",
  title: "New Tab +: the same capability-aware Add registry as chat",
  area: "Agent pane",
  pane: true,
  height: 650,
  widths: { narrow: 520, normal: 900, wide: 1100 },
  checks: {
    anchorMovePx: { value: 0, reason: "The + trigger stays in the same composer column." },
    layoutShiftMax: { value: 0, reason: "The capability-aware menu floats without shifting the page." },
  },
  covers: ["agent-session/acpmux/newtab/NewTabScreen.tsx#NewTabScreen"],
  styles: async () => {
    await import("../styles.css");
    await import("./screen.css");
  },
  load: async () => Fixture,
  variants: {
    ready: {
      note: "Capture, project, advertised Plan, goal and skill share one Add section.",
      props: { variant: "ready" },
      play: ready,
    },
    planning: {
      note: "An advertised Plan mode offers its harness-native Build alternative.",
      props: { variant: "planning" },
      play: open,
    },
    files: {
      note: "Unavailable host capabilities stay absent; file attachment still works.",
      props: { variant: "files" },
      play: open,
    },
    skill: {
      note: "Selecting a skill preserves and sends the complete existing draft as command arguments.",
      props: { variant: "ready" },
      play: skill,
    },
  },
});
