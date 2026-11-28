import { openedRunEvents } from "./src/agent-session/acpmux/conversation/OpenedRunRhythm.gallery.ts";
import { rowsFromRecording } from "./src/gallery/fixtures/recording.ts";
import { turnView } from "./src/agent-session/acpmux/conversation/turns.ts";
for (const ended of [false, true]) {
  const raw = await rowsFromRecording(
    openedRunEvents(ended)
      .map((e) => JSON.stringify(e))
      .join("\n"),
    "claude",
  );
  for (const working of [false, true]) {
    const out = turnView(raw, new Set(), { working, agentFamily: "claude", now: 1_800_000_000_000 });
    console.log("ended", ended, "working", working);
    console.log(
      out.map((r) => ({
        id: r.id,
        kind: r.kind,
        text: r.text,
        foldRun: r.foldRun,
        runOpen: r.runOpen,
        inBackground: r.inBackground,
        messageRun: r.messageRun,
        foldOpen: r.foldOpen,
        background: r.background,
      })),
    );
  }
}
