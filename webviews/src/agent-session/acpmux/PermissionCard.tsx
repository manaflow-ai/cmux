import React, { useEffect, useLayoutEffect, useMemo, useRef, useState } from "react";
import { KeyHint } from "../../ui/KeyHint";
import { Menu, MenuButton, MenuItem, MenuPopup } from "../../ui/Menu";
import { playResize } from "./conversation/fold";
import { ChevronDown } from "./conversation/icons";
import { Markdown } from "./conversation/Markdown";
import { toolIcon } from "./conversation/toolRowModel";
import { useT } from "./i18n";
import type { AcpmuxPermission } from "./model";
import { postNative } from "./native";
import { NativeError } from "./nativeError";
import { knownRefusalText } from "./transportErrors";
import "./permissions/externalAccess.css";
import { takePermissionFocus } from "./permissions/focusRequest";
import { compareHarnesses, harnessName, type PlanBuildElsewhere } from "./permissions/planBuild";
import { ProposedEdits } from "./permissions/ProposedEdits";
import { HoldRing, holdButtonProps, holdTitle, useHoldToApprove, type HoldControl } from "./permissions/HoldButton";
import { holdApplies, holdSettings } from "./permissions/holdToApprove";
import type { HoldScope } from "./permissions/holdToApprove.experiment";
import {
  alwaysAllowScope,
  commandPreview,
  optionButtonLabel,
  permissionAnswers,
  permissionCommand,
  permissionDetail,
  permissionKeyAction,
  permissionOptionKind,
  permissionScopeText,
  permissionTitle,
  type PermissionKeyAction,
} from "./permissions/prompt";
import { SHORTCUT_ACTIONS, useShortcut } from "./shortcuts";
import { focusRoute } from "../../ui/focusRoute";
import { cx } from "../../ui/cx";
import { Surface } from "../../ui/surface/Surface";

type PermissionOption = AcpmuxPermission["options"][number];

/** The single card frame used by legacy ACP asks and grouped tool permissions. */
type PermissionCardFrameProps = {
  title?: string;
  ariaLabel?: string;
  leading?: React.ReactNode;
  children: React.ReactNode;
  className?: string;
  /// The card takes focus from code (``permissionFocus``), so its keys answer.
  focusable?: boolean;
};

export const PermissionCardFrame = React.forwardRef<HTMLFieldSetElement, PermissionCardFrameProps>(
  function PermissionCardFrame({ title, ariaLabel, leading, children, className, focusable }, ref) {
    const titleId = React.useId();
    // The ask role's shell (ui/surface): the content material, the card corner, the hairline, the
    // type and the padding are the role's, the same as every other card in the transcript. The
    // `acpmux-permission-card` class is a hook for styles.css and the tests, with no shell rules.
    return (
      <Surface
        as="fieldset"
        // oxlint-disable-next-line jsx-a11y/aria-role -- the Surface role, not an ARIA role
        role="ask"
        ref={ref}
        className={cx("acpmux-permission-card", className)}
        aria-labelledby={title ? titleId : undefined}
        aria-label={!title ? ariaLabel : undefined}
        tabIndex={focusable ? -1 : undefined}
      >
        {title && (
          <Surface.Header icon={leading} titleId={titleId} className="acpmux-permission-card-heading">
            {title}
          </Surface.Header>
        )}
        {children}
      </Surface>
    );
  },
);

/// How many asks' answers a card remembers: far more than a card shows before the snapshot moves on.
const KEPT_ANSWERS = 32;

/// A key the card itself answers (Esc, ⌘↩), drawn as a keycap in its button: `keys` as shown,
/// `aria` in `aria-keyshortcuts` form. `letter` is the answer's letter (y, a, n), drawn first.
export type CardKey = { letter?: string; keys: string[]; aria: string };

/** Shared action button so grouped and legacy cards present the same localized label and key hint.
 * Only the short label and the key: what an answer covers is the card's one scope line, never the
 * button's (Leo 2026-10-25: "the allow button ... it shouldn't be encompassing so much"). With
 * `cardKey` the button shows that key as a keycap, as Claude desktop's "Deny Esc" and "Allow ⌘↩",
 * and still answers `shortcut`, which it lists after the card key. */
export function PermissionActionButton({
  label,
  shortcut,
  cardKey,
  kind,
  hold,
  holdDescription,
  ...props
}: React.ButtonHTMLAttributes<HTMLButtonElement> & {
  label: string;
  shortcut?: string;
  cardKey?: CardKey;
  /// On the ask card's actions row: the one primary, or a quiet secondary (ui/Button's solid and subtle).
  /// Without it (the Home inbox's own answer buttons) the button keeps its caller's class styling.
  kind?: "primary" | "secondary";
  /// Hold to approve (permissions/HoldButton.tsx): the button answers after a held press, with a
  /// ring at its leading edge; its click answers nothing. Absent, the button is today's.
  hold?: HoldControl;
  /// The hold's "Hold to allow", its tooltip and accessible description.
  holdDescription?: string;
}) {
  const { className, ...buttonProps } = props;
  const content = (
    <>
      {hold && <HoldRing hold={hold} />}
      <span className="acpmux-permission-action-label">{label}</span>
      {cardKey ? (
        <Surface.Keys className="acpmux-permission-keys">
          {cardKey.letter && <KeyHint keys={cardKey.letter.toUpperCase()} aria-hidden="true" />}
          {cardKey.letter && (cardKey.keys.length > 0 || shortcut) && (
            <span className="acpmux-permission-keys-or" aria-hidden="true">
              /
            </span>
          )}
          {cardKey.keys.length > 0 ? (
            <KeyHint keys={cardKey.keys.join("")} aria-hidden="true" />
          ) : (
            shortcut && <KeyHint keys={shortcut} aria-hidden="true" />
          )}
        </Surface.Keys>
      ) : (
        shortcut && <KeyHint keys={shortcut} aria-hidden="true" />
      )}
    </>
  );
  const common = {
    ...(hold ? holdButtonProps(hold, holdDescription ?? "") : {}),
    title: hold ? holdTitle(buttonProps.title, holdDescription ?? "") : buttonProps.title,
    "aria-label": label,
    "aria-keyshortcuts": [cardKey?.aria, shortcut].filter(Boolean).join(" ") || undefined,
  };
  if (kind)
    return (
      <Surface.Action {...buttonProps} {...common} kind={kind} className={className}>
        {content}
      </Surface.Action>
    );
  return (
    // The Home inbox's answer buttons keep their own row styling until that surface migrates.
    <button {...buttonProps} {...common} className={className} type="button">
      {content}
    </button>
  );
}

