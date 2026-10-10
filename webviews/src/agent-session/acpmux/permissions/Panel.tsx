import React, { useEffect, useRef, useState } from "react";
import { useT, type StringKey } from "../i18n";
import { SHORTCUT_ACTIONS, useShortcut, withShortcut } from "../shortcuts";
import { ChevronRightIcon } from "../ComposerPickers";
import { Icon } from "../icons/Icon";
import type { PermissionClientState, PermissionDecision, PermissionGroup } from "./protocol";

const choices: Record<PermissionDecision, StringKey> = {
  allow_once: "permission.allowOnce",
  allow_chat: "permission.allowChat",
  deny: "permission.deny",
};

type Props = {
  state: PermissionClientState;
  onRespond(groupId: string, revision: number, decision: PermissionDecision): void;
  onRetry(): void;
  onRevoke(): void;
  onRefresh(): void;
};

/// The kind of a request, as its agent reports it (ACP ToolKind), and the icon that draws it.
const KIND_ICON: Record<string, string> = {
  execute: "terminal",
  edit: "tool.edit",
  delete: "file",
  move: "file",
  read: "file.text",
  search: "tool.search",
  fetch: "search",
};

function toolOf(item: PermissionGroup["items"][number]) {
  const raw = item.request.toolCall;
  return raw && typeof raw === "object" && !Array.isArray(raw) ? (raw as Record<string, unknown>) : undefined;
}

function KindIcon({ kind }: { kind: string }) {
  return (
    <span className="grid size-6 flex-none place-items-center rounded-md bg-hover text-muted" aria-hidden="true">
      <Icon name={KIND_ICON[kind] ?? "composer.command"} size={14} />
    </span>
  );
}

/// One request: a single disclosure row (the request itself, or "Expand details" when the title
/// already names it) that shows the folders it touches and its full input. Agent input renders
/// as text, never markup.
function RequestRow({
  item,
  label,
  open,
  hint,
}: {
  item: PermissionGroup["items"][number];
  label?: string;
  open: number;
  hint?: string;
}) {
  const t = useT();
  const details = useRef<HTMLDetailsElement>(null);
  useEffect(() => {
    if (open > 0 && details.current) details.current.open = true;
  }, [open]);
  const tool = toolOf(item);
  const title = typeof tool?.title === "string" ? tool.title : t("permission.toolRequest");
  const kind = typeof tool?.kind === "string" ? tool.kind : "";
  const paths = Array.isArray(tool?.locations)
    ? tool.locations
        .map((location) =>
          location && typeof location === "object" ? (location as Record<string, unknown>).path : undefined,
        )
        .filter((path): path is string => typeof path === "string")
    : [];
  return (
    <details ref={details}>
      <summary className="group/row flex cursor-default list-none items-center gap-2 rounded-lg px-1.5 py-1 text-detail text-muted hover:bg-hover focus-visible:outline focus-visible:outline-1 focus-visible:outline-fg [&::-webkit-details-marker]:hidden">
        <span className="flex-none transition-transform duration-100 group-open/row:rotate-90 motion-reduce:transition-none">
          <ChevronRightIcon />
        </span>
        {label ? (
          <span className="flex items-center gap-1.5">
            {label}
            <Hint keys={hint} />
          </span>
        ) : (
          <>
            <span className="min-w-0 truncate font-mono text-fg">{title}</span>
            {kind && <span className="flex-none text-dim">{kind}</span>}
          </>
        )}
        {item.state !== "pending" && (
          <span className="flex-none text-dim">
            {t(item.state === "cancelled" ? "permission.itemCancelled" : "permission.itemResolved")}
          </span>
        )}
      </summary>
      <div className="mt-1 mb-1 ml-7 flex flex-col gap-1.5">
        {paths.length > 0 && (
          <ul className="m-0 list-none p-0 font-mono text-caption text-muted">
            {paths.map((path, index) => (
              <li key={index} className="break-all">
                {path}
              </li>
            ))}
          </ul>
        )}
        {tool?.rawInput !== undefined && (
          <pre className="m-0 max-h-56 overflow-auto rounded-lg border-[0.5px] border-edge bg-base p-2 font-mono text-caption whitespace-pre-wrap break-all text-fg">
            {typeof tool.rawInput === "string" ? tool.rawInput : JSON.stringify(tool.rawInput, null, 2)}
          </pre>
        )}
        {tool?.content !== undefined && (
          <pre className="m-0 max-h-56 overflow-auto rounded-lg border-[0.5px] border-edge bg-base p-2 font-mono text-caption whitespace-pre-wrap break-all text-fg">
            {JSON.stringify(tool.content, null, 2)}
          </pre>
        )}
        {tool?.rawInput === undefined && tool?.content === undefined && (
          <p className="m-0 text-caption text-dim">{t("permission.noInput")}</p>
        )}
      </div>
    </details>
  );
}

