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
import { LoginStepError, type CloudSignIn, type LoginAgent, type LoginFailure } from "../cloudAgentLogin";

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
/// paste stays one link away); Codex's and Grok's ask for the device code the card shows; Gemini
/// takes a key only. Nothing leaves the gallery.
const DEVICE_PAGES = {
  codex: { url: "https://auth.openai.com/codex/device", userCode: "QRST-4821" },
  grok: { url: "https://accounts.x.ai/device", userCode: "WDJB-MJHT" },
  cursor: { url: "https://cursor.com/loginDeepControl?challenge=gallery" },
} as const;

/// The route name the card says for each agent.
const AGENT_NAMES: Record<LoginAgent, string> = {
  claude: "Claude Code",
  codex: "Codex",
  gemini: "Gemini CLI",
  grok: "Grok",
  cursor: "Cursor",
};

function gallerySignIn(agent: LoginAgent, approve: boolean, fail?: LoginFailure): CloudSignIn {
  return {
    agent,
    start: async () => {
      // A machine that refuses the sign-in (a team machine: `shared_machine`).
      if (fail) throw new LoginStepError(fail);
      if (agent === "claude")
        return {
          loginId: "gallery-login",
          url: "https://claude.ai/oauth/authorize",
          needsCode: true,
          ...(approve
            ? {
                autoUrl: "https://claude.ai/oauth/authorize?redirect_uri=http%3A%2F%2Flocalhost%3A54545%2Fcallback",
                callbackPort: 54545,
              }
            : {}),
        };
      // Gemini has no sign-in page (the card never starts one).
      if (agent === "gemini") throw new LoginStepError("unsupported");
      return { loginId: "gallery-login", ...DEVICE_PAGES[agent], needsCode: false };
    },
    open: () => {},
    openOnMachine: async () => true,
    finish: () => new Promise<boolean>(() => {}),
    apiKey: async () => true,
    gateway: async () => true,
    cancel: () => {},
    reserve: async () => undefined,
    resend: async () => {},
  };
}

/// Only a Cloud chat's sign-in card, for its states.
function CloudSignInStates({ agent, approve, fail }: { agent: LoginAgent; approve: boolean; fail?: LoginFailure }) {
  return (
    <main className="acpmux-scroll" style={{ padding: 18, overflow: "auto", height: "100%", boxSizing: "border-box" }}>
      <TurnActionsContext.Provider
        value={{
          switchModel: () => {},
          cloudSignIn: gallerySignIn(agent, approve, fail),
          route: { name: AGENT_NAMES[agent], harness: agent, hostKind: "cloud" },
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

function TranscriptType({
  signIn,
  approve = false,
  fail,
}: {
  signIn?: LoginAgent;
  approve?: boolean;
  fail?: LoginFailure;
}) {
  if (signIn) return <CloudSignInStates agent={signIn} approve={approve} fail={fail} />;
  const [viewer, setViewer] = useState(false);
  return (
    <main className="acpmux-scroll" style={{ padding: 18, overflow: "auto", height: "100%", boxSizing: "border-box" }}>
      <PlainCode lang="typescript" code={"export const retry = 3;\n\nretry();"} open />
      <EditDiff file={file} />
      <ShellBlock command="cd ~/src/atlas && bun test" output={output} exitCode={2} />
      <div data-type="tool-output">
        <ToolRow item={tool("Fetch retry log", "fetch", "completed", { output })} />
      </div>
      {/* A script the verb table does not know (commandActions.ts), so the row draws its line in mono. */}
      <CommandRow
        item={tool("Run retry tests", "execute", "completed", { command: "./scripts/retry-check.sh", exitCode: 2 })}
      />
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
    "cursor-sign-in": {
      props: { signIn: "cursor" },
      note: "A Cloud chat whose Cursor agent is not signed in on its machine: one Sign in to Cursor button and no Use an API key (a Cursor key goes in as the Cloud secret CURSOR_API_KEY).",
    },
    "cursor-approve": {
      props: { signIn: "cursor" },
      note: "After the one Sign in to Cursor click: cursor-agent login runs on the machine, its cursor.com page is open, and the card waits for the approve with no code to type.",
      play: async (ctx) => {
        await ctx.click({ selector: ".cv-turn-error__primary" });
        await ctx.waitFor(() => ctx.document.querySelector(".cv-turn-signin__text"));
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
    "gemini-sign-in": {
      props: { signIn: "gemini" },
      note: "A Cloud chat whose Gemini CLI is not signed in on its machine: Gemini signs in there with a key only, so Use an API key is the card's one filled button, with no sign-in page.",
    },
    "gemini-key-entry": {
      props: { signIn: "gemini" },
      note: "After Use an API key for Gemini: the key field, saved to the machine's .gemini/.env (and settings.json picks the key) where Gemini CLI reads it.",
      play: async (ctx) => {
        await ctx.click({ selector: ".cv-turn-error__primary" });
        await ctx.waitFor(() => ctx.document.querySelector('.cv-turn-signin__input[type="password"]'));
      },
    },
    "grok-sign-in": {
      props: { signIn: "grok" },
      note: "A Cloud chat whose Grok is not signed in on its machine: one Sign in to Grok button, and no Use an API key (Grok reads its key from the person's vault).",
    },
    "grok-code": {
      props: { signIn: "grok" },
      note: "After the one Sign in to Grok click: grok login --device-auth runs on the machine, its accounts.x.ai page is open and its device code is shown, already copied, while the card waits for the approval.",
      play: async (ctx) => {
        await ctx.click({ selector: ".cv-turn-error__primary" });
        await ctx.waitFor(() => ctx.document.querySelector(".cv-turn-signin__code"));
      },
    },
    "grok-team-machine": {
      props: { signIn: "grok", fail: "shared_machine" },
      note: "Sign in to Grok on a team Cloud machine: acpmux refuses an own sign-in there (every member runs as the same user), and the card says so with no Retry.",
      play: async (ctx) => {
        await ctx.click({ selector: ".cv-turn-error__primary" });
        await ctx.waitFor(() => ctx.document.querySelector(".cv-turn-signin__error"));
      },
    },
    "claude-sign-in-cancel": {
      props: { signIn: "claude" },
      note: "Opening the code form and cancelling resize the card over the shared micro duration; the final card is the original sign-in state.",
      play: async (ctx) => {
        await ctx.click({ selector: ".cv-turn-error__primary" });
        await ctx.waitFor(() => ctx.document.querySelector(".cv-turn-signin__input"));
        await ctx.click({ selector: ".cv-turn-signin__row .cv-turn-auth-action:nth-child(2)" });
        await ctx.waitFor(() => !ctx.document.querySelector(".cv-turn-signin__input"));
      },
    },
  },
});
