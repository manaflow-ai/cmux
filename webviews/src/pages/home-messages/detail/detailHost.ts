// The detail's host bridge (`cmux.home.messages.*`, HomeMessagesPage.swift): what the transcript
// and its cards read from the app and send to it. Every stream event and answer is parsed: the host
// is another build, and a value that is not one reads as nothing.
//
//   appearance (stream)  {look, chiefLook, defaults: ChatColors, colors: {[id]: ChatColors}}
//   headerPanels (stream) {enabled, panels: HeaderPanelState[]}; headerPanels.toggle {id}
//   dictation {method, params} -> the result; dictation (stream): DictationUpdate events
//   linkPreview {url, kind, details} -> HomeLinkPreview
//   openLink {url}: an app link or a path a chip opened (the host opens it, never the system)
//   firstRun (stream) {introKind?, memoryOffer?, petShown?, shortcuts?, agents?, switchKeys?,
//                      starters?}: the empty Chief chat's host facts (HomeMessagesFirstRun.swift)
//   chief.settings {conversation, anchor: {x, y, width, height}}: the Chief's settings popover under
//                      the name pill (a click only)
//   chiefFace (stream) {conversation, picture?, text?}: the shown Chief's header avatar as the app reads it
//   chiefPlace (stream) {conversation, chip: {tone, text, glyph, label, help}} | null: its location chip;
//                      chief.place {conversation, anchor}: the Teleport menu under the chip (a click only)
//   needsYou (stream) {route} | null: the shown Chief chat's pinned Needs you, the Feed page's own view
//                      on `route` (cards/needsYou); while it shows, its cmux.feed.* calls go on the Feed's
//                      relay and needsYou.action runs its cmux.app.action.run (a click only)
//   bubble.facts {conversation} -> {linkScheme?, forward, share, retryReply, files}: what a bubble's
//                      menu may offer in this conversation (bubbleMenu.ts)
//   bubble.retryReply {conversation, message}, bubble.forward {text}, bubble.share {text | url},
//   bubble.file {action, path | attachment {conversation, message, partIndex, part}}: its rows' runs
//   toastAvoidance {rects: [{left, top, right, bottom}] | []}: the compose bar's box (viewport CSS
//                      pixels), which the app's toasts rest above (HomePageToastAvoidance.swift)
//   attachment.drag {conversation, message, partIndex, attachment}: the host drags the attachment out as
//                      a Finder file promise while the press is held -> {started}
// Stop, Stop all agents, Continue, Restart and Start now are transcript/chiefTurn.ts's.
import { useEffect, useMemo, useState } from "react";
import type { DictationUpdate } from "../../../agent-session/acpmux/dictationText";
import { deliverDictation } from "../../../agent-session/acpmux/dictation";
import { toastAvoidanceReports, type ToastAvoidanceReports } from "../../../agent-session/acpmux/toastAvoidance";
import type { HomeAttachment, HomeConversation } from "../../home-channels/types";
import { isPageError, type PageClient } from "../../shared/pageClient";
import type { HeaderPanelState } from "../cards/header/HeaderPanelBar";
import { HEADER_PANEL_STATE_EVENT, HEADER_PANEL_TOGGLE_OP } from "../cards/header/HeaderPanelBar";
import type { HomeLinkPreview, LinkPreviewFetch } from "../cards/links/linkPreview";
import type {
  AgentGlance,
  AgentGlanceStatus,
  ChiefIntroKind,
  StarterContext,
  SwitchKeys,
} from "../cards/firstRun/firstRunModel";
import { LINK_PREVIEW_OP } from "../cards/links/linkPreview";
import { BUBBLE_LOOKS, type BubbleLook, type ChatColors } from "../transcript/colors";
import { NO_BUBBLE_HOST, type BubbleHostFacts, type FileAction, type FileTarget } from "../transcript/bubbleMenu";
import type { DictationCall } from "../transcript/MessageComposer";

export const DetailOps = {
  appearance: "cmux.home.messages.appearance",
  headerPanels: HEADER_PANEL_STATE_EVENT,
  headerPanelToggle: HEADER_PANEL_TOGGLE_OP,
  dictation: "cmux.home.messages.dictation",
  linkPreview: LINK_PREVIEW_OP,
  openLink: "cmux.home.messages.openLink",
  firstRun: "cmux.home.messages.firstRun",
  chiefSettings: "cmux.home.messages.chief.settings",
  chiefFace: "cmux.home.messages.chiefFace",
  chiefPlace: "cmux.home.messages.chiefPlace",
  chiefPlaceOpen: "cmux.home.messages.chief.place",
  needsYou: "cmux.home.messages.needsYou",
  needsYouAction: "cmux.home.messages.needsYou.action",
  bubbleFacts: "cmux.home.messages.bubble.facts",
  bubbleRetryReply: "cmux.home.messages.bubble.retryReply",
  bubbleForward: "cmux.home.messages.bubble.forward",
  bubbleShare: "cmux.home.messages.bubble.share",
  bubbleFile: "cmux.home.messages.bubble.file",
  toastAvoidance: "cmux.home.messages.toastAvoidance",
  attachmentDrag: "cmux.home.messages.attachment.drag",
} as const;