function GroupItems({ group, expandSignal }: { group: PermissionGroup; expandSignal: number }) {
  return (
    <div className="flex flex-col">
      {group.items.map((item) => (
        <RequestRow key={item.permissionId} item={item} open={expandSignal} />
      ))}
    </div>
  );
}

/// The question in the card's title: one request names its command or tool as code ("Run
/// `bun add x`?"); several count themselves.
function AskTitle({ group }: { group: PermissionGroup }) {
  const t = useT();
  if (group.items.length !== 1) return <>{t("permission.count.other", { n: group.items.length })}</>;
  const tool = toolOf(group.items[0]!);
  const title = typeof tool?.title === "string" ? tool.title : t("permission.toolRequest");
  const marker = "\u0001";
  const [before = "", after = ""] = t(tool?.kind === "execute" ? "permission.ask.run" : "permission.ask.allow", {
    tool: marker,
  }).split(marker);
  return (
    <>
      {before}
      <code className="rounded-md bg-hover px-1 font-mono [overflow-wrap:anywhere] text-fg">{title}</code>
      {after}
    </>
  );
}

const buttonBase =
  "inline-flex h-8 cursor-default items-center gap-1.5 rounded-lg border-0 px-3 font-[inherit] text-control disabled:opacity-50 focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-fg";
/// One primary action (a fill in the text color with the card fill as its text, so it contrasts in
/// every theme), one secondary (a filled dark chip), and a quiet tertiary; never blue (board
/// principle 2).
const VARIANT: Record<PermissionDecision, { name: "primary" | "secondary" | "tertiary"; className: string }> = {
  allow_once: { name: "primary", className: "bg-fg text-menu hover:opacity-90" },
  allow_chat: {
    name: "secondary",
    className: "bg-hover text-fg hover:bg-[color-mix(in_srgb,var(--agent-text)_14%,transparent)]",
  },
  deny: { name: "tertiary", className: "bg-transparent text-muted hover:bg-hover hover:text-fg" },
};
/// Left to right: the quiet choice first, the primary last, at the trailing edge (macOS order).
const ORDER: PermissionDecision[] = ["deny", "allow_chat", "allow_once"];

/// A shortcut hint: quiet keycaps that show while the card is hovered or focused, or while
/// Option-Command is held. Hidden from assistive technology; the button's name is the verb.
function Hint({ keys }: { keys?: string }) {
  if (!keys) return null;
  return (
    <kbd
      aria-hidden="true"
      className="hidden font-sans text-caption opacity-60 group-hover/perm:inline group-focus-within/perm:inline group-data-[hints=true]/perm:inline"
    >
      {keys}
    </kbd>
  );
}

