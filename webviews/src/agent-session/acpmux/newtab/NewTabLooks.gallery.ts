// l10n-allow-file: capture-only fixtures (looks-threads-console helper), not for a PR.
// The threads and console New Tab looks (public repos manaflow-ai/cmux-newtab-{threads,console}-look)
// drawn as the app draws a cmux.newtab/1 page: the agent pane's New Tab with `tabs.newTabApp` set, and
// the scene the look's own main.js emitted in the native QuickJS VM (cmux-app-host test newtab_looks).
import { agentPaneEntry } from "../../../gallery/format";
import { CWD, noChat } from "../../../gallery/fixtures/acpmux";
import { installAppPanelsDevClient } from "../../../apps/scene/panelsClient";
import type { PageClient } from "../../../pages/shared/pageClient";

const OPS = import.meta.glob<unknown[]>("./look-ops/*.json", { eager: true, import: "default" });
const opsFor = (app: string) => OPS[`./look-ops/${app.replace(/^local\//, "")}.json`] ?? [];

// The page host as the Mac bridge answers it (AppMountSurface.newTab): mount, then the scene.
const host: PageClient = {
  async call<R>(op: string, params: unknown): Promise<R> {
    if (op === "cmux.apps.panels.mount") return { mount_id: (params as { app: string }).app } as R;
    return {} as R;
  },
  async subscribe<E>(
    _stream: string,
    callback: (event: E, seq: number) => void,
    filter?: unknown,
  ): Promise<() => void> {
    const id = (filter as { mount_id: string }).mount_id;
    queueMicrotask(() => callback({ mount_id: id, ops: opsFor(id), reset: true } as E, 1));
    return () => undefined;
  },
  handle() {
    return () => undefined;
  },
} as unknown as PageClient;
installAppPanelsDevClient(host);

const newTab = (app: string) => ({
  newTab: { layout: "b", kind: "agent", cwd: CWD, home: "/Users/you", lastAgent: "claude", template: "minimal", app },
  newSession: true,
});

const variants = Object.fromEntries(
  ["threads", "console"].flatMap((look) =>
    ["empty", "few", "six", "10k", "recently-closed"].map((state) => [
      `${look}-${state}`,
      { note: `${look} look, ${state}.`, ready: newTab(`local/${look}-${state}`), snapshot: noChat([]) },
    ]),
  ),
);

export default agentPaneEntry({
  id: "agent-pane.new-tab-looks",
  title: "New Tab looks (capture only)",
  area: "New Tab",
  covers: ["src/agent-session/acpmux/newtab/NewTabAppPage.tsx"],
  height: 560,
  variants,
});
