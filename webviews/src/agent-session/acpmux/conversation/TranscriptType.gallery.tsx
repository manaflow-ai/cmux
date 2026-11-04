// l10n-allow-file: deterministic transcript reading samples.
import { useState } from "react";
import { componentEntry } from "../../../gallery/format";
import { tool } from "../../../gallery/fixtures/acpmux";
import { toolFiles } from "../diff";
import { ShellRow } from "../shell/ShellRow";
import { PlainCode } from "./StreamingCode";
import { ShellBlock } from "./ShellBlock";
import { EditDiff } from "./EditDiff";
import { Markdown } from "./Markdown";
import { DiagramBlock } from "./DiagramBlock";
import { RenderCard } from "./RenderCard";
import { ImageViewer } from "./ImageViewer";
import { TurnFooter } from "./TurnRows";
import { TurnActionsContext } from "./turnActions";
import { ToolRow } from "./ToolRow";
import { CommandRow } from "./CommandRow";
import type { CloudSignIn, LoginAgent } from "../cloudAgentLogin";

const output = Array.from({ length: 14 }, (_, index) => `step ${index + 1}: completed`).join("\n");
const file = toolFiles([
  tool("Update retry", "edit", "completed", {
    diffs: [
      {
        path: "src/long-retry-policy-name.ts",
        oldText: Array.from({ length: 14 }, (_, index) => `retry(${index + 1});`).join("\n"),
        newText: Array.from({ length: 14 }, (_, index) => `retry(${index + 3});`).join("\n"),
      },
    ],
  }).tool!,
])[0]!;
const image = {
  src: `data:image/svg+xml,${encodeURIComponent('<svg xmlns="http://www.w3.org/2000/svg" width="240" height="120"><rect width="240" height="120" fill="gray"/></svg>')}`,
  alt: "Retry report with a deliberately long image title",
};

/// A Cloud chat's sign-in with synthetic replies: Claude's page gives a code to paste back, or with
/// `approve` its automatic page opens on the chat's machine and signs in on the approve (a code to
/// paste stays one link away); Codex's asks for the device code the card shows. Nothing leaves the
/// gallery.
function gallerySignIn(agent: LoginAgent, approve: boolean): CloudSignIn {
  return {
    agent,
    start: async () =>
      agent === "claude"
        ? {
            loginId: "gallery-login",
            url: "https://claude.ai/oauth/authorize",
            needsCode: true,
            ...(approve
              ? {
                  autoUrl: "https://claude.ai/oauth/authorize?redirect_uri=http%3A%2F%2Flocalhost%3A54545%2Fcallback",
                  callbackPort: 54545,
                }
              : {}),
          }
        : {
            loginId: "gallery-login",
            url: "https://auth.openai.com/codex/device",
            userCode: "QRST-4821",
            needsCode: false,
          },
    open: () => {},
    openOnMachine: async () => true,
    finish: () => new Promise<boolean>(() => {}),
    apiKey: async () => true,
    cancel: () => {},
    reserve: async () => undefined,
    resend: async () => {},
  };
}

/// Only a Cloud chat's sign-in card, for its states.
function CloudSignInStates({ agent, approve }: { agent: LoginAgent; approve: boolean }) {
  return (
    <main className="acpmux-scroll" style={{ padding: 18, overflow: "auto", height: "100%", boxSizing: "border-box" }}>
      <TurnActionsContext.Provider
        value={{
          switchModel: () => {},
          cloudSignIn: gallerySignIn(agent, approve),
          route: { name: agent === "claude" ? "Claude Code" : "Codex", harness: agent, hostKind: "cloud" },
        }}
      >
        <TurnFooter
          row={{
            id: `sign-in-${agent}`,
            kind: "turnSummary",
            version: 1,
            at: 1000,
            status: "failed",
            error: "Not logged in · Please run /login",
            prompt: "Run retry tests",
            retryRowId: `sign-in-${agent}-prompt`,
          }}
        />
      </TurnActionsContext.Provider>
    </main>
  );
}