/** The `attachment.drag` params of `part`, the `partIndex`th part of `message` (its wire shape). */
export function attachmentDragParams(
  message: { id: string; conversation: string },
  part: HomeAttachment,
  partIndex: number,
) {
  const { type: _type, ...attachment } = part;
  return { conversation: message.conversation, message: message.id, partIndex, attachment };
}

type Json = Record<string, unknown>;
const record = (value: unknown): Json | undefined =>
  value && typeof value === "object" && !Array.isArray(value) ? (value as Json) : undefined;
const HEX = /^#[0-9a-f]{6}$/i;
const COLOR_FIELDS = ["sent", "sentText", "received", "receivedText"] as const;

// ---------- Appearance ----------

export interface MessagesAppearance {
  look: BubbleLook;
  /** A Chief conversation's look. */
  chiefLook: BubbleLook;
  defaults: ChatColors;
  colors: ReadonlyMap<string, ChatColors>;
  /** The message boxes check spelling (Settings agentPane.spellChecking, as the native composer). */
  spellChecking: boolean;
}

export const DEFAULT_APPEARANCE: MessagesAppearance = {
  look: "imessage",
  chiefLook: "imessage",
  defaults: {},
  colors: new Map(),
  spellChecking: false,
};

const lookOf = (value: unknown): BubbleLook | undefined =>
  typeof value === "string" && (BUBBLE_LOOKS as readonly string[]).includes(value) ? (value as BubbleLook) : undefined;

export function parseChatColors(value: unknown): ChatColors {
  const raw = record(value);
  const out: ChatColors = {};
  for (const field of COLOR_FIELDS) {
    const hex = raw?.[field];
    if (typeof hex === "string" && HEX.test(hex.trim())) out[field] = hex.trim();
  }
  return out;
}

export function parseAppearance(event: unknown): MessagesAppearance {
  const raw = record(event);
  const look = lookOf(raw?.look) ?? "imessage";
  const colors = new Map<string, ChatColors>();
  for (const [id, value] of Object.entries(record(raw?.colors) ?? {})) {
    const parsed = parseChatColors(value);
    if (Object.keys(parsed).length) colors.set(id, parsed);
  }
  return {
    look,
    chiefLook: lookOf(raw?.chiefLook) ?? look,
    defaults: parseChatColors(raw?.defaults),
    colors,
    spellChecking: raw?.spellChecking === true,
  };
}

/** One conversation's look and colours: its own over the defaults, field by field. */
export function chatAppearance(
  appearance: MessagesAppearance,
  conversation: Pick<HomeConversation, "id" | "kind">,
): { look: BubbleLook; colors: ChatColors } {
  return {
    look: conversation.kind === "chief" ? appearance.chiefLook : appearance.look,
    colors: { ...appearance.defaults, ...appearance.colors.get(conversation.id) },
  };
}

// ---------- Header panels ----------

export interface HeaderPanelsState {
  /** The Debug toggle: off shows only the always-shown toggles. */
  enabled: boolean;
  panels: readonly HeaderPanelState[];
}

export const NO_HEADER_PANELS: HeaderPanelsState = { enabled: false, panels: [] };

export function parseHeaderPanels(event: unknown): HeaderPanelsState {
  const raw = record(event);
  const panels: HeaderPanelState[] = [];
  for (const entry of Array.isArray(raw?.panels) ? raw.panels : []) {
    const panel = record(entry);
    if (typeof panel?.id !== "string" || !panel.id) continue;
    panels.push({
      id: panel.id,
      isOn: panel.isOn === true,
      ...(typeof panel.shortcut === "string" && panel.shortcut ? { shortcut: panel.shortcut } : {}),
    });
  }
  return { enabled: raw?.enabled === true, panels };
}

// ---------- Dictation ----------

const DICTATION_STATES = new Set(["idle", "starting", "listening", "finalizing", "failed", "denied"]);

/** A dictation event the composer can apply, or undefined. */
export function parseDictationUpdate(event: unknown): DictationUpdate | undefined {
  const raw = record(event);
  if (!raw || typeof raw.state !== "string" || !DICTATION_STATES.has(raw.state)) return undefined;
  if (typeof raw.text !== "string") return undefined;
  const level = typeof raw.level === "number" && Number.isFinite(raw.level) ? Math.min(1, Math.max(0, raw.level)) : 0;
  return { ...(raw as unknown as DictationUpdate), level, cancelled: raw.cancelled === true };
}

