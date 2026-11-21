// The Context screen, in place in the pane (as Integrate a harness is): what this chat's agent reads
// besides your messages, from acpmux's inventory (`_acpmux/context`, contextInventory.ts). Text cmux
// adds shows in full under each row; the harness's own system prompt, memory files, MCP tools and
// skills show the tokens the harness measured, since it does not hand cmux their text. Below, the
// guidance cmux sends every new chat is editable for every chat or for this folder
// (`_acpmux/context_override`); a saved edit reaches chats started after it, never a running one.
//
// Leo, 2026-11-04: "giving the users a better way to, like, see what's actually happening and to,
// like, visualize what's happening ... as a viewer or whatever ... some people just want to edit it
// a bit, right? Like, we can just expose that".
import { useEffect, useRef, useState } from "react";
import { PICKER_LAST_KNOWN } from "../../../lastKnown";
import { useEscapeCloses } from "../../../ui/escapeDismiss";
import { Button } from "../../../ui/Button";
import { Tabs, TabsList, TabsTrigger } from "../../../ui/Tabs";
import "../../../ui/controls.css";
import { Spinner } from "../conversation/icons";
import { type StringKey, useT } from "../i18n";
import { Icon } from "../icons/Icon";
import {
  type GroupId,
  grouped,
  guidanceDraft,
  type Inventory,
  type InventoryPart,
  parseInventory,
} from "./contextInventory";
import "./context.css";

/// `partId`: a preset prompt's id (`Inventory.prompts`), none for cmux's guidance. `text: null`
/// removes the saved replacement, so new chats get the default again. A `project` edit is for the
/// chat's own folder: acpmux takes its cwd, and the relay passes none from the page.
export type ContextOverride = { scope: "user" | "project"; text: string | null; partId?: string };

/// list: rows fold open to their text (ships). document: every text open, one page to read.
/// split: rows on the left, the picked row's text on the right.
export type ContextLayout = "list" | "document" | "split";

const GROUP_TITLE: Record<GroupId, StringKey> = {
  cmux: "contextScreen.groupCmux",
  harness: "contextScreen.groupHarness",
  memory: "contextScreen.groupMemory",
  mcp: "contextScreen.groupMcp",
  skill: "contextScreen.groupSkills",
};

type Load = { kind: "loading" } | { kind: "failed"; reason: string } | { kind: "ready"; inventory: Inventory };

/// The last inventory each chat's reader answered, by the reader (App's `loadContext` stays the same
/// function for one chat): a screen opened again draws it at once and reads again behind it.
const lastInventory = new WeakMap<() => Promise<unknown>, Inventory>();

function lastKnown(load: () => Promise<unknown>): Load {
  const inventory = PICKER_LAST_KNOWN ? lastInventory.get(load) : undefined;
  return inventory ? { kind: "ready", inventory } : { kind: "loading" };
}

