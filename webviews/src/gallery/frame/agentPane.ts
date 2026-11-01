// The agent pane host: the real pane entry (acpmux/main.tsx, so AcpmuxApp under its boundary and
// the desktop layer) on a stand-in for the app's pane bridge (`webkit.messageHandlers.agentSession`
// plus `window.cmuxAcpmuxBridge`). `ready` answers the state's host fields with the `preview`
// transport, which runs no client; the state's snapshot then arrives through `receive`, as the
// app's own snapshot does. The theme goes through `applyTheme` (AgentPaneTheme.swift's values) and
// the font through `applyCustomization` (the user's agent pane theme.css), the app's own inputs.
import type { AgentPaneVariant } from "../format";
import { addPseudoLocales } from "../pseudo";
import type { StageContext } from "./context";
import { installChipHost } from "./chips";
import { resetSummaryCards } from "../../agent-session/acpmux/summary/cardState";
import { setChatDisplay } from "../../agent-session/acpmux/chatDisplay";

type Message = { id?: string; method?: string; params?: Record<string, unknown> };

/** The user stylesheet a font control writes: the pane's own type variables. */
export function agentPaneFontCSS(font: string, size: number): string {
  const rules: string[] = [];
  if (font) rules.push(`--cv-font: ${font};`, `--agent-host-font-family: ${font};`);
  if (size) rules.push(`--cv-font-size: ${size}px;`, `--cv-line-height: ${Math.round(size * 1.625 * 100) / 100}px;`);
  return rules.length ? `:root { ${rules.join(" ")} }` : "";
}

const UPLOAD_STEPS = new Set(["chat.upload.begin", "chat.upload.chunk", "chat.upload.finish", "chat.upload.cancel"]);