// ---------- Streams ----------

/** The newest value of a host stream (parsed), `initial` until the first event or without a host. */
export function useHostStream<T>(host: PageClient | null, stream: string, parse: (event: unknown) => T, initial: T): T {
  const [value, setValue] = useState(initial);
  useEffect(() => {
    if (!host) return;
    let stop: (() => void) | undefined;
    let ended = false;
    void host
      .subscribe<unknown>(stream, (event) => {
        if (!ended) setValue(parse(event));
      })
      .then((unsubscribe) => {
        if (ended) unsubscribe();
        else stop = unsubscribe;
      })
      .catch(() => undefined);
    return () => {
      ended = true;
      stop?.();
    };
    // `parse` is a module function; the stream's name and host define the subscription.
    // oxlint-disable-next-line react-hooks/exhaustive-deps
  }, [host, stream]);
  return value;
}

const unknownOp = (error: unknown) => isPageError(error) && error.code === "cmux.protocol.unknown_op";

/** The host's dictation for the composer, or undefined: no mic until the host has accepted the
 * dictation stream (its capability: a host without dictation refuses the subscription), and none
 * again once a call says the op is unknown. Its events go to every composer listening
 * (`deliverDictation`). */
export function useHostDictation(host: PageClient | null): DictationCall | undefined {
  // The host that accepted the stream; a new host starts without a mic until it does too.
  const [offered, setOffered] = useState<PageClient | null>(null);
  const call = useMemo<DictationCall | undefined>(
    () =>
      host
        ? (method, params) =>
            host.call<unknown>(DetailOps.dictation, { method, params: params ?? {} }).catch((error: unknown) => {
              if (unknownOp(error)) setOffered((current) => (current === host ? null : current));
              throw error;
            })
        : undefined,
    [host],
  );
  useEffect(() => {
    if (!host) return;
    let stop: (() => void) | undefined;
    let ended = false;
    void host
      .subscribe<unknown>(DetailOps.dictation, (event) => {
        const update = parseDictationUpdate(event);
        if (update) deliverDictation(update);
      })
      .then((unsubscribe) => {
        if (ended) return unsubscribe();
        stop = unsubscribe;
        setOffered(host);
      })
      .catch(() => undefined);
    return () => {
      ended = true;
      stop?.();
      setOffered((current) => (current === host ? null : current));
    };
  }, [host]);
  return offered === host ? call : undefined;
}

// ---------- Links ----------

/** The chips' preview read; undefined when the host has none for the link. */
export function linkPreviewFetch(host: PageClient | null): LinkPreviewFetch {
  return async (params) => {
    if (!host) return undefined;
    const answer = await host.call<HomeLinkPreview | null>(DetailOps.linkPreview, params).catch(() => null);
    const raw = record(answer);
    if (!raw || typeof raw.title !== "string" || typeof raw.kind !== "string") return undefined;
    return answer as HomeLinkPreview;
  };
}

// ---------- First run ----------

/** What the host knows for an empty Chief chat's first-run panel. */
export interface FirstRunFacts {
  /** The first-open intro to show (the host keeps which showed: `markIntroShown`). */
  introKind?: ChiefIntroKind;
  memoryOffer?: string;
  petShown?: boolean;
  shortcuts: { terminal?: string; agent?: string };
  agents: readonly AgentGlance[];
  switchKeys?: SwitchKeys;
  starters: StarterContext;
}

export const NO_FIRST_RUN: FirstRunFacts = { shortcuts: {}, agents: [], starters: {} };

const GLANCE = new Set<AgentGlanceStatus>(["needsYou", "failed", "done", "idle", "working"]);
const str = (value: unknown): string | undefined => (typeof value === "string" && value ? value : undefined);
const strings = (value: unknown): string[] | undefined =>
  Array.isArray(value) ? value.filter((entry): entry is string => typeof entry === "string" && !!entry) : undefined;