export function ContextScreen({
  load,
  save,
  onClose,
  layout = "list",
}: {
  /// Reads the chat's inventory (`_acpmux/context`).
  load(): Promise<unknown>;
  /// Saves one replacement and answers with the inventory after it (`_acpmux/context_override`);
  /// unset where the pane may not edit (a remote chat), so the editor reads only.
  save?(change: ContextOverride): Promise<unknown>;
  onClose(): void;
  layout?: ContextLayout;
}) {
  const t = useT();
  const [state, setState] = useState<Load>(() => lastKnown(load));
  useEscapeCloses(true, onClose, "textarea");
  // acpmux pushes no change for the inventory; a saved edit answers with the inventory after it.
  // mount-read: the screen reads the chat's inventory once each time it opens.
  useEffect(() => {
    let live = true;
    // A last-known inventory stays on screen until this read answers; a failed read keeps it.
    const shown = PICKER_LAST_KNOWN ? lastInventory.get(load) : undefined;
    if (shown) setState({ kind: "ready", inventory: shown });
    load().then(
      (value) => {
        if (!live) return;
        const inventory = parseInventory(value);
        if (inventory) lastInventory.set(load, inventory);
        if (inventory) setState({ kind: "ready", inventory });
        else if (!shown) setState({ kind: "failed", reason: "" });
      },
      (error: unknown) => {
        if (live && !shown)
          setState({ kind: "failed", reason: error instanceof Error ? error.message : String(error) });
      },
    );
    return () => {
      live = false;
    };
  }, [load]);
  return (
    <section className="acpmux-context-screen" data-layout={layout} aria-label={t("contextScreen.title")}>
      <header className="acpmux-context-screen-head">
        <div className="acpmux-context-screen-heading">
          <h2>{t("contextScreen.title")}</h2>
          <p>{t("contextScreen.subtitle")}</p>
        </div>
        <button
          type="button"
          className="acpmux-context-screen-close"
          aria-label={t("contextScreen.close")}
          onClick={onClose}
        >
          <Icon name="action.close" size={14} />
        </button>
      </header>
      {state.kind === "loading" ? (
        <p className="acpmux-context-screen-note" data-context-state="loading">
          <Spinner size={12} loading /> {t("contextScreen.loading")}
        </p>
      ) : state.kind === "failed" ? (
        <p className="acpmux-context-screen-note" data-context-state="failed">
          {state.reason ? t("contextScreen.failedBecause", { reason: state.reason }) : t("contextScreen.failed")}
        </p>
      ) : (
        <ContextBody
          inventory={state.inventory}
          layout={layout}
          {...(save && state.inventory.canEdit
            ? {
                save: async (change: ContextOverride) => {
                  const next = parseInventory(await save(change));
                  if (next) lastInventory.set(load, next);
                  if (next) setState({ kind: "ready", inventory: next });
                },
              }
            : {})}
        />
      )}
    </section>
  );
}

function ContextBody({
  inventory,
  layout,
  save,
}: {
  inventory: Inventory;
  layout: ContextLayout;
  save?(change: ContextOverride): Promise<void>;
}) {
  const t = useT();
  const tokens = new Intl.NumberFormat(undefined, { notation: "compact", maximumFractionDigits: 1 });
  const groups = grouped(inventory);
  const firstText = inventory.parts.find((part) => part.text !== undefined)?.id;
  const [picked, setPicked] = useState<string | undefined>(firstText);
  const [open, setOpen] = useState<ReadonlySet<string>>(new Set());
  const toggle = (id: string) =>
    setOpen((current) => {
      const next = new Set(current);
      if (!next.delete(id)) next.add(id);
      return next;
    });
  const used = inventory.providerTotalTokens ?? inventory.totalTokens;
  const shown = (id: string) => (layout === "document" ? true : layout === "split" ? false : open.has(id));
  const pickedPart = inventory.parts.find((part) => part.id === picked);
  return (
    <>
      <p className="acpmux-context-screen-summary" data-context-summary>
        <span>
          {inventory.maxTokens
            ? t("contextScreen.total", { used: tokens.format(used), max: tokens.format(inventory.maxTokens) })
            : t("contextScreen.totalNoMax", { used: tokens.format(used) })}
        </span>
        <span className="acpmux-context-screen-muted">
          {t("contextScreen.cmuxAdds", { tokens: tokens.format(inventory.cmuxTokens) })}
        </span>
      </p>
      <div className="acpmux-context-screen-parts">
        <div className="acpmux-context-screen-groups">
          {groups.map((group) => (
            <section key={group.id} className="acpmux-context-group" data-context-group={group.id}>
              <h3>{t(GROUP_TITLE[group.id])}</h3>
              <ul>
                {group.parts.map((part) => (
                  <PartRow
                    key={part.id}
                    part={part}
                    tokens={tokens}
                    open={shown(part.id)}
                    picked={layout === "split" && picked === part.id}
                    onPick={
                      part.text === undefined
                        ? undefined
                        : () => (layout === "split" ? setPicked(part.id) : toggle(part.id))
                    }
                  />
                ))}
              </ul>
            </section>
          ))}
        </div>
        {layout === "split" && (
          <div className="acpmux-context-screen-detail" data-context-detail>
            {pickedPart?.text !== undefined ? (
              <>
                <h3>{pickedPart.label}</h3>
                <PartText text={pickedPart.text} />
              </>
            ) : (
              <p className="acpmux-context-screen-muted">{t("contextScreen.pickPart")}</p>
            )}
          </div>
        )}
      </div>
      {inventory.defaultText !== undefined ? (
        <GuidanceEditor inventory={inventory} {...(save ? { save } : {})} />
      ) : (
        <p className="acpmux-context-screen-muted">{t("contextScreen.readOnly")}</p>
      )}
      {Object.entries(inventory.prompts).map(([id, prompt]) => (
        <PromptEditor key={id} id={id} prompt={prompt} {...(save ? { save } : {})} />
      ))}
    </>
  );
}