// One keycap per key, as Claude desktop draws "Esc" and "⌘ ↩", after the answer's letter
// (permissions/prompt.ts PERMISSION_LETTERS): "Y / ⌘ ↩", "A / ⌥⌘2", "N / Esc".
const DENY_KEY: CardKey = { letter: "n", keys: ["Esc"], aria: "n Escape" };
const ALLOW_KEY: CardKey = { letter: "y", keys: ["⌘", "↩"], aria: "y Meta+Enter" };
const ALWAYS_KEY: CardKey = { letter: "a", keys: [], aria: "a" };

/// Where Approve plan builds: here (the ask's own allow) or one of the plan's other builds.
export type PlanTarget = "here" | PlanBuildElsewhere;

/// Approve plan joined to its build menu, one split button: the primary half approves here with its
/// ⌘↩ as before; the chevron half opens a menu of where else the plan can be built: Build here (the same
/// answer), Build in a new worktree (a sub-session on its own branch, so this chat stays free), and
/// Build on two agents and compare (the chat's harness and another, each in its own worktree).
export function PlanBuildSplit({
  harness,
  cardKey,
  onHere,
  onBuild,
  holdFocus,
  onPick,
  children,
}: {
  harness?: string;
  cardKey?: CardKey;
  /// Under hold to approve, no item answers itself: each picks where the held Approve plan builds
  /// (`onPick`) and the menu closes onto Approve plan, where a held Return or press approves
  /// (HoldButton.tsx).
  holdFocus?: React.RefObject<HTMLButtonElement | null>;
  onPick?(target: PlanTarget): void;
  onHere(): void;
  onBuild(target: PlanBuildElsewhere): void;
  /// The Approve plan button.
  children: React.ReactNode;
}) {
  const t = useT();
  const [first, second] = compareHarnesses(harness);
  return (
    <span className="acpmux-plan-build-split">
      {children}
      <Menu>
        <MenuButton
          variant="solid"
          size="md"
          className="acpmux-permission-primary acpmux-plan-build-chevron"
          label={t("permission.plan.buildMenu")}
          title={t("permission.plan.buildMenu")}
          data-menu="plan-build"
        >
          <ChevronDown size={14} />
        </MenuButton>
        <MenuPopup
          label={t("permission.plan.buildMenu")}
          align="end"
          className="acpmux-quick-menu acpmux-plan-build-menu"
          finalFocus={holdFocus}
        >
          <MenuItem
            data-value="here"
            shortcut={cardKey ? cardKey.keys.join("") : undefined}
            onSelect={holdFocus ? () => onPick?.("here") : onHere}
          >
            {t("permission.plan.buildHere")}
          </MenuItem>
          <MenuItem data-value="worktree" onSelect={() => (holdFocus ? onPick?.("worktree") : onBuild("worktree"))}>
            {t("permission.plan.buildWorktree")}
          </MenuItem>
          <MenuItem data-value="compare" onSelect={() => (holdFocus ? onPick?.("compare") : onBuild("compare"))}>
            <span className="acpmux-plan-build-item">
              <span>{t("permission.plan.buildCompare")}</span>
              <span className="acpmux-plan-build-detail">
                {t("permission.plan.buildCompareDetail", { first: harnessName(first), second: harnessName(second) })}
              </span>
            </span>
          </MenuItem>
        </MenuPopup>
      </Menu>
    </span>
  );
}