export async function mountAgentPane(state: AgentPaneVariant, context: StageContext): Promise<void> {
  const strings = (await import("../../agent-session/acpmux/generated/strings.json")).default as unknown as Record<
    string,
    Record<string, string>
  >;
  addPseudoLocales(strings);
  globalThis.__cmuxPaneStrings = strings as never;
  installChipHost(state.chipHost);
  resetSummaryCards();
  // Only the gallery's mock daemon reads these. Clear them between staged variants, so one
  // capture's negative auth cannot leak into the next fixture.
  Object.assign(globalThis, {
    cmuxAcpmuxMockHarnesses: state.mockHarnesses,
    cmuxAcpmuxMockHarnessHealth: state.mockHarnessHealth,
    cmuxAcpmuxMockNative: state.native,
    cmuxAcpmuxMockSessionAuth: state.mockSessionAuth,
    cmuxAcpmuxMockCapabilities: state.mockCapabilities,
    cmuxAcpmuxMockTrustPending: state.mockTrustPending,
    cmuxAcpmuxMockStart: state.mockStart,
  });
  const snapshot = structuredClone(state.snapshot);
  if (state.recording) {
    const { rowsFromRecording } = await import("../fixtures/recording");
    const { harness } = state.recording;
    snapshot.rows = await rowsFromRecording(await state.recording.events(), harness);
    if (snapshot.summary) snapshot.summary = { ...snapshot.summary, harness, family: harness };
    snapshot.sessions = snapshot.sessions.map((entry) => ({ ...entry, harness }));
  }
  const answer = (value: unknown) => ({ ok: true, value });
  // The app's staged upload (cloudUploads.ts: begin, base64 chunks, finish, cancel), so a pasted
  // file goes through the path the app runs. A variant that answers or delays a step in `native` /
  // `nativeDelayMs` takes it over (a refused begin is an older host: the pane uses `chat.upload`).
  // A finished file's path is the one the variant's `chat.upload` fixture gives its name, else one
  // under the gallery's Chat Uploads.
  const uploads = new Map<string, { name: string; size: number; received: number; index: number }>();
  const batches = new Map<string, { files: { name?: unknown; size?: unknown }[]; next: number }>();
  const fixturePath = (name: string): string | undefined => {
    const legacy = state.native?.["chat.upload"] as { uploads?: { name?: unknown; path?: unknown }[] } | undefined;
    const path = legacy?.uploads?.find((upload) => upload.name === name)?.path;
    return typeof path === "string" ? path : undefined;
  };
  const stageUpload = (message: Message): unknown => {
    const method = message.method ?? "";
    if (!UPLOAD_STEPS.has(method)) return undefined;
    const taken = Object.hasOwn(state.native ?? {}, method) || Object.hasOwn(state.nativeDelayMs ?? {}, method);
    if (taken) return undefined;
    const params = message.params ?? {};
    if (method === "chat.upload.begin") {
      const name = String(params.name ?? "");
      const size = Number(params.size ?? 0);
      // A paste of several files: the first begin names them all (`batch`) and gets a batch token;
      // each later file presents it and must be the manifest's next entry, as the host checks.
      let batchToken: string | undefined;
      if (Array.isArray(params.batch)) {
        if (params.batchToken !== undefined) return null;
        batchToken = `gallery-batch-${batches.size}`;
        batches.set(batchToken, { files: params.batch as { name?: unknown; size?: unknown }[], next: 0 });
      }
      const batch = batches.get(batchToken ?? String(params.batchToken ?? ""));
      if (params.batchToken !== undefined && !batch) return null;
      if (batch) {
        const expected = batch.files[batch.next++];
        if (expected?.name !== name || expected?.size !== size) return null;
      }
      const index = uploads.size;
      const token = `gallery-upload-${index}-${name}`;
      uploads.set(token, { name, size, received: 0, index });
      return { token, size, chunkSize: 256 * 1024, ...(batchToken ? { batchToken } : {}) };
    }
    const token = String(params.token ?? "");
    const upload = uploads.get(token);
    if (!upload) return null;
    if (method === "chat.upload.chunk") {
      if (Number(params.offset) !== upload.received) return null;
      upload.received += atob(String(params.data ?? "")).length;
      return { offset: upload.received };
    }
    if (method === "chat.upload.finish" && upload.received === upload.size)
      return {
        path:
          fixturePath(upload.name) ??
          `/Users/dev/Library/Application Support/cmux/Chat Uploads/1/${upload.index}/${upload.name}`,
      };
    return null;
  };
  const deliver = () => {
    const bridge = window.cmuxAcpmuxBridge;
    if (!bridge) return;
    bridge.applyTheme({ ...context.agentTheme, ...state.theme });
    bridge.applyCustomization({ themeCSS: agentPaneFontCSS(context.env.fontFamily, context.env.fontSize) });
    bridge.applySessionStatus?.(state.sessionStatus === true);
    // The chat's look as the app's `display` push sends it (none: the default look).
    setChatDisplay(state.display ?? {});
    bridge.applyWorkflowLabs?.(state.workflowLabs !== false);
    bridge.receive(structuredClone(snapshot));
  };
  const next = (method: string | undefined) => {
    const after =
      method && state.afterCall && Object.hasOwn(state.afterCall, method) ? state.afterCall[method] : undefined;
    // In a task after the answer, as the app's transport sends a snapshot.
    if (after) setTimeout(() => window.cmuxAcpmuxBridge?.receive(structuredClone(after)), 0);
  };
  const handle = (message: Message) => {
    context.log(message.method ?? "?", message.params);
    next(message.method);
    switch (message.method) {
      case "ready":
        // The snapshot follows the answer, as the app's transport sends it: in a task after the
        // pane has read the answer (a new chat or New Tab page resets its snapshot right then).
        setTimeout(deliver, 0);
        return answer({ protocolVersion: 1, transport: "preview", machineName: "This Mac", ...state.ready });
      case "project.list":
      case "file.search":
        return answer(state.native?.[message.method] ?? []);
      default: {
        const staged = stageUpload(message);
        if (staged !== undefined) return answer(staged);
        const value = state.native?.[message.method ?? ""] ?? null;
        // `{ nativeError: {code, userMessage?} }` answers as the app's refusal of the call.
        if (value && typeof value === "object" && "nativeError" in value)
          return { ok: false, error: (value as { nativeError: unknown }).nativeError };
        return answer(value);
      }
    }
  };
  (window as unknown as { webkit: unknown }).webkit = {
    messageHandlers: {
      agentSession: {
        postMessage: (message: Message) => {
          const reply = handle(message);
          const delay = state.nativeDelayMs?.[message.method ?? ""];
          return delay ? new Promise((resolve) => setTimeout(() => resolve(reply), delay)) : Promise.resolve(reply);
        },
      },
    },
  };
  document.documentElement.dataset.cmuxWebviewKind = "acpmux-agent-session";
  // Before the pane's scripts run, as AgentPaneTunables.documentScript sets them in the app.
  for (const [name, value] of Object.entries(state.documentAttributes ?? {}))
    document.documentElement.setAttribute(`data-${name}`, value);
  // The desktop layer first (the pane's main.tsx imports it): it inserts desktop.css and the liquid
  // glass (ui/glass/glass.css) on their own, and the pane's sheet, which holds them in the shipped
  // order ahead of the pane's own sheets, must come after so a surface's rules outrank `.ui-glass`
  // as they do in the app.
  await import("../../pages/shared/desktop");
  await import("virtual:cmux-gallery/agent-pane.css");
  await import("katex/dist/katex.min.css");
  await import("../../agent-session/acpmux/main");
  // main.tsx imports some pane sheets itself (styles.css, diffTokens.css, composerFooterShared.css,
  // #26126). The app's bundle drops those imports and ships each sheet once in dev.tsx's order, but
  // here each lands as a second copy after the pane's sheet, so styles.css's base rules outranked the
  // later sheets' (the quiet row took the bar's 10 px padding back). The pane's sheet goes last again,
  // after every copy, so the shipped order wins.
  const paneSheet = document.querySelector('style[data-vite-dev-id$="/agent-pane.virtual.css"]');
  if (paneSheet) document.head.append(paneSheet);
}