function PartRow({
  part,
  tokens,
  open,
  picked,
  onPick,
}: {
  part: InventoryPart;
  tokens: Intl.NumberFormat;
  open: boolean;
  picked: boolean;
  onPick?: () => void;
}) {
  const t = useT();
  const count =
    part.measurement === "unavailable"
      ? t("contextScreen.notReported")
      : part.measurement === "estimated"
        ? t("contextScreen.estimated", { tokens: tokens.format(part.tokens) })
        : tokens.format(part.tokens);
  const head = (
    <>
      {onPick ? (
        <Icon name={open ? "disclosure.expanded" : "disclosure.collapsed"} size={12} />
      ) : (
        <span className="acpmux-context-row-spacer" aria-hidden="true" />
      )}
      <span className="acpmux-context-row-label">{part.label}</span>
      {!part.included && <span className="acpmux-context-row-off">{t("contextScreen.off")}</span>}
      <span className="acpmux-context-row-count">{count}</span>
    </>
  );
  return (
    <li className="acpmux-context-row" data-context-part={part.id} data-picked={picked || undefined}>
      {onPick ? (
        <button type="button" className="acpmux-context-row-head" aria-expanded={open} onClick={onPick}>
          {head}
        </button>
      ) : (
        <div className="acpmux-context-row-head">{head}</div>
      )}
      {open && part.text !== undefined && <PartText text={part.text} />}
    </li>
  );
}

function PartText({ text }: { text: string }) {
  const t = useT();
  return text ? (
    <pre className="acpmux-context-text">{text}</pre>
  ) : (
    <p className="acpmux-context-screen-muted">{t("contextScreen.empty")}</p>
  );
}

/// The guidance cmux sends a new chat once, with its first message. `user` replaces it for every
/// chat; `project` for this folder's. Empty text turns it off; Use Default removes the replacement.
function GuidanceEditor({ inventory, save }: { inventory: Inventory; save?(change: ContextOverride): Promise<void> }) {
  const [scope, setScope] = useState<"user" | "project">(inventory.project !== undefined ? "project" : "user");
  const saved = scope === "project" ? inventory.project : inventory.user;
  return (
    <TextEditor
      id="guidance"
      title="contextScreen.editTitle"
      initial={guidanceDraft(inventory, scope)}
      saved={saved !== undefined}
      scope={scope}
      onScope={setScope}
      {...(save ? { save: (text: string | null) => save({ scope, text }) } : {})}
    />
  );
}

function PromptEditor({
  id,
  prompt,
  save,
}: {
  id: string;
  prompt: Inventory["prompts"][string];
  save?(change: ContextOverride): Promise<void>;
}) {
  const [scope, setScope] = useState<"user" | "project">(prompt.project !== undefined ? "project" : "user");
  const saved = scope === "project" ? prompt.project : prompt.user;
  return (
    <TextEditor
      id={id}
      label={prompt.label}
      initial={saved ?? (scope === "project" ? prompt.user : undefined) ?? prompt.defaultText}
      saved={saved !== undefined}
      scope={scope}
      onScope={setScope}
      {...(save ? { save: (text: string | null) => save({ scope, text, partId: id }) } : {})}
    />
  );
}

