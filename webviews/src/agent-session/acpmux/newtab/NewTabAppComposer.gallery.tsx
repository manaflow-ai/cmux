// l10n-allow-file: gallery fixtures (a look's sample scene), not shipped UI.
import { useMemo, type ComponentProps } from "react";
import { componentEntry } from "../../../gallery/format";
import type { Play } from "../../../gallery/play";
import { CWD, manySessions, noChat } from "../../../gallery/fixtures/acpmux";
import type { PageClient, PageHandler } from "../../../pages/shared/pageClient";
import type { SceneOp } from "../../../apps/scene/store";
import { NewTabAppSlot } from "./NewTabAppSlot";
import { NewTabScreen } from "./NewTabScreen";

type Look = "cards" | "console" | "no-slot";

const screen: ComponentProps<typeof NewTabScreen> = {
  snapshot: noChat(manySessions(3)),
  home: "/Users/you",
  cwd: CWD,
  projects: [{ cwd: CWD, label: "atlas-web" }],
  knownProjects: null,
  onAsk: () => {},
  onOpen: () => {},
  onSearch: () => {},
  onShell: () => {},
  onJump: () => {},
  onOpenSession: () => {},
  onShowAll: () => {},
};

const card = (id: string, harness: string, title: string, preview: string, age: string): SceneOp[] => [
  {
    op: "create",
    id,
    type: "VStack",
    props: { spacing: 4, padding: 12, background: "secondaryFill", cornerRadius: 12, onTap: true, opens: { chat: id } },
  },
  { op: "create", id: `${id}-meta`, type: "HStack", props: { spacing: 6 } },
  { op: "create", id: `${id}-mark`, type: "Icon", props: { symbol: `harness:${harness}`, size: 14 } },
  { op: "create", id: `${id}-age`, type: "Text", props: { text: age, font: "caption", color: "secondary" } },
  { op: "children", id: `${id}-meta`, children: [`${id}-mark`, `${id}-age`] },
  { op: "create", id: `${id}-title`, type: "Text", props: { text: title, weight: "semibold", lineLimit: 1 } },
  {
    op: "create",
    id: `${id}-preview`,
    type: "Text",
    props: { text: preview, font: "caption", color: "secondary", lineLimit: 2 },
  },
  { op: "children", id, children: [`${id}-meta`, `${id}-title`, `${id}-preview`] },
];

const row = (id: string, harness: string, title: string, age: string): SceneOp[] => [
  { op: "create", id, type: "HStack", props: { spacing: 8, onTap: true, opens: { chat: id } } },
  { op: "create", id: `${id}-mark`, type: "Icon", props: { symbol: `harness:${harness}`, size: 14 } },
  { op: "create", id: `${id}-title`, type: "Text", props: { text: title, monospaced: true, lineLimit: 1 } },
  { op: "create", id: `${id}-gap`, type: "Spacer", props: {} },
  { op: "create", id: `${id}-age`, type: "Text", props: { text: age, monospaced: true, color: "secondary" } },
  { op: "children", id, children: [`${id}-mark`, `${id}-title`, `${id}-gap`, `${id}-age`] },
];

function scene(look: Look): SceneOp[] {
  if (look === "console")
    return [
      { op: "create", id: "root", type: "VStack", props: { spacing: 16, padding: 24 } },
      { op: "create", id: "head", type: "Text", props: { text: "recent", monospaced: true, color: "secondary" } },
      ...row("r1", "claude", "fix the upload retry", "2m"),
      ...row("r2", "codex", "release notes for 0.9", "1h"),
      ...row("r3", "claude", "flaky e2e on login", "3h"),
      { op: "children", id: "root", children: ["head", "r1", "r2", "r3"] },
      { op: "root", id: "root" },
    ];
  return [
    { op: "create", id: "root", type: "VStack", props: { spacing: 16, padding: 24 } },
    { op: "create", id: "cards", type: "HStack", props: { spacing: 12, alignment: "top" } },
    ...card("c1", "claude", "Fix the upload retry", "Done: retries now back off and the test passes.", "2m"),
    ...card("c2", "codex", "Release notes for 0.9", "Drafted the notes; waiting on the changelog.", "1h"),
    ...card("c3", "claude", "Flaky e2e on login", "Found the race in the session cookie.", "3h"),
    { op: "children", id: "cards", children: ["c1", "c2", "c3"] },
    { op: "children", id: "root", children: ["cards"] },
    { op: "root", id: "root" },
  ];
}

/** The page host for one look: the mount answers, and the scene arrives once the page subscribes. */
function lookHost(look: Look): PageClient {
  return {
    async call<R>(op: string): Promise<R> {
      return (op === "cmux.apps.panels.mount" ? { mount_id: "m1" } : {}) as R;
    },
    async subscribe<E>(_stream: string, callback: (event: E, seq: number) => void): Promise<() => void> {
      setTimeout(() => callback({ mount_id: "m1", ops: scene(look) } as E, 1), 0);
      return () => undefined;
    },
    handle(_op: string, _handler: PageHandler) {
      return () => undefined;
    },
  } as PageClient;
}

function LookPage({ look = "cards" }: { look?: Look }) {
  const client = useMemo(() => lookHost(look), [look]);
  return (
    // In the agent pane shell, the app scene occupies the room above cmux's own composer.
    <div className="acpmux-shell" style={{ flexDirection: "column" }}>
      <NewTabScreen
        {...screen}
        template="minimal"
        above={
          look === "no-slot" ? undefined : (
            <NewTabAppSlot app={`local/${look}-look`} cwd={CWD} client={client} onUnavailable={() => undefined} />
          )
        }
      />
    </div>
  );
}

const drawn: Play = async (ctx) => {
  await ctx.waitFor(() => ctx.document.querySelector('.nt-app-page[data-status="ready"]') !== null);
};
const composed: Play = async (ctx) => {
  await drawn(ctx);
  await ctx.waitFor(() => ctx.document.querySelector(".nt-app-slot-body[data-status=ready]") !== null);
};

export default componentEntry<{ look?: Look }>({
  id: "agent-pane.new-tab-app-composer",
  title: "New Tab app with cmux's composer",
  area: "New Tab",
  height: 560,
  pane: true,
  covers: ["agent-session/acpmux/newtab/NewTabAppSlot.tsx", "apps/scene/SceneSymbol.tsx#SceneSymbol"],
  load: async () => LookPage,
  styles: () =>
    Promise.all([
      import("../styles.css"),
      import("../composerStates.css"),
      import("./screen.css"),
      import("./appSlot.css"),
      import("../../../apps/scene/scene.css"),
    ]),
  variants: {
    cards: {
      note: "A cards look: cmux's own composer stays below the slot, with three chat cards and each agent's mark.",
      props: { look: "cards" },
      play: composed,
    },
    console: {
      note: "A console look: cmux's own composer stays below the slot; the rows are monospace Text with harness marks.",
      props: { look: "console" },
      play: composed,
    },
    "no-slot": {
      note: "A page with no selected app keeps cmux's own composer and draws no extension scene.",
      props: { look: "no-slot" },
      play: drawn,
    },
  },
});
