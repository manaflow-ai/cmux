// l10n-allow-file: gallery fixtures (sample tool requests and paths), not shipped UI.
//
// The asks above the composer stacked as the pane draws them (`.acpmux-asks-stack`): the permission ask,
// the folder trust ask and the Cloud start ask. One material (content), one radius (`--grid-cards-radius`),
// one hairline stroke, one button set (ui/Button): a reviewer reads all three side by side, in the
// default look and under a look from examples/looks.
import looks from "virtual:cmux-gallery/looks";
import { componentEntry } from "../../gallery/format";
import { CloudStartAsk } from "./CloudStartAsk";
import { PermissionPanel } from "./permissions/Panel";
import type { PermissionClientState } from "./permissions/protocol";
import { TrustAsk } from "./TrustAsk";

const permission: PermissionClientState = {
  supported: true,
  ready: true,
  chatAllowance: false,
  loading: false,
  busy: false,
  groups: [
    {
      groupId: "group-gallery-stack",
      sessionId: "session-gallery",
      turnId: "turn-gallery-1",
      revision: 1,
      state: "pending",
      decisions: ["allow_once", "allow_chat", "deny"],
      decision: null,
      items: [
        {
          permissionId: "permission-gallery-stack",
          state: "pending",
          request: {
            toolCall: {
              title: "Run the web test suite",
              kind: "execute",
              locations: [{ path: "webviews/test" }],
              rawInput: { command: "bun test webviews/test/gallery-coverage.test.ts", cwd: "/Users/you/src/cmux" },
            },
          },
        },
      ],
    },
  ],
};

const cloudAsk = {
  id: "stack",
  kind: "firstLogin",
  title: "Set up Claude on paint-dev?",
  lines: ["The token stays in this Mac's Keychain; Cloud machines get it only to run your chat."],
  buttons: [
    { id: "cancel", title: "Cancel", role: "cancel" },
    { id: "setUp", title: "Set Up", role: "default" },
  ],
} as const;

const noop = () => undefined;

function AsksStack({ oneLine }: { oneLine?: boolean }) {
  return (
    <div className="acpmux-shell" data-asks-stack-fixture>
      <div className="acpmux-main">
        <div className="acpmux-permission acpmux-asks-stack">
          <PermissionPanel
            state={permission}
            working
            onRespond={noop}
            onRetry={noop}
            onRevoke={noop}
            onRefresh={noop}
          />
          <TrustAsk
            ask={
              oneLine
                ? { cwd: "/Users/leo/Projects/demo-app", state: "decided", level: "trusted" }
                : {
                    cwd: "/Users/leo/Projects/atlas-web/packages/fetch",
                    state: "ask",
                    repo: { root: "/Users/leo/Projects/atlas-web", worktree: false },
                  }
            }
            agent="Claude Code"
            onTrust={noop}
            onTrustRepo={noop}
            onDistrust={noop}
            onUndo={noop}
          />
          <CloudStartAsk ask={{ ...cloudAsk, buttons: [...cloudAsk.buttons] }} onAnswer={async () => true} />
        </div>
      </div>
    </div>
  );
}

const lookNamed = (id: string) => looks.looks.find((look) => look.id === id);

export default componentEntry<{ oneLine?: boolean }>({
  id: "agent-pane.asks-stack",
  title: "Asks stack (permission, trust, Cloud)",
  area: "Agent pane",
  height: 520,
  widths: { narrow: 400, normal: 620, wide: 760 },
  anchors: [{ selector: "[data-asks-stack-fixture]" }],
  covers: ["agent-session/acpmux/TrustAsk.tsx#TrustAsk", "agent-session/acpmux/CloudStartAsk.tsx"],
  styles: () =>
    Promise.all([import("./styles.css"), import("./conversation/conversation.css"), import("./cloudStart.css")]),
  load: async () => AsksStack,
  variants: {
    stacked: {
      note: "The permission ask, the folder trust ask (open) and the Cloud ask: one content material, radius, stroke and button set.",
      props: {},
    },
    "stacked-answered": {
      note: "The same stack with the trust ask answered (the one-line strip with Undo).",
      props: { oneLine: true },
    },
    "stacked-material": {
      note: "The stack under the material look.",
      props: {},
      ...(lookNamed("material-addon") ? { look: lookNamed("material-addon") } : {}),
    },
    "stacked-shadcn": {
      note: "The stack under the shadcn look.",
      props: { oneLine: true },
      ...(lookNamed("shadcn-addon") ? { look: lookNamed("shadcn-addon") } : {}),
    },
  },
});