function TextEditor({
  id,
  title,
  label,
  initial,
  saved,
  scope,
  onScope,
  save,
}: {
  id: string;
  title?: StringKey;
  label?: string;
  initial: string;
  /// A replacement is saved in this scope, so Use Default has something to remove.
  saved: boolean;
  scope: "user" | "project";
  onScope(scope: "user" | "project"): void;
  save?(text: string | null): Promise<void>;
}) {
  const t = useT();
  const [draft, setDraft] = useState(initial);
  const [status, setStatus] = useState<{ kind: "idle" | "saving" | "saved" } | { kind: "failed"; reason: string }>({
    kind: "idle",
  });
  // A scope switch or a save answer brings new text; what the person typed is kept until then.
  // A refresh behind a last-known inventory brings new text too, but never over an edited draft.
  const shown = useRef({ initial, scope, saving: false });
  useEffect(() => {
    const last = shown.current;
    shown.current = { initial, scope, saving: false };
    if (last.initial === initial) return;
    setDraft((current) => (last.scope !== scope || last.saving || current === last.initial ? initial : current));
  }, [initial, scope]);
  const run = (text: string | null) => {
    if (!save) return;
    shown.current.saving = true;
    setStatus({ kind: "saving" });
    save(text).then(
      () => setStatus({ kind: "saved" }),
      (error: unknown) => setStatus({ kind: "failed", reason: error instanceof Error ? error.message : String(error) }),
    );
  };
  const heading = label ?? (title ? t(title) : id);
  return (
    <section className="acpmux-context-editor" data-context-editor={id}>
      <div className="acpmux-context-editor-head">
        <h3>{heading}</h3>
        <Tabs
          variant="segmented"
          value={scope}
          onValueChange={(value) => onScope(value === "project" ? "project" : "user")}
        >
          <TabsList aria-label={heading}>
            <TabsTrigger value="user">{t("contextScreen.scopeUser")}</TabsTrigger>
            <TabsTrigger value="project">{t("contextScreen.scopeProject")}</TabsTrigger>
          </TabsList>
        </Tabs>
      </div>
      <p className="acpmux-context-screen-muted">{t("contextScreen.editHint")}</p>
      <textarea
        className="acpmux-context-editor-text"
        aria-label={heading}
        value={draft}
        // Read-only while a save is in flight: its answer brings the saved text, which replaces the draft.
        readOnly={!save || status.kind === "saving"}
        spellCheck={false}
        rows={Math.min(16, Math.max(4, draft.split("\n").length + 1))}
        onChange={(event) => {
          setDraft(event.target.value);
          if (status.kind !== "idle") setStatus({ kind: "idle" });
        }}
      />
      {save ? (
        <div className="acpmux-context-editor-actions">
          <span className="acpmux-context-screen-muted" data-context-save={status.kind}>
            {status.kind === "saved"
              ? t("contextScreen.saved")
              : status.kind === "failed"
                ? t("contextScreen.saveFailedBecause", { reason: status.reason })
                : ""}
          </span>
          <Button size="sm" variant="ghost" disabled={!saved || status.kind === "saving"} onClick={() => run(null)}>
            {t("contextScreen.useDefault")}
          </Button>
          <Button
            size="sm"
            variant="solid"
            disabled={status.kind === "saving" || (draft === initial && saved)}
            onClick={() => run(draft)}
          >
            {t("contextScreen.save")}
          </Button>
        </div>
      ) : (
        <p className="acpmux-context-screen-muted">{t("contextScreen.readOnly")}</p>
      )}
    </section>
  );
}