export function parseFirstRun(event: unknown): FirstRunFacts {
  const raw = record(event);
  if (!raw) return NO_FIRST_RUN;
  const introKind = raw.introKind === "welcome" || raw.introKind === "askFocus" ? raw.introKind : undefined;
  const shortcuts = record(raw.shortcuts);
  const agents: AgentGlance[] = [];
  for (const entry of Array.isArray(raw.agents) ? raw.agents : []) {
    const agent = record(entry);
    const id = str(agent?.id);
    const status = agent?.status as AgentGlanceStatus;
    if (!agent || !id || !GLANCE.has(status)) continue;
    agents.push({ id, title: str(agent.title) ?? id, icon: str(agent.icon) ?? "agent.chat", status });
  }
  const keys = record(raw.switchKeys);
  const switchKeys: SwitchKeys | undefined = keys
    ? {
        ...(str(keys.tabByNumber) ? { tabByNumber: str(keys.tabByNumber) } : {}),
        ...(str(keys.workspaceByNumber) ? { workspaceByNumber: str(keys.workspaceByNumber) } : {}),
        ...(str(keys.nextPreviousTab) ? { nextPreviousTab: str(keys.nextPreviousTab) } : {}),
        ...(str(keys.nextPreviousWorkspace) ? { nextPreviousWorkspace: str(keys.nextPreviousWorkspace) } : {}),
        ...(str(keys.focusBackForward) ? { focusBackForward: str(keys.focusBackForward) } : {}),
        ...(keys.desktopConflict === true ? { desktopConflict: true } : {}),
      }
    : undefined;
  const starters = record(raw.starters);
  return {
    ...(introKind ? { introKind } : {}),
    ...(str(raw.memoryOffer) ? { memoryOffer: str(raw.memoryOffer) } : {}),
    ...(typeof raw.petShown === "boolean" ? { petShown: raw.petShown } : {}),
    shortcuts: {
      ...(str(shortcuts?.terminal) ? { terminal: str(shortcuts?.terminal) } : {}),
      ...(str(shortcuts?.agent) ? { agent: str(shortcuts?.agent) } : {}),
    },
    agents,
    ...(switchKeys ? { switchKeys } : {}),
    starters: {
      ...(strings(starters?.workspaces) ? { workspaces: strings(starters?.workspaces) } : {}),
      ...(strings(starters?.working) ? { working: strings(starters?.working) } : {}),
      ...(strings(starters?.failures) ? { failures: strings(starters?.failures) } : {}),
      ...(strings(starters?.pullRequests) ? { pullRequests: strings(starters?.pullRequests) } : {}),
    },
  };
}

// ---------- Bubble menus ----------

const SCHEME = /^cmux(?:-[a-z0-9]+)*$/;

/** The host's answer to `bubble.facts`; anything else offers nothing. */
export function parseBubbleFacts(value: unknown): BubbleHostFacts {
  const raw = record(value);
  if (!raw) return NO_BUBBLE_HOST;
  const scheme = typeof raw.linkScheme === "string" && SCHEME.test(raw.linkScheme) ? raw.linkScheme : undefined;
  return {
    ...(scheme ? { linkScheme: scheme } : {}),
    forward: raw.forward === true,
    share: raw.share === true,
    retryReply: raw.retryReply === true,
    files: raw.files === true,
  };
}

/** What the open conversation's bubble menus offer: read once per conversation (none without a host). */
export function useBubbleFacts(host: PageClient | null, conversation: string): BubbleHostFacts {
  const [facts, setFacts] = useState<{ conversation: string; facts: BubbleHostFacts }>();
  useEffect(() => {
    if (!host) return;
    let live = true;
    void host
      .call<unknown>(DetailOps.bubbleFacts, { conversation })
      .then(parseBubbleFacts, () => NO_BUBBLE_HOST)
      .then((read) => {
        if (live) setFacts({ conversation, facts: read });
      });
    return () => {
      live = false;
    };
  }, [host, conversation]);
  return facts?.conversation === conversation ? facts.facts : NO_BUBBLE_HOST;
}

/** The runs of a bubble's host rows; each is the person's click (a refusal changes nothing). */
export function bubbleHostActions(host: PageClient | null) {
  const call = (op: string, params: Record<string, unknown>) => void host?.call(op, params).catch(() => undefined);
  return {
    retryReply: (conversation: string, message: string) => call(DetailOps.bubbleRetryReply, { conversation, message }),
    forward: (text: string) => call(DetailOps.bubbleForward, { text }),
    share: (item: { text: string } | { url: string }) => call(DetailOps.bubbleShare, item),
    file: (action: FileAction, target: FileTarget) =>
      call(
        DetailOps.bubbleFile,
        "path" in target
          ? { action, path: target.path }
          : {
              action,
              attachment: {
                conversation: target.conversation,
                message: target.message,
                partIndex: target.partIndex,
                part: target.attachment,
              },
            },
      ),
  };
}

// ---------- Toast avoidance ----------

/** The compose bars' reports to `host` (toastAvoidance.ts's stack, over this page's own op): the
 * app's toasts rest above the newest mounted bar, and none once every bar is gone. */
export function homeToastAvoidance(host: PageClient): ToastAvoidanceReports {
  return toastAvoidanceReports((rects) => host.call(DetailOps.toastAvoidance, { rects }));
}
