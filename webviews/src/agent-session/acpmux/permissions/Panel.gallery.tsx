// l10n-allow-file: gallery fixtures (sample commands and paths), not shipped UI.
// The tool permission card (Panel.tsx) in every state Lawrence reviews: one request, several, the
// input expanded, a long command, deny-only, a chat allowance with an error, collecting, narrow.
import { componentEntry } from "../../../gallery/format";
import type { PlayContext } from "../../../gallery/play";
import type { PermissionPanel } from "./Panel";
import type { PermissionClientState, PermissionGroup } from "./protocol";

type Props = Parameters<typeof PermissionPanel>[0];

// The card's behavior, checked in a real engine by each variant's play (the shell and the matrix
// runner fail a variant whose wait times out). Lawrence 2026-10-09: "this ui is ugly".
const card = (ctx: PlayContext) => ctx.document.querySelector<HTMLElement>("[data-permission-card]");
const decisions = (ctx: PlayContext) => [
  ...(card(ctx)?.querySelectorAll<HTMLButtonElement>("button[data-decision]") ?? []),
];
/// One look: the title names the request; exactly one primary action (Allow once, at the trailing
/// edge); shortcut keycaps are hidden from assistive technology and every button is named by its
/// verb; no separate Expand button; the isolation note is a chip inside the card with its reason.
async function oneLook(ctx: PlayContext, title: string) {
  await ctx.waitFor(() => card(ctx)?.querySelector("[data-permission-title]")?.textContent === title);
  await ctx.waitFor(() => {
    const buttons = decisions(ctx);
    const primary = buttons.filter((button) => button.dataset.variant === "primary");
    return (
      primary.length === 1 &&
      primary[0] === buttons.at(-1) &&
      primary[0]!.dataset.decision === "allow_once" &&
      buttons.every((button) => button.getAttribute("aria-label") === button.firstChild?.textContent) &&
      [...card(ctx)!.querySelectorAll("kbd")].every((kbd) => kbd.getAttribute("aria-hidden") === "true") &&
      ![...card(ctx)!.querySelectorAll("button")].some((button) => button.textContent?.includes("Expand")) &&
      !!card(ctx)!.querySelector("[data-permission-isolation][title]")
    );
  });
}

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
  // The pane's color tokens live on .acpmux-shell (styles.css); in the app the card always sits
  // inside it, so the gallery draws it there too, or the card would show without its colors.
  load: () =>
    Promise.all([import("./Panel"), import("../shortcuts")]).then(
      ([{ PermissionPanel }, { ShortcutsContext, SHORTCUT_ACTIONS }]) =>
        Object.assign(
          (props: Props) => (
            <div className="acpmux-shell" style={{ display: "block", height: "auto", padding: 16 }}>
              {/* The app's default keycaps for the permission commands, as the host sends them. */}
              <ShortcutsContext.Provider
                value={{
                  [SHORTCUT_ACTIONS.permissionAllowOnce]: "⌥⌘1",
                  [SHORTCUT_ACTIONS.permissionAllowChat]: "⌥⌘2",
                  [SHORTCUT_ACTIONS.permissionDeny]: "⌥⌘3",
                  [SHORTCUT_ACTIONS.permissionExpand]: "⌥⌘4",
                }}
              >
                <PermissionPanel {...props} />
              </ShortcutsContext.Provider>
            </div>
          ),
          { displayName: "PermissionPanelInShell" },
        ),
    ),
  variants: {
    "one-request": {
      note: "One command: the title names it; Allow once is the only primary action; hover shows the ⌥⌘ hints.",
      props: props([group([guide])]),
      // Holding Option-Command shows every shortcut hint at once (keycaps under the hovered card).
      play: async (ctx) => {
        await oneLook(ctx, "Run cmux harness guide?");
        ctx.document.defaultView!.dispatchEvent(
          new KeyboardEvent("keydown", { key: "Meta", metaKey: true, altKey: true }),
        );
        await ctx.waitFor(() => card(ctx)?.dataset.hints === "true");
        await ctx.hover({ selector: "[data-permission-card]" });
      },
    },
    "several-requests": {
      note: "Three requests from one turn: the title counts them and each one is its own row.",
      props: props([group([guide, write, fetch])]),
      play: async (ctx) => {
        await oneLook(ctx, "3 requests from this turn");
        await ctx.waitFor(() => card(ctx)?.querySelectorAll("details summary").length === 3);
        await ctx.hover({ selector: "[data-permission-card] [data-decision=allow_once]" });
      },
    },
    expanded: {
      note: "The request row opened: the folder it touches and its full input, as text.",
      props: props([group([write])]),
      // One disclosure: the request row itself opens and shows the input as text.
      play: async (ctx) => {
        await oneLook(ctx, "Allow Write src/app.ts?");
        await ctx.click({ selector: "[data-permission-card] summary" });
        await ctx.waitFor(() => card(ctx)?.querySelector("details")?.open === true);
        await ctx.waitFor(() => card(ctx)?.querySelector("pre")?.textContent?.includes("export const retry"));
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
