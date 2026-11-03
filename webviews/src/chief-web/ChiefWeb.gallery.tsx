// l10n-allow-file: gallery fixtures, not shipped UI.
import { componentEntry } from "../gallery/format";
import type { ChiefWebProps } from "./ChiefWeb";
import { ExpiredSession, type ChiefIdentity, type SocketLike } from "./wire";
import { memoryStorage } from "../agent-session/guest/fixtures/liveChat";

const identity: ChiefIdentity = {
  handle: "alex",
  mainConversationId: "conv_chief",
  chiefId: "agent_chief",
};
const state = {
  id: identity.mainConversationId,
  title: "Chief",
  participants: [
    { id: "user_alex", kind: "person", display_name: "Alex" },
    { id: "agent_chief", kind: "agent", agent_class: "mux", display_name: "Chief" },
  ],
};
const message = (id: string, seq: number, author: string, text: string) => ({
  id,
  seq,
  author,
  conversation: state.id,
  parts: [{ type: "text", text }],
  created_at: "2026-11-01T12:00:00Z",
  client_msg_id: id,
});

function fixture(
  mode: "reply" | "empty" | "streaming" | "reconnecting" | "signin-claude" | "signin-code" | "signin-codex" = "reply",
): ChiefWebProps {
  const login = {
    loginId: "gallery-login",
    url: mode === "signin-codex" ? "https://auth.openai.com/codex/device" : "https://claude.ai/oauth/authorize",
    needsCode: mode !== "signin-codex",
    ...(mode === "signin-codex" ? { userCode: "ABCD-1234" } : {}),
  };
  return {
    storage: memoryStorage(),
    loginApi: {
      status: async () => ({
        waiting: true,
        harness: mode === "signin-codex" ? "codex" : "claude",
        login: mode === "signin-claude" ? null : login,
      }),
      start: async () => login,
      finish: async () => ({ signedIn: true, resumed: true }),
      cancel: async () => undefined,
    },
    api: {
      me: async () => identity,
      ticket: async () => ({
        ticket: "gallery-ticket",
        websocketUrl: "wss://api.invalid/chief-wire",
      }),
      send: async () => undefined,
    },
    openSocket: () => {
      let alive = true;
      let greeted = false;
      const socket: SocketLike = {
        onopen: null,
        onmessage: null,
        onclose: null,
        close: () => {
          alive = false;
        },
        send: (data) => {
          if (!alive || JSON.parse(data).t !== "subscribe" || greeted) return;
          greeted = true;
          const rows =
            mode === "empty"
              ? []
              : [
                  message("prompt", 1, "user_alex", "Build me a hello page I can share."),
                  ...(mode === "streaming"
                    ? []
                    : [
                        message(
                          "reply",
                          2,
                          "agent_chief",
                          "Your hello page is ready.\n\n[Open your page](https://hello.preview-development.cmux.dev)\n\nYou can share that link with anyone.",
                        ),
                      ]),
                ];
          if (mode.startsWith("signin"))
            rows.push({
              ...message(
                "machine-auth",
                3,
                identity.chiefId,
                mode === "signin-codex" ? "Sign in to Codex to continue." : "Sign in to Claude to continue.",
              ),
              client_msg_id: `chief-machine-auth:${identity.chiefId}:run_42`,
            });
          queueMicrotask(() => {
            if (!alive) return;
            void socket.onmessage?.({
              data: JSON.stringify({
                t: "snapshot",
                stream: `conv:${state.id}`,
                seq: 2,
                state,
                rows: { table: "msg", rows: rows.map((row) => ({ key: row.id, n: row.seq, row })) },
              }),
            });
            if (mode === "streaming")
              void socket.onmessage?.({
                data: JSON.stringify({
                  t: "step.delta",
                  conversation: state.id,
                  author: "agent_chief",
                  run: "run_1",
                  step: "talk:0",
                  kind: "talk",
                  seq: 0,
                  text: "I’m building your hello page. I’ll send you a link you can open and share.",
                }),
              });
            if (mode === "reconnecting") socket.onclose?.({ code: 1006 });
          });
        },
      };
      queueMicrotask(() => {
        if (alive)
          void socket.onmessage?.({
            data: JSON.stringify({ t: "welcome", principal: { user: "user_alex" } }),
          });
      });
      return socket;
    },
  };
}

export default componentEntry<ChiefWebProps>({
  id: "chief-web.mobile",
  title: "Chief on the web",
  area: "Home and Chief",
  covers: ["chief-web/ChiefWeb.tsx"],
  height: 844,
  widths: { narrow: 390, normal: 768, wide: 1280 },
  pane: true,
  load: () => import("./ChiefWeb").then((module) => module.ChiefWeb),
  variants: {
    "phone-light": {
      props: fixture(),
      note: "Selected: quiet header, readable replies, composer above the keyboard.",
    },
    "phone-dark": { props: fixture(), note: "The same phone layout in dark appearance." },
    tablet: { props: fixture(), height: 1024 },
    desktop: { props: fixture(), height: 900 },
    empty: { props: fixture("empty") },
    streaming: { props: fixture("streaming") },
    reconnecting: { props: fixture("reconnecting") },
    "machine-claude": {
      props: fixture("signin-claude"),
      note: "Selected: one quiet run-scoped sign-in card above the composer.",
    },
    "machine-claude-code": {
      props: fixture("signin-code"),
      note: "A validated provider link remains clickable while its one-use code is pasted.",
    },
    "machine-codex": {
      props: fixture("signin-codex"),
      note: "Device code and explicit continuation, without a code-paste field.",
    },
    expired: {
      props: {
        storage: memoryStorage(),
        api: {
          me: async () => {
            throw new ExpiredSession();
          },
          ticket: async () => ({ ticket: "", websocketUrl: "" }),
          send: async () => undefined,
        },
      },
    },
  },
});
