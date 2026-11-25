/// The chat's Customize bar, as data: what `cmux --json customize status` says (cmux-customize
/// `Status`, cli/customize/render.rs `status_json`) turned into what the bar shows. The verbs it runs
/// are the CLI's own (`cmux.customize.run`, CmuxNextApps CustomizeChatPage.swift), so nothing here
/// decides what a preview, an apply or an undo is: it only reads the answer.

/// The parts a customization changes (cmux-customize `tree.rs` `Part`, kebab case on the wire).
export const CUSTOMIZE_PARTS = ["settings", "keybindings", "themes", "views", "styles", "automations"] as const;
export type CustomizePart = (typeof CUSTOMIZE_PARTS)[number];

export type CustomizeProblem = { path: string; line?: number; message: string };

export type CustomizeBarState =
  /** Nothing is previewing: what is live is what is applied. */
  | { kind: "idle"; generation?: number }
  /** A draft is live in the window and not yet applied. */
  | {
      kind: "preview";
      /** The newest ask, in the person's words; empty for a hand edit. */
      wish: string;
      /** The parts the preview changes, in `CUSTOMIZE_PARTS` order. */
      parts: CustomizePart[];
      files: number;
      /** A file the person edited by hand since the agent's last turn. */
      byHand: boolean;
      problems: CustomizeProblem[];
      canApply: boolean;
      /** The applied generation the draft sits on. */
      generation?: number;
    };

/** The verbs the bar runs (CustomizeChatPage.verbs). */
export type CustomizeVerb = "status" | "apply" | "discard" | "rollback" | "save";

function record(value: unknown): Record<string, unknown> | undefined {
  return value && typeof value === "object" && !Array.isArray(value) ? (value as Record<string, unknown>) : undefined;
}

function isPart(value: unknown): value is CustomizePart {
  return typeof value === "string" && (CUSTOMIZE_PARTS as readonly string[]).includes(value);
}

/** The message of a refusal (`{code, message}`, or `{error: {code, message}}`), else undefined. */
export function refusalMessage(answer: unknown): string | undefined {
  const top = record(answer);
  const error = record(top?.error) ?? (typeof top?.code === "string" ? top : undefined);
  if (!error) return undefined;
  return typeof error.message === "string" && error.message.trim() ? error.message : String(error.code ?? "");
}

/** The bar's state for a status answer; a refusal or a shape it cannot read is `idle`. */
export function barState(answer: unknown): CustomizeBarState {
  // `brief` and an ask answer carry the status under `status`.
  const top = record(answer);
  const status = record(top?.status) && !Array.isArray(top?.changes) ? record(top?.status) : top;
  if (!status || refusalMessage(status) !== undefined) return { kind: "idle" };
  const current = record(status.current);
  const generation = typeof current?.n === "number" ? current.n : undefined;
  const changes = Array.isArray(status.changes) ? status.changes.map(record).filter((c) => c !== undefined) : [];
  if (changes.length === 0) return generation === undefined ? { kind: "idle" } : { kind: "idle", generation };
  const changed = new Set(changes.map((change) => change.part).filter(isPart));
  const asks = Array.isArray(record(status.draft)?.asks) ? (record(status.draft)!.asks as unknown[]) : [];
  const last = record(asks[asks.length - 1]);
  const problems: CustomizeProblem[] = (Array.isArray(status.problems) ? status.problems : [])
    .map(record)
    .filter((p) => p !== undefined && typeof p.message === "string")
    .map((p) => ({
      path: typeof p!.path === "string" ? p!.path : "",
      ...(typeof p!.line === "number" ? { line: p!.line } : {}),
      message: p!.message as string,
    }));
  return {
    kind: "preview",
    wish: typeof last?.text === "string" ? last.text.trim() : "",
    parts: CUSTOMIZE_PARTS.filter((part) => changed.has(part)),
    files: changes.length,
    byHand: changes.some((change) => change.by_hand === true),
    problems,
    canApply: status.can_apply !== false && problems.length === 0,
    ...(generation === undefined ? {} : { generation }),
  };
}

/** A profile name the CLI takes (CustomizeChatPage.isProfileName): what a typed name becomes. */
export function profileName(typed: string): string | undefined {
  const name = typed
    .trim()
    .toLowerCase()
    .replace(/\s+/g, "-")
    .replace(/[^a-z0-9_-]/g, "")
    .replace(/^[-_]+/, "")
    .slice(0, 64);
  return name ? name : undefined;
}
