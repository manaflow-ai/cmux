// l10n-allow-file: gallery fixtures (sample commands and paths), not shipped UI.
// The tool permission card (Panel.tsx) in every state Lawrence reviews: one request, several, the
// input expanded, a long command, deny-only, a chat allowance with an error, collecting, narrow.
import { componentEntry } from "../../../gallery/format";
import type { PermissionPanel } from "./Panel";
import type { PermissionClientState, PermissionGroup } from "./protocol";

type Props = Parameters<typeof PermissionPanel>[0];

const noop = () => undefined;
const item = (id: string, title: string, kind: string, rawInput: unknown, paths: string[] = []) => ({
  permissionId: id,
  state: "pending" as const,
  request: { toolCall: { title, kind, rawInput, locations: paths.map((path) => ({ path })) } },
});
const group = (items: PermissionGroup["items"], decisions = ["allow_once", "allow_chat", "deny"]): PermissionGroup => ({
  groupId: "gallery-group",
  sessionId: "gallery-session",
  turnId: "gallery-turn",
  revision: 1,
  state: "pending",
  decision: null,
  decisions: decisions as PermissionGroup["decisions"],
  items,
});
const props = (groups: PermissionGroup[], extra: Partial<PermissionClientState> = {}): Props => ({
  state: { supported: true, ready: true, groups, chatAllowance: false, loading: false, busy: false, ...extra },
  onRespond: noop,
  onRetry: noop,
  onRevoke: noop,
  onRefresh: noop,
});

const guide = item("p1", "cmux harness guide", "execute", { command: "cmux harness guide" }, ["/Users/you/src/cmux"]);
const write = item(
  "p2",
  "Write src/app.ts",
  "edit",
  { path: "src/app.ts", content: "export const retry = (n: number) => n * 2;\n" },
  ["/Users/you/src/cmux/src/app.ts"],
);
const fetch = item("p3", "Fetch https://docs.example.com/api", "fetch", { url: "https://docs.example.com/api" });
const longCommand = item(
  "p4",
  "bun x tsc --noEmit -p webviews/tsconfig.json && bun test webviews/src/agent-session/acpmux/permissions --timeout 30000",
  "execute",
  {
    command:
      "bun x tsc --noEmit -p webviews/tsconfig.json && bun test webviews/src/agent-session/acpmux/permissions --timeout 30000",
  },
);

export default componentEntry<Props>({
  id: "agent-pane.permission-card",
  title: "Tool permission card",
  area: "Agent pane",
  height: 300,
  covers: ["agent-session/acpmux/permissions/Panel.tsx#PermissionPanel"],
  pane: true,
  load: () => import("./Panel").then((module) => module.PermissionPanel),
  variants: {
    "one-request": {
      note: "One command: the title names it; Allow once is the only primary action; hover shows the ⌥⌘ hints.",
      props: props([group([guide])]),
    },
    "several-requests": {
      note: "Three requests from one turn: the title counts them and each one is its own row.",
      props: props([group([guide, write, fetch])]),
    },
    expanded: {
      note: "The request row opened: the folder it touches and its full input, as text.",
      props: props([group([write])]),
      play: async (ctx) => {
        await ctx.click({ selector: "[data-permission-card] summary" });
      },
    },
    "long-command": {
      note: "A long command wraps inside its code chip; the isolation chip and the buttons keep their place.",
      props: props([group([longCommand])]),
    },
    "deny-only": {
      note: "No single-use approval exists for an item: only Deny is offered, with the reason.",
      props: props([group([guide], ["deny"])]),
    },
    "allowed-with-error": {
      note: "Requests are allowed for this chat (Revoke) and the last answer needs a check (Check and retry).",
      props: props([], { chatAllowance: true, uncertain: true, error: "The permission answer may have been applied." }),
    },
    collecting: {
      note: "The agent is still sending requests for this turn: nothing can be answered yet.",
      props: props([{ ...group([guide]), state: "collecting" }]),
    },
  },
  widths: { narrow: 360 },
});