/// A permission ask as Claude desktop draws its "Allow Claude to use …?" card (Leo, 2026-11-05: "The
/// whole, like, allow whatever to use, allow for this session, or deny. And then it shows the
/// hotkeys."): a glass card whose head, a shade lighter than the rest, holds what the call does, with
/// the tool's glyph, and a muted reason under it; then the details, the command clamped to its first line ("Show full
/// command" opens all of it) and what an answer covers (the folder or app, the Always allow rule) as
/// one muted line, cut with an ellipsis and whole on hover; then the answers, short buttons sized to
/// their labels: any other option the agent offered and Deny with its Esc keycap at the leading
/// edge, Always allow and the filled Allow once with its ⌘ ↩ keycaps at the trailing edge, each shown only when the
/// agent offered that kind (permissions/prompt.ts). Deny opens a field for what the agent should do instead, sent with the
/// deny through `onDenyWithFeedback`. Keys y, a and n (drawn on the answers), 1, 2 and 3, Return and ⌘↩
/// (Allow once) and Esc (Deny, or close the field) answer while this card is the prompt and nothing
/// else has the keyboard; an empty composer gives it the letters, Return and Esc. In a chat
/// running its highest mode (`fullAccessMode`), an ask still here is one the mode does not answer
/// (acpmux hub/permissions.rs `full_access_allow`: an ask Claude Code marks as needing the person,
/// one with no one-time allow), and one line under the title says so: Allow once lets it through
/// this time only (Leo, 2026-11-04: "a temporary one-time sort of ask for, like if for whatever
/// reason there's the bypass permissions, it doesn't bypass every single thing").
/// A plan approval (Claude Code's ExitPlanMode, Grok's and Cursor's plan modes) shows its plan as
/// Markdown, the way the transcript renders a reply, with Approve plan and Keep planning, whose field
/// says what to change (Leo, 2026-11-05: "i like these plans too... i want us to be able to render it
/// in ours").
export function PermissionCard({
  permission,
  onAnswer,
  onDenyWithFeedback,
  harness,
  focusComposer,
  shortcuts = true,
  waiting = 0,
  alwaysAtSource = false,
  fullAccessMode,
  onDraft,
  onBuildPlan,
  onApproveEditedPlan,
  onForkFirst,
  hold: holdOverride,
}: {
  permission: AcpmuxPermission;
  /// Sends the answer. A promise that rejects means acpmux refused it (already answered elsewhere,
  /// withdrawn, a policy change): the card says so and its keys answer again.
  onAnswer(optionId: string): unknown;
  /// Denies with `optionId`, then gives the agent `text` (empty: only denies). False when acpmux
  /// refused the deny: the field stays, with what was typed.
  onDenyWithFeedback?(optionId: string, text: string): Promise<boolean>;
  harness?: string;
  focusComposer?: () => void;
  /// False while another ask takes the permission shortcuts (a waiting permission group,
  /// permissionKeys.ts `cardTakesShortcuts`): the card then neither answers its keys nor shows them.
  shortcuts?: boolean;
  /// More asks waiting behind this one, answered after it.
  waiting?: number;
  /// A peer's chat: the peer takes only a one-time Allow and a Deny from this Mac, never a lasting
  /// grant (acpmux mac_approvers.rs), so Always allow stays on the card, disabled, saying why,
  /// instead of failing after the click.
  alwaysAtSource?: boolean;
  /// The chat's mode label while it runs its highest mode (Bypass permissions, Full access).
  fullAccessMode?: string;
  /// Told when the deny's instructions open (true) and close, sent or not (false; also on unmount),
  /// so the pane keeps this card up while something is typed on it (permissionKeys.ts `heldOnCard`).
  onDraft?(open: boolean): void;
  /// A plan approval's other builds (`_acpmux/plan/build`): in a new worktree, or on two harnesses
  /// to compare. With it, Approve plan is a split button whose menu offers them; acpmux answers the
  /// ask itself, and a promise that rejects is a refusal the card shows, as for `onAnswer`.
  onBuildPlan?(target: PlanBuildElsewhere, plan?: string): Promise<unknown>;
  /// Approves the plan as the person edited it on the card (Leo's gap doc item 6: "an edit step
  /// before Approve"). With it, the card offers Edit plan; an Approve after an edit sends the edit
  /// here instead of the plain allow, and a build elsewhere starts from it.
  onApproveEditedPlan?(plan: string): Promise<unknown>;
  /// "Fork first" on a risky step of a Cloud chat (`permission.forkOffer`, acpmux fork_risky.rs):
  /// the app forks the machine, keeps the copy as a checkpoint, then allows `optionId`. A promise
  /// that rejects is a refusal the card shows (the fork failed: the step still waits).
  onForkFirst?(optionId: string): unknown;
  /// Hold to approve's scope and hold time, in place of the experiments' (holdToApprove.experiment.ts);
  /// `reduced` draws the stepped ring. The pane passes none; the gallery and tests do.
  hold?: { scope: HoldScope; durationMs: number; reduced?: boolean };
}) {
  const t = useT();
  const command = permissionCommand(permission);
  /// "Fork first" shows only where the pane can carry it out, and only while the ask waits.
  const forkOffer = onForkFirst && permission.pending ? permission.forkOffer : undefined;
  const preview = useMemo(() => commandPreview(command), [command]);
  const external = permission.externalAccess;
  const [settingsError, setSettingsError] = useState<{ id: string; message: string }>();
  const title = external ? t("permission.external.title", { target: external.target }) : permissionTitle(permission, t);
  const detail = external ? t("permission.external.detail") : permissionDetail(permission);
  const {
    allowOnce,
    allowAlways,
    deny: denyOption,
    others,
  } = useMemo(() => permissionAnswers(permission.options), [permission.options]);
  const alwaysScope = allowAlways && alwaysAllowScope(permission, allowAlways);
  const scopeText = external ? undefined : permissionScopeText(permission, t);
  /// The one scope line: the target the ask covers, then the Always allow rule.
  const scopeLine = [scopeText, alwaysScope].filter(Boolean).join(" · ") || undefined;
  const targetId = React.useId();
  const ruleId = React.useId();
  const otherId = React.useId();
  const allowAlwaysLabel =
    allowAlways &&
    (permissionOptionKind(allowAlways) === "allow_chat" ? t("permission.allowChat") : t("permission.alwaysAllow"));
  const otherLabels = useMemo(() => {
    const taken = new Set<string>([t("permission.allowOnce"), t("permission.deny")]);
    if (allowAlwaysLabel) taken.add(allowAlwaysLabel);
    return others.map((option) => {
      const label = optionButtonLabel(option, t, taken);
      taken.add(label);
      return label;
    });
  }, [others, t, allowAlwaysLabel]);
  const feedback = Boolean(!external && onDenyWithFeedback && permission.pending && denyOption);
  const plan = permission.plan;
  const claude = harness === "claude" || harness?.startsWith("claude-");
  const feedbackPlaceholder = plan
    ? t("permission.plan.feedbackPlaceholder")
    : claude
      ? t("permission.claude.feedbackPlaceholder")
      : t("permission.feedbackPlaceholder");
  /// The ask whose full command is open: a new ask opens collapsed.
  const [expanded, setExpanded] = useState<string>();
  const showFull = expanded === permission.permissionId;
  const fullId = React.useId();
  // The command's box grows to the full command (and back) on the fold's clock (fold.ts `playResize`)
  // from the height it was drawn at before the toggle, so the stack's top and the transcript's rows
  // over it travel together instead of the card growing in one frame.
  const commandRef = useRef<HTMLDivElement>(null);
  const commandFrom = useRef<number | undefined>(undefined);
  useLayoutEffect(() => {
    const node = commandRef.current;
    const from = commandFrom.current;
    commandFrom.current = undefined;
    if (node && from !== undefined) playResize(node, from);
  }, [showFull]);
  // A one-line command longer than the two lines the preview holds is cut off: measured, so "Show
  // full command" is offered whenever the preview does not show all of it.
  const previewRef = useRef<HTMLElement>(null);
  const [clamped, setClamped] = useState(false);
  useLayoutEffect(() => {
    const element = previewRef.current;
    if (!element) return;
    const measure = () => setClamped(element.scrollHeight > element.clientHeight + 1);
    measure();
    if (typeof ResizeObserver === "undefined") return;
    const observer = new ResizeObserver(measure);
    observer.observe(element);
    return () => observer.disconnect();
  }, [preview.line, showFull]);
  /// The field's text while it is open, for the ask it opened on; `sending` while its deny goes.
  const [draft, setDraft] = useState<{ permissionId: string; text: string; sending?: boolean }>();
  const writing = draft?.permissionId === permission.permissionId ? draft : undefined;
  const field = useRef<HTMLTextAreaElement>(null);
  // Opening it again (Deny, its key, the deny shortcut) keeps what is typed.
  const openFeedback = () => {
    if (!writing) setDraft({ permissionId: permission.permissionId, text: "" });
  };
  const fieldOpen = writing !== undefined;
  const draftListener = useRef(onDraft);
  draftListener.current = onDraft;
  useEffect(() => {
    if (!fieldOpen) return;
    draftListener.current?.(true);
    return () => draftListener.current?.(false);
  }, [fieldOpen]);
  // Opened by the person's own click or key, so the field takes the keyboard.
  useEffect(() => {
    if (fieldOpen) field.current?.focus();
  }, [fieldOpen]);
  const group = useRef<HTMLFieldSetElement>(null);
  /// Set when the field closes without sending: the keyboard goes back to Deny.
  const backToOpener = useRef(false);
  useEffect(() => {
    if (fieldOpen || !backToOpener.current) return;
    backToOpener.current = false;
    group.current?.querySelector<HTMLElement>("[data-feedback-opener]")?.focus();
  }, [fieldOpen]);
  const closeFeedback = () => {
    if (writing?.sending) return;
    backToOpener.current = true;
    setDraft(undefined);
  };
  // Each ask's answer, out or taken, by the attempt that sent it: held keys repeat, a key and a
  // click can both land before the snapshot clears the ask, and the card can show an ask again
  // (another before it, then it) while its answer is still out, so each ask is answered once. A
  // refusal from acpmux (the promise `onAnswer` returns rejects) frees it again: that answer was
  // never heard. A taken answer is kept: the card can show that ask again before the snapshot
  // drops it. Only the newest taken answers are kept, so a long chat's card stays small; an answer
  // still out is kept until it settles, so its reply always finds it.
  const answers = useRef(new Map<string, { attempt: number; out: boolean }>());
  const attempts = useRef(0);
  /// The ask shown now, read when an answer settles: only its own outcome changes what the card shows.
  const shown = useRef(permission.permissionId);
  shown.current = permission.permissionId;
  /// The plan as the person is editing it, for the ask it was opened on (Edit plan).
  const [planEdit, setPlanEdit] = useState<{ permissionId: string; text: string }>();
  const editingPlan = Boolean(plan && onApproveEditedPlan && planEdit?.permissionId === permission.permissionId);
  /// The edit Approve sends: only a changed, non-empty one; else the plan goes as the agent wrote it.
  const editedText = (() => {
    if (!editingPlan || !planEdit) return undefined;
    const text = planEdit.text.trim();
    return text && text !== plan ? text : undefined;
  })();
  /// The ask whose last answer acpmux refused: the card says so until the next answer.
  const [refused, setRefused] = useState<string>();
  /// A refused plan build's line, in plain words, shown in place of the answer's refusal.
  const [refusedWhy, setRefusedWhy] = useState<string>();
  type Sent = { permissionId: string; attempt: number };
  /// Starts one answer for the ask shown now; undefined while one is out or taken for it.
  const begin = (): Sent | undefined => {
    const permissionId = permission.permissionId;
    if (answers.current.has(permissionId)) return undefined;
    const attempt = ++attempts.current;
    answers.current.set(permissionId, { attempt, out: true });
    setRefused(undefined);
    setRefusedWhy(undefined);
    return { permissionId, attempt };
  };
  /// Whether `sent` is still its ask's answer: no newer attempt for that ask has replaced it.
  const owns = (sent: Sent) => answers.current.get(sent.permissionId)?.attempt === sent.attempt;
  /// acpmux took the answer: it stays taken, among the KEPT_ANSWERS last taken; the ask shown is
  /// never forgotten.
  const taken = (sent: Sent) => {
    if (!owns(sent)) return;
    // Moved to the end: the map's order is the order answers were taken in.
    answers.current.delete(sent.permissionId);
    answers.current.set(sent.permissionId, { attempt: sent.attempt, out: false });
    let settled = 0;
    for (const answer of answers.current.values()) if (!answer.out) settled += 1;
    for (const [id, answer] of answers.current) {
      if (settled <= KEPT_ANSWERS) break;
      if (answer.out || id === shown.current) continue;
      answers.current.delete(id);
      settled -= 1;
    }
  };
  /// The ask's answer was refused: its keys and buttons answer it again, and the card says so.
  const refuse = (sent: Sent, why?: string) => {
    if (!owns(sent)) return;
    answers.current.delete(sent.permissionId);
    if (shown.current !== sent.permissionId) return;
    setRefused(sent.permissionId);
    setRefusedWhy(why);
  };
  // After an answer the keyboard goes back to the composer, so a stray key never answers the next
  // ask in line.
  const answer = (option: PermissionOption, forkFirst = false) => {
    const sent = begin();
    if (!sent) return;
    let reply: unknown;
    try {
      // Approve plan after an edit: the edited plan goes with the approval.
      reply =
        forkFirst && onForkFirst
          ? onForkFirst(option.id)
          : option === allowOnce && editedText !== undefined && onApproveEditedPlan
            ? onApproveEditedPlan(editedText)
            : onAnswer(option.id);
    } catch (error) {
      reply = Promise.reject(error);
    }
    focusComposer?.();
    // A refusal is never silent, and never leaves the ask unanswerable while it still waits.
    Promise.resolve(reply).then(
      () => taken(sent),
      () => refuse(sent),
    );
  };
  const answerByKey = answer;
  // Hold to approve (permissions/HoldButton.tsx, off unless its experiment is on): an allow of an
  // ask the scope covers answers after a held press or key, never a click. Deny and the other
  // answers never hold. The settings are read once per card, as the experiments' other readers do.
  const [experimentHold] = useState(holdSettings);
  const holdConfig = holdOverride ?? experimentHold;
  const holds = permission.pending && holdApplies(holdConfig.scope, [{ kind: permission.kind, command }]);
  const holdDescription = t("permission.holdToAllow");
  // Under hold, a plan's build menu answers nothing: it picks where the held Approve plan builds,
  // for this ask only (a new ask starts at here).
  const [picked, setPicked] = useState<{ permissionId: string; target: PlanTarget }>();
  const planTarget: PlanTarget =
    plan && onBuildPlan && picked?.permissionId === permission.permissionId ? picked.target : "here";
  // Each hold is bound to the ask, the answer and the plan target it was pressed on: a press on one
  // ask never approves the ask that replaces it, nor builds where it was not pressed to (HoldButton.tsx
  // `identity`).
  const holdOnce = useHoldToApprove({
    enabled: holds && !!allowOnce && !writing,
    identity: `${permission.permissionId}\u0000${allowOnce?.id ?? ""}\u0000${planTarget}`,
    durationMs: holdConfig.durationMs,
    reducedOverride: holdOverride?.reduced,
    onComplete: () => {
      if (planTarget !== "here") build(planTarget);
      else if (allowOnce) answer(allowOnce);
    },
  });
  const holdAlways = useHoldToApprove({
    enabled: holds && !!allowAlways && !alwaysAtSource && !writing,
    identity: `${permission.permissionId}\u0000${allowAlways?.id ?? ""}`,
    durationMs: holdConfig.durationMs,
    reducedOverride: holdOverride?.reduced,
    onComplete: () => allowAlways && answer(allowAlways),
  });
  /// Builds the plan elsewhere: one answer for the ask, like a button's, which acpmux gives itself.
  const build = (target: PlanBuildElsewhere) => {
    if (!onBuildPlan) return;
    const sent = begin();
    if (!sent) return;
    let reply: unknown;
    try {
      reply = onBuildPlan(target, editedText);
    } catch (error) {
      reply = Promise.reject(error);
    }
    focusComposer?.();
    // A build refused before anything started (limits, a missing harness, a worktree error)
    // says why: no build card exists to say it.
    Promise.resolve(reply).then(
      () => taken(sent),
      (failure: unknown) => {
        // In plain words, with the pane's reason when it words one; acpmux's text goes to the log.
        const known = knownRefusalText(failure);
        if (!known) console.warn("agent pane: the plan was not built", failure);
        refuse(sent, known ? t("permission.plan.buildRefused", { error: known }) : t("permission.plan.buildFailed"));
      },
    );
  };
  /// Deny: the field for what to do instead when the pane can send it, else the deny itself.
  const deny = (byKey = false) => {
    // An answer already out or taken for the ask (a deny with feedback sending) is not given again.
    if (!denyOption || answers.current.has(permission.permissionId)) return;
    if (feedback) openFeedback();
    else if (byKey) answerByKey(denyOption);
    else answer(denyOption);
  };
  /// The keys' and the shortcuts' actions, read at the time of the key.
  /// `event` is the key that asked, absent for an app shortcut's page event.
  const act = useRef<(action: PermissionKeyAction, event?: KeyboardEvent) => boolean>(() => false);
  useLayoutEffect(() => {
    act.current = (action, event) => {
      if (action === "closeFeedback") {
        if (!writing || writing.sending) return false;
        closeFeedback();
        return true;
      }
      if (answers.current.has(permission.permissionId)) return false;
      if (action === "deny") {
        if (!denyOption) return false;
        deny(true);
        return true;
      }
      const option = action === "allow_once" ? allowOnce : alwaysAtSource ? undefined : allowAlways;
      if (!option) return false;
      const hold = action === "allow_once" ? holdOnce : holdAlways;
      if (hold) {
        // A held key fills the ring until it goes up; an app shortcut cannot be held, so it puts the
        // keyboard on the button, where Return or Space held answers.
        if (event) hold.holdKey(event);
        else focusRoute(hold.ref.current, "person", "an app allow shortcut under hold to approve");
        return true;
      }
      answerByKey(option);
      return true;
    };
  });
  const allowOnceShortcut = useShortcut(SHORTCUT_ACTIONS.permissionAllowOnce);
  const allowChatShortcut = useShortcut(SHORTCUT_ACTIONS.permissionAllowChat);
  const denyShortcut = useShortcut(SHORTCUT_ACTIONS.permissionDeny);
  const active = permission.pending && shortcuts;
  // The keys go to the page, not to the card: with nothing focused the card is still the prompt.
  // Capture, so a digit is taken before the composer's typing-anywhere listener (composerFocus.ts)
  // puts it in the prompt; permissionKeyAction leaves any key a field, menu or button owns.
  useEffect(() => {
    if (!active) return;
    const onKey = (event: KeyboardEvent) => {
      const action = permissionKeyAction(event, group.current, fieldOpen);
      if (!action || !act.current(action, event)) return;
      event.preventDefault();
      event.stopPropagation();
    };
    document.addEventListener("keydown", onKey, true);
    return () => document.removeEventListener("keydown", onKey, true);
  }, [active, fieldOpen]);
  // A click on the ask's notification opens the chat with the card focused (`permissionFocus`), not
  // the composer: the next 1, 2, 3, Return or Esc answers it.
  useEffect(() => {
    if (!active) return;
    const focus = () => {
      takePermissionFocus();
      focusRoute(group.current, "system", "a permission request");
    };
    // Asked just before this card mounted: the chat opened first.
    if (takePermissionFocus()) focusRoute(group.current, "system", "a permission request");
    window.addEventListener("cmux-acpmux-permissionFocus", focus);
    return () => window.removeEventListener("cmux-acpmux-permissionFocus", focus);
  }, [active]);
  // The app's permission shortcuts (⌥⌘1, ⌥⌘2, ⌥⌘3) arrive as page events.
  useEffect(() => {
    if (!active) return;
    const events = [
      ["cmux-acpmux-permissionAllowOnce", "allow_once"],
      ["cmux-acpmux-permissionAllowChat", "allow_always"],
      ["cmux-acpmux-permissionDeny", "deny"],
    ] as const;
    const handlers = events.map(([event, action]) => {
      const handler = () => void act.current(action);
      window.addEventListener(event, handler);
      return [event, handler] as const;
    });
    return () => handlers.forEach(([event, handler]) => window.removeEventListener(event, handler));
  }, [active]);
  const sendFeedback = async (text: string) => {
    if (!denyOption || !onDenyWithFeedback || writing?.sending) return;
    const sent = begin();
    if (!sent) return;
    const { permissionId } = sent;
    setDraft({ permissionId, text, sending: true });
    let denied = false;
    try {
      denied = await onDenyWithFeedback(denyOption.id, text.trim());
    } catch {
      // A throw is a refusal too: nothing says acpmux took the deny.
    }
    // The ask's draft is this attempt's while it sends: nothing else can open or send it.
    const mine = owns(sent);
    const onCard = shown.current === permissionId;
    if (denied) {
      taken(sent);
      if (mine) setDraft((draft) => (draft?.permissionId === permissionId ? undefined : draft));
      // The keyboard goes back to the composer, as a plain deny's does.
      if (mine && onCard) focusComposer?.();
      return;
    }
    // Refused (answered elsewhere, or the connection dropped): the field stays with its text.
    if (!mine) return;
    refuse(sent);
    setDraft((draft) => (draft?.permissionId === permissionId ? { permissionId, text } : draft));
    if (onCard) field.current?.focus();
  };

  const commandBlock = command && (
    <div ref={commandRef} className="acpmux-permission-command" data-expanded={showFull || undefined}>
      {showFull ? (
        <Surface.Inset as="pre" mono scroll id={fullId} className="acpmux-permission-command-full">
          <code>{command}</code>
        </Surface.Inset>
      ) : (
        <Surface.Inset mono className="acpmux-permission-command-preview">
          <code ref={previewRef}>{preview.line}</code>
        </Surface.Inset>
      )}
      {(preview.more || clamped || showFull) && (
        <button
          type="button"
          className="acpmux-permission-command-toggle"
          aria-expanded={showFull}
          aria-controls={showFull ? fullId : undefined}
          onClick={() => {
            commandFrom.current = commandRef.current?.getBoundingClientRect().height;
            setExpanded(showFull ? undefined : permission.permissionId);
          }}
        >
          {showFull ? t("permission.hideFullCommand") : t("permission.showFullCommand")}
        </button>
      )}
    </div>
  );
  const scopeBlock = !writing && scopeLine && (
    <p className="acpmux-permission-scope" data-scope-kind={permission.scope?.kind}>
      {scopeText && <span id={targetId}>{scopeText}</span>}
      {scopeText && alwaysScope && " · "}
      {alwaysScope && <span id={ruleId}>{alwaysScope}</span>}
    </p>
  );

  return (
    <PermissionCardFrame ref={group} className="acpmux-permission-ask" ariaLabel={title} focusable>
      <Surface.Header
        icon={toolIcon(permission.kind ?? (command ? "execute" : undefined))}
        className="acpmux-permission-request-head"
        titleClassName="acpmux-permission-request-label"
        titleProps={{ "data-external-access": external ? "" : undefined }}
      >
        {title}
      </Surface.Header>
      {/* Rendered only with content: an empty slot would still add the role's gap. */}
      {(waiting > 0 ||
        detail ||
        forkOffer ||
        (fullAccessMode && permission.pending) ||
        plan ||
        editedText !== undefined) && (
        <Surface.Body className="acpmux-permission-request" data-harness={harness || undefined}>
          {waiting > 0 && <p className="acpmux-permission-waiting">{t("permission.moreWaiting", { n: waiting })}</p>}
          {detail && <p className="acpmux-permission-request-description">{detail}</p>}
          {forkOffer && (
            <p className="acpmux-permission-fork-offer">
              {t("permission.forkFirstDetail", { reason: forkOffer.reason })}
            </p>
          )}
          {fullAccessMode && permission.pending && (
            <p className="acpmux-permission-one-time">
              {t(allowOnce ? "permission.fullAccessStillAsks" : "permission.fullAccessStillAsksNoOnce", {
                mode: fullAccessMode,
              })}
            </p>
          )}
          {plan &&
            (editingPlan && planEdit ? (
              // The plan as text the person edits; Approve plan sends it to the agent.
              <textarea
                className="acpmux-permission-plan acpmux-permission-plan-editor"
                aria-label={t("permission.plan.editLabel")}
                value={planEdit.text}
                rows={Math.min(16, Math.max(4, planEdit.text.split("\n").length + 1))}
                spellCheck
                autoFocus
                onChange={(event) => setPlanEdit({ permissionId: permission.permissionId, text: event.target.value })}
                onKeyDown={(event) => {
                  // Typing stays in the field; Escape closes the edit without sending it.
                  event.stopPropagation();
                  if (event.key === "Escape") {
                    event.preventDefault();
                    setPlanEdit(undefined);
                  }
                }}
              />
            ) : (
              // Fences as plain code, scrolled inside the card when long.
              <Surface.Inset
                scroll
                className="acpmux-permission-plan selectable"
                role="document"
                aria-label={t("permission.plan.label")}
              >
                <Markdown plainCode>{plan}</Markdown>
              </Surface.Inset>
            ))}
          {editedText !== undefined && <p className="acpmux-permission-plan-edited">{t("permission.plan.edited")}</p>}
        </Surface.Body>
      )}
      {(commandBlock || scopeBlock) && (
        <div className="acpmux-permission-details">
          {commandBlock}
          {scopeBlock}
        </div>
      )}
      <ProposedEdits permissionId={permission.permissionId} diffs={permission.diffs} />
      {!writing && refused === permission.permissionId && (
        <p className="acpmux-permission-refused" role="alert">
          {refusedWhy ?? t("permission.error.refused")}
        </p>
      )}
      {!writing && (
        <Surface.Actions className="acpmux-permission-buttons">
          {others.map((option, index) => {
            const label = otherLabels[index]!;
            const full = [option.name.trim(), option.description?.trim()].filter(Boolean).join(" · ");
            const more = full && full !== label ? full : undefined;
            const fullId = `${otherId}-${index}`;
            return (
              <React.Fragment key={option.id}>
                <PermissionActionButton
                  label={label}
                  title={more}
                  aria-describedby={more ? fullId : undefined}
                  kind="secondary"
                  className="acpmux-permission-other"
                  onClick={() => answer(option)}
                />
                {more && (
                  <span id={fullId} className="acpmux-permission-sr-only">
                    {more}
                  </span>
                )}
              </React.Fragment>
            );
          })}
          {plan && onApproveEditedPlan && permission.pending && (
            <PermissionActionButton
              label={editingPlan ? t("permission.plan.discardEdit") : t("permission.plan.edit")}
              className="acpmux-permission-other acpmux-permission-plan-edit"
              data-plan-editing={editingPlan ? "" : undefined}
              onClick={() =>
                setPlanEdit(editingPlan ? undefined : { permissionId: permission.permissionId, text: plan })
              }
            />
          )}
          {denyOption && (
            <PermissionActionButton
              label={
                plan ? t("permission.plan.keepPlanning") : t(external ? "permission.external.skip" : "permission.deny")
              }
              shortcut={shortcuts ? denyShortcut : undefined}
              cardKey={shortcuts ? DENY_KEY : undefined}
              aria-describedby={scopeText ? targetId : undefined}
              kind="secondary"
              className="acpmux-permission-deny"
              data-feedback-opener=""
              onClick={() => deny()}
            />
          )}
          {external && (
            <PermissionActionButton
              kind="secondary"
              label={t("permission.external.openSettings")}
              onClick={() => {
                const id = permission.permissionId;
                setSettingsError(undefined);
                void postNative("externalAccess.openSettings", { kind: external.kind }).catch((error: unknown) => {
                  const remote = error instanceof NativeError && error.code === "remote.unsupported";
                  if (!remote) console.warn("agent pane: Open Settings failed", error);
                  if (shown.current === id)
                    setSettingsError({
                      id,
                      message: remote ? t("permission.external.remote") : t("permission.external.settingsFailed"),
                    });
                });
              }}
            />
          )}
          {(allowAlways || allowOnce) && (
            // The allows keep the trailing edge together, so a narrow card wraps them as a pair.
            <Surface.Trailing className="acpmux-permission-allows">
              {forkOffer && allowOnce && (
                <PermissionActionButton
                  label={t("permission.forkFirst")}
                  title={forkOffer.machine}
                  kind="secondary"
                  className="acpmux-permission-fork-first"
                  onClick={() => answer(allowOnce, true)}
                />
              )}
              {allowAlways && allowAlwaysLabel && (
                <PermissionActionButton
                  label={allowAlwaysLabel}
                  shortcut={shortcuts && !alwaysAtSource ? allowChatShortcut : undefined}
                  cardKey={shortcuts && !alwaysAtSource ? ALWAYS_KEY : undefined}
                  title={alwaysAtSource ? t("permission.alwaysAtSource") : alwaysScope}
                  aria-describedby={
                    [scopeText && targetId, alwaysScope && ruleId].filter(Boolean).join(" ") || undefined
                  }
                  kind="secondary"
                  disabled={alwaysAtSource}
                  onClick={() => answer(allowAlways)}
                  hold={holdAlways}
                  holdDescription={holdDescription}
                />
              )}
              {allowOnce &&
                (() => {
                  const approve = (
                    <PermissionActionButton
                      label={
                        planTarget === "worktree"
                          ? t("permission.plan.buildWorktree")
                          : planTarget === "compare"
                            ? t("permission.plan.buildCompare")
                            : plan
                              ? t("permission.plan.approve")
                              : t("permission.allowOnce")
                      }
                      data-plan-target={holdOnce && plan ? planTarget : undefined}
                      aria-describedby={scopeText ? targetId : undefined}
                      shortcut={shortcuts ? allowOnceShortcut : undefined}
                      cardKey={shortcuts ? ALLOW_KEY : undefined}
                      kind="primary"
                      className="acpmux-permission-primary"
                      onClick={() => answer(allowOnce)}
                      hold={holdOnce}
                      holdDescription={holdDescription}
                    />
                  );
                  return plan && onBuildPlan ? (
                    <PlanBuildSplit
                      harness={harness}
                      cardKey={shortcuts ? ALLOW_KEY : undefined}
                      holdFocus={holdOnce?.ref}
                      onPick={(target) => setPicked({ permissionId: permission.permissionId, target })}
                      onHere={() => answer(allowOnce)}
                      onBuild={build}
                    >
                      {approve}
                    </PlanBuildSplit>
                  ) : (
                    approve
                  );
                })()}
            </Surface.Trailing>
          )}
        </Surface.Actions>
      )}
      {settingsError?.id === permission.permissionId && (
        <p className="acpmux-permission-refused" role="alert">
          {settingsError.message}
        </p>
      )}
      {writing && (
        <form
          className="acpmux-permission-feedback"
          onSubmit={(event) => {
            event.preventDefault();
            void sendFeedback(writing.text);
          }}
        >
          <textarea
            ref={field}
            rows={2}
            aria-label={feedbackPlaceholder}
            placeholder={feedbackPlaceholder}
            value={writing.text}
            readOnly={writing.sending}
            onChange={(event) => setDraft({ permissionId: permission.permissionId, text: event.target.value })}
            // ui-allow: a text field's own Return (send) beside Shift-Return (new line), as the composer's.
            onKeyDown={(event) => {
              // An input method keeps its Return: WebKit can end the composition before the Return's
              // keydown, which then only says keyCode 229.
              if (event.key !== "Enter" || event.shiftKey) return;
              if (event.nativeEvent.isComposing || event.keyCode === 229) return;
              event.preventDefault();
              void sendFeedback(writing.text);
            }}
          />
          <div className="acpmux-permission-feedback-actions">
            <Surface.Action aria-keyshortcuts="Escape" disabled={writing.sending} onClick={closeFeedback}>
              {t("permission.feedbackCancel")}
              <Surface.Keys>
                <KeyHint keys={DENY_KEY.keys.join("")} aria-hidden="true" />
              </Surface.Keys>
            </Surface.Action>
            <Surface.Action
              kind="primary"
              type="submit"
              className="acpmux-permission-feedback-send"
              aria-keyshortcuts="Enter"
              disabled={writing.sending}
            >
              {t("permission.feedbackSend")}
              <Surface.Keys>
                <KeyHint keys="↩" aria-hidden="true" />
              </Surface.Keys>
            </Surface.Action>
          </div>
        </form>
      )}
    </PermissionCardFrame>
  );
}