function TranscriptType({ signIn, approve = false }: { signIn?: LoginAgent; approve?: boolean }) {
  if (signIn) return <CloudSignInStates agent={signIn} approve={approve} />;
  const [viewer, setViewer] = useState(false);
  return (
    <main className="acpmux-scroll" style={{ padding: 18, overflow: "auto", height: "100%", boxSizing: "border-box" }}>
      <PlainCode lang="typescript" code={"export const retry = 3;\n\nretry();"} open />
      <EditDiff file={file} />
      <ShellBlock command="cd ~/src/atlas && bun test" output={output} exitCode={2} />
      <div data-type="tool-output">
        <ToolRow item={tool("Fetch retry log", "fetch", "completed", { output })} />
      </div>
      <CommandRow item={tool("Run retry tests", "execute", "completed", { command: "bun test", exitCode: 2 })} />
      <ShellRow
        row={{
          id: "type-shell",
          kind: "userShell",
          at: 1000,
          version: 1,
          shell: {
            id: "type-shell",
            command: "bun test src/net/retry.test.ts",
            cwd: "/src/atlas",
            startedAt: 1000,
            status: "running",
            output,
            truncated: false,
            version: 1,
          },
        }}
        expanded={false}
        onToggleActivity={() => {}}
      />
      <Markdown>
        {
          "The retry report has a note.[^report]\n\n[^report]: The timeout is retried three times, then returned to the caller."
        }
      </Markdown>
      <TurnActionsContext.Provider
        value={{
          switchModel: () => {},
          reauthenticate: () => {},
          transferCloudCredentials: async () => {},
          route: { name: "Claude Code", hostKind: "cloud" },
        }}
      >
        <TurnFooter
          row={{
            id: "type-auth",
            kind: "turnSummary",
            version: 1,
            at: 1000,
            status: "failed",
            error: "401 unauthorized",
            prompt: "Run retry tests",
            retryRowId: "type-auth-prompt",
          }}
        />
      </TurnActionsContext.Provider>
      <RenderCard call={{ html: "<p>Retry report</p>", title: "Retry report with a deliberately long title" }} />
      <DiagramBlock lang="vega-lite" code="{ invalid chart" />
      <button type="button" onClick={() => setViewer(true)}>
        Open image
      </button>
      {viewer && <ImageViewer images={[image, image]} index={0} onIndex={() => {}} onClose={() => setViewer(false)} />}
    </main>
  );
}

export default componentEntry({
  id: "agent-pane.transcript-type",
  title: "Transcript reading size",
  area: "Agent pane",
  pane: true,
  height: 1100,
  widths: { narrow: 390, normal: 760 },
  covers: [
    "agent-session/acpmux/conversation/StreamingCode.tsx#PlainCode",
    "agent-session/acpmux/conversation/EditDiff.tsx",
    "agent-session/acpmux/conversation/ShellBlock.tsx",
    "agent-session/acpmux/shell/ShellRow.tsx",
    "agent-session/acpmux/conversation/Markdown.tsx",
    "agent-session/acpmux/conversation/TurnRows.tsx#TurnFooter",
    "agent-session/acpmux/conversation/CloudSignIn.tsx#CloudSignIn",
    "agent-session/acpmux/conversation/RenderCard.tsx",
    "agent-session/acpmux/conversation/DiagramBlock.tsx",
    "agent-session/acpmux/conversation/ImageViewer.tsx",
    "agent-session/acpmux/conversation/ToolRow.tsx",
    "agent-session/acpmux/conversation/CommandRow.tsx",
  ],
  load: async () => TranscriptType,
  styles: () => Promise.all([import("../styles.css"), import("./conversation.css")]),
  variants: {
    reading: {
      props: {},
      note: "Real transcript headers, code, output, footnotes, actions, diagrams and media.",
      play: async (ctx) => {
        await ctx.click({ selector: '[data-type="tool-output"] .cv-tool' });
        await ctx.waitFor(() => ctx.document.querySelector(".cv-tool-output"));
      },
    },
    "claude-sign-in": {
      props: { signIn: "claude" },
      note: "A Cloud chat whose Claude is not signed in on its machine: one Sign in to Claude button (its click starts the login there and opens Claude's page), with Use an API key as a link beside it.",
    },
    "claude-code-entry": {
      props: { signIn: "claude" },
      note: "After the one Sign in to Claude click: the login runs on the machine and Claude's page is open; the card asks for the code the page shows, with Open sign-in page to open it again.",
      play: async (ctx) => {
        await ctx.click({ selector: ".cv-turn-error__primary" });
        await ctx.waitFor(() => ctx.document.querySelector(".cv-turn-signin__input"));
      },
    },
    "claude-approve": {
      props: { signIn: "claude", approve: true },
      note: "After the one Sign in to Claude click on a machine whose acpmux names Claude's automatic page: that page opens in a tab bound to the machine, and the card waits for the approve, with no code field and Paste a code instead as a quiet link.",
      play: async (ctx) => {
        await ctx.click({ selector: ".cv-turn-error__primary" });
        await ctx.waitFor(() => ctx.document.querySelector(".cv-turn-signin .cv-turn-error__offer-link"));
      },
    },
    "codex-code": {
      props: { signIn: "codex" },
      note: "The same one click for Codex: its page open and its device code, large and already copied, while the card waits for the approval.",
      play: async (ctx) => {
        await ctx.click({ selector: ".cv-turn-error__primary" });
        await ctx.waitFor(() => ctx.document.querySelector(".cv-turn-signin__code"));
      },
    },
  },
});