export function PermissionPanel({ state, onRespond, onRetry, onRevoke, onRefresh }: Props) {
  const t = useT();
  const shortcuts = {
    allow_once: useShortcut(SHORTCUT_ACTIONS.permissionAllowOnce),
    allow_chat: useShortcut(SHORTCUT_ACTIONS.permissionAllowChat),
    deny: useShortcut(SHORTCUT_ACTIONS.permissionDeny),
  } satisfies Record<PermissionDecision, string | undefined>;
  const retryShortcut = useShortcut(SHORTCUT_ACTIONS.permissionRetry);
  const revokeShortcut = useShortcut(SHORTCUT_ACTIONS.permissionRevoke);
  const refreshShortcut = useShortcut(SHORTCUT_ACTIONS.permissionRefresh);
  const expandShortcut = useShortcut(SHORTCUT_ACTIONS.permissionExpand);
  const [expandSignal, setExpandSignal] = useState(0);
  // Holding Option-Command (the permission shortcuts' modifiers) shows every hint at once.
  const [hints, setHints] = useState(false);
  useEffect(() => {
    const track = (event: KeyboardEvent) => setHints(event.altKey && event.metaKey);
    const clear = () => setHints(false);
    window.addEventListener("keydown", track);
    window.addEventListener("keyup", track);
    window.addEventListener("blur", clear);
    return () => {
      window.removeEventListener("keydown", track);
      window.removeEventListener("keyup", track);
      window.removeEventListener("blur", clear);
    };
  }, []);
  const pendingRef = useRef<typeof state.groups>([]);
  const stateRef = useRef(state);
  stateRef.current = state;
  pendingRef.current = state.groups.filter((group) => group.state === "pending" || group.state === "collecting");
  const callbacks = useRef({ onRespond, onRetry, onRevoke, onRefresh });
  callbacks.current = { onRespond, onRetry, onRevoke, onRefresh };
  useEffect(() => {
    const handlers = new Map<string, EventListener>([
      ["permissionAllowOnce", () => respondToPending("allow_once")],
      ["permissionAllowChat", () => respondToPending("allow_chat")],
      ["permissionDeny", () => respondToPending("deny")],
      ["permissionRetry", runRetry],
      ["permissionRevoke", runRevoke],
      ["permissionRefresh", runRefresh],
      ["permissionExpand", () => setExpandSignal((value) => value + 1)],
    ]);
    function respondToPending(decision: PermissionDecision) {
      const current = stateRef.current;
      if (!current.supported || current.busy || current.loading || current.ready === false || current.uncertain) return;
      const group = pendingRef.current.find(
        (candidate) => candidate.state === "pending" && candidate.decisions.includes(decision),
      );
      if (group) callbacks.current.onRespond(group.groupId, group.revision, decision);
    }
    function runRetry() {
      const current = stateRef.current;
      if (current.supported && current.uncertain && !current.busy && !current.loading) callbacks.current.onRetry();
    }
    function runRevoke() {
      const current = stateRef.current;
      if (current.supported && current.chatAllowance && !current.busy && !current.loading && !current.uncertain)
        callbacks.current.onRevoke();
    }
    function runRefresh() {
      const current = stateRef.current;
      if (current.supported && !!current.error && !current.busy && !current.loading) callbacks.current.onRefresh();
    }
    for (const [name, handler] of handlers) window.addEventListener(`cmux-acpmux-${name}`, handler);
    return () => {
      for (const [name, handler] of handlers) window.removeEventListener(`cmux-acpmux-${name}`, handler);
    };
  }, []);
  if (!state.supported) return null;
  const pending = state.groups.filter((group) => group.state === "pending" || group.state === "collecting");
  const receipt = pending.length === 0 ? state.groups.at(-1) : undefined;
  if (!pending.length && !receipt && !state.chatAllowance && !state.error) return null;
  const disabled = state.busy || state.loading || state.ready === false || !!state.uncertain;
  return (
    <section
      className="acpmux-permission acpmux-permission-panel"
      aria-label={t("permission.title")}
      aria-busy={state.busy}
    >
      {state.chatAllowance && (
        <div className="flex items-center justify-between gap-3 px-1 text-detail text-muted">
          <span>{t("permission.chatAllowed")}</span>
          <button
            type="button"
            className={`${buttonBase} h-7 px-2.5 ${VARIANT.allow_chat.className}`}
            onClick={onRevoke}
            title={withShortcut(t("permission.revoke"), revokeShortcut)}
            disabled={disabled}
          >
            {t("permission.revoke")}
          </button>
        </div>
      )}
      {pending.map((group) => (
        <div
          key={group.groupId}
          data-permission-card=""
          data-hints={String(hints)}
          className="group/perm rounded-xl border-[0.5px] border-edge bg-menu p-3 text-fg shadow-[0_1px_2px_rgb(0_0_0/0.18)]"
        >
          <div className="flex flex-wrap items-start gap-x-2.5 gap-y-1.5">
            {group.items.length === 1 && <KindIcon kind={String(toolOf(group.items[0]!)?.kind ?? "")} />}
            <div className="min-w-0 flex-1 basis-48">
              <div data-permission-title="" className="text-title font-semibold">
                <AskTitle group={group} />
              </div>
            </div>
            <span
              data-permission-isolation=""
              title={t("permission.coverageDetail")}
              className="mt-0.5 max-w-full flex-none truncate rounded-md border-[0.5px] border-edge px-1.5 text-caption text-warning"
            >
              {t("permission.coverage")}
            </span>
          </div>
          <div className="mt-2">
            {group.items.length === 1 ? (
              <RequestRow
                item={group.items[0]!}
                label={t("permission.expand")}
                open={expandSignal}
                hint={expandShortcut}
              />
            ) : (
              <GroupItems group={group} expandSignal={expandSignal} />
            )}
          </div>
          {group.state === "collecting" ? (
            <output className="mt-2 block text-detail text-muted">{t("permission.collecting")}</output>
          ) : (
            <>
              {!group.decisions.includes("allow_once") && (
                <p className="mt-2 mb-0 text-detail text-muted">{t("permission.denyOnly")}</p>
              )}
              <div className="mt-3 flex flex-wrap items-center justify-end gap-2">
                {ORDER.filter((decision) => group.decisions.includes(decision)).map((decision) => (
                  <button
                    key={decision}
                    type="button"
                    data-decision={decision}
                    data-variant={VARIANT[decision].name}
                    aria-label={t(choices[decision])}
                    title={decision === "allow_chat" ? t("permission.chatScope") : undefined}
                    className={`${buttonBase} ${VARIANT[decision].className}`}
                    onClick={() => onRespond(group.groupId, group.revision, decision)}
                    disabled={disabled}
                  >
                    {t(choices[decision])}
                    <Hint keys={shortcuts[decision]} />
                  </button>
                ))}
              </div>
            </>
          )}
        </div>
      ))}
      {receipt && (
        <details className="acpmux-permission-receipt px-1 text-detail text-muted">
          <summary className="cursor-default">
            {receipt.state === "cancelled"
              ? t("permission.cancelled")
              : receipt.decision
                ? t(choices[receipt.decision])
                : t("permission.answered")}
          </summary>
          <GroupItems group={receipt} expandSignal={expandSignal} />
        </details>
      )}
      {state.error && (
        <div className="flex items-center justify-between gap-3 px-1 text-detail text-warning" role="alert">
          <span>{state.error}</span>
          <button
            type="button"
            className={`${buttonBase} h-7 px-2.5 ${VARIANT.allow_chat.className}`}
            onClick={state.uncertain ? onRetry : onRefresh}
            title={withShortcut(
              state.uncertain ? t("permission.checkRetry") : t("permission.refresh"),
              state.uncertain ? retryShortcut : refreshShortcut,
            )}
            disabled={state.busy || state.loading}
          >
            {state.uncertain ? t("permission.checkRetry") : t("permission.refresh")}
          </button>
        </div>
      )}
    </section>
  );
}
