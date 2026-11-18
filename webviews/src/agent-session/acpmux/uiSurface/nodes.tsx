// The registered components a surface's nodes draw with (`cmux.ui-surface/1`): cmux's own React,
// never agent markup. Every string is a React text child, so `<b>` in a label reads as `<b>`. Each
// node is memoized on its own content (model.ts `sameNode`), so a streamed update that re-sends the
// whole tree re-renders only the nodes that changed; fields read their value from the card's store
// by `bind` (values.ts), so an edit re-renders only that field.
import { createContext, memo, useContext, useId, useMemo, type ReactNode } from "react";
import { Input } from "../../../ui/Input";
import { useT } from "../i18n";
import { DiagramBlock } from "../conversation/DiagramBlock";
import { TableBlock } from "../conversation/TableBlock";
import { Icon } from "../icons/Icon";
import { AlertCircle, Check, ImageIcon, Spinner } from "../conversation/icons";
import {
  sameNode,
  valueKey,
  type UiApprovalNode,
  type UiButtonNode,
  type UiChartNode,
  type UiFieldNode,
  type UiNode,
  type UiProgressNode,
  type UiReviewNode,
  type UiSurfaceAction,
  type UiTableNode,
} from "./model";
import { useSurfaceValue } from "./values";
import { approvalLook, chartSource, choiceLook, reviewLook } from "./looks";

/// What a node's controls can do: press an action (the card asks acpmux, then shows the strip).
export type SurfaceActions = {
  act(action: UiSurfaceAction): void;
  /// The action whose confirmation is showing, or whose request is on its way.
  waiting?: string;
  /// Actions the person confirmed (their sends went): an approval reads Approved or Denied.
  answered: ReadonlySet<string>;
  /// While streaming, an error, or a request in flight: no new press.
  locked: boolean;
};

export const SurfaceActionsContext = createContext<SurfaceActions>({
  act: () => {},
  answered: new Set(),
  locked: true,
});

/// The fixed icon set (DESIGN `icon`): a name outside it draws nothing.
const ICONS: Readonly<Record<string, string>> = {
  check: "action.confirm",
  close: "action.close",
  search: "tool.search",
  time: "time.waiting",
  clock: "time.waiting",
  warning: "status.failure",
  error: "status.failure",
  info: "status.failure",
  web: "link.web",
  link: "link.web",
  folder: "folder",
  file: "file",
  edit: "action.edit",
  add: "action.add",
  image: "site.permission.images",
  mail: "message.send",
  send: "message.send",
  lock: "security.lock",
  play: "media.play",
  stop: "action.stop",
};

/// A node's accessibility props: its label, live region and hidden flag, and a description element.
type A11yProps = {
  "aria-label"?: string;
  "aria-live"?: "polite" | "assertive";
  "aria-hidden"?: true;
  "aria-describedby"?: string;
};

function useA11y(node: UiNode): { props: A11yProps; describe: ReactNode } {
  const id = useId();
  const a11y = node.a11y;
  if (!a11y) return { props: {}, describe: null };
  return {
    props: {
      "aria-label": a11y.label,
      "aria-live": a11y.live,
      "aria-hidden": a11y.hidden ? true : undefined,
      "aria-describedby": a11y.description ? `${id}-d` : undefined,
    },
    describe: a11y.description ? (
      <span id={`${id}-d`} hidden>
        {a11y.description}
      </span>
    ) : null,
  };
}

export const SurfaceNode = memo(
  function SurfaceNode({ node }: { node: UiNode }) {
    switch (node.type) {
      case "text":
        return <TextNode node={node} />;
      case "stack":
      case "card":
      case "list":
        return <Container node={node} />;
      case "divider":
        return <hr className="uis-divider" aria-hidden={node.a11y?.hidden ? true : undefined} />;
      case "icon":
        return <IconNode name={node.name} label={node.a11y?.label} />;
      case "image":
        return <ImageNode node={node} />;
      case "button":
        return <ButtonNode node={node} />;
      case "field":
        return <FieldNode node={node} />;
      case "approval":
        return <ApprovalNode node={node} />;
      case "review":
        return <ReviewNode node={node} />;
      case "table":
        return <TableNode node={node} />;
      case "chart":
        return <ChartNode node={node} />;
      case "progress":
        return <ProgressNode node={node} />;
      case "fallback":
        return <FallbackNode node={node} />;
    }
  },
  (previous, next) => sameNode(previous.node, next.node),
);

function TextNode({ node }: { node: Extract<UiNode, { type: "text" }> }) {
  const { props, describe } = useA11y(node);
  const content = (
    <>
      {node.text}
      {describe}
    </>
  );
  if (node.style === "heading")
    return (
      <h3 className="uis-heading" {...props}>
        {content}
      </h3>
    );
  if (node.style === "code")
    return (
      <pre className="uis-code" {...props}>
        {content}
      </pre>
    );
  return (
    <p className={node.style === "caption" ? "uis-caption" : "uis-text"} {...props}>
      {content}
    </p>
  );
}

function Container({ node }: { node: Extract<UiNode, { type: "stack" | "card" | "list" }> }) {
  const { props, describe } = useA11y(node);
  if (node.type === "list")
    return (
      <ul className="uis-list" {...props}>
        {node.children.map((child) => (
          <li key={child.id}>
            <SurfaceNode node={child} />
          </li>
        ))}
        {describe}
      </ul>
    );
  const className =
    node.type === "card" ? "uis-inner-card" : node.axis === "h" ? "uis-stack uis-stack--h" : "uis-stack";
  return (
    <div className={className} role={node.a11y?.label ? "group" : undefined} {...props}>
      {node.children.map((child) => (
        <SurfaceNode key={child.id} node={child} />
      ))}
      {describe}
    </div>
  );
}

function IconNode({ name, label }: { name: string; label?: string }) {
  const glyph = ICONS[name];
  if (!glyph) return null;
  return (
    <span
      className="uis-icon"
      role={label ? "img" : undefined}
      aria-label={label}
      aria-hidden={label ? undefined : true}
    >
      <Icon name={glyph} size={16} />
    </span>
  );
}

function ImageNode({ node }: { node: Extract<UiNode, { type: "image" }> }) {
  const t = useT();
  const { props, describe } = useA11y(node);
  // No fetch: the prototype draws the alt text in a frame (DESIGN `image`).
  return (
    <figure className="uis-image" role="img" aria-label={node.alt || t("uiSurface.image")} {...props}>
      <ImageIcon size={16} />
      <figcaption>{node.alt || t("uiSurface.image")}</figcaption>
      {describe}
    </figure>
  );
}

const variantClass = { primary: " is-primary", secondary: " is-secondary", danger: " is-danger" } as const;

function ButtonNode({ node }: { node: UiButtonNode }) {
  const actions = useContext(SurfaceActionsContext);
  const { props, describe } = useA11y(node);
  const action = node.action;
  return (
    <button
      type="button"
      className={`acpmux-ask-action uis-button${variantClass[node.variant]}`}
      disabled={!action || actions.locked}
      aria-pressed={action && actions.waiting === action.id ? true : undefined}
      onClick={() => action && actions.act(action)}
      {...props}
    >
      {node.label}
      {describe}
    </button>
  );
}

// ---------- fields ----------

function FieldNode({ node }: { node: UiFieldNode }) {
  const id = useId();
  const { props, describe } = useA11y(node);
  const [value, setValue] = useSurfaceValue(valueKey(node));
  const label = (
    <label className="uis-field-label" htmlFor={id}>
      {node.label}
    </label>
  );
  switch (node.input) {
    case "text":
    case "date":
      return (
        <div className="uis-field" {...props}>
          {label}
          <Input
            id={id}
            type={node.input === "date" ? "date" : node.secure ? "password" : "text"}
            variant="outline"
            size="sm"
            value={typeof value === "string" ? value : ""}
            onChange={(event) => setValue(event.currentTarget.value)}
          />
          {describe}
        </div>
      );
    case "checkbox":
      return (
        <div className="uis-field uis-field--check" {...props}>
          <input
            id={id}
            type="checkbox"
            className="uis-checkbox"
            checked={value === true}
            onChange={(event) => setValue(event.currentTarget.checked)}
          />
          {label}
          {describe}
        </div>
      );
    case "slider": {
      const min = node.min ?? 0;
      const max = node.max ?? 100;
      const current = typeof value === "number" ? value : min;
      return (
        <div className="uis-field" {...props}>
          <span className="uis-field-head">
            {label}
            <output className="uis-field-value" htmlFor={id}>
              {current}
            </output>
          </span>
          <input
            id={id}
            type="range"
            className="uis-slider"
            min={min}
            max={max}
            value={current}
            onChange={(event) => setValue(Number(event.currentTarget.value))}
          />
          {describe}
        </div>
      );
    }
    case "choice":
      return <ChoiceField node={node} value={value} setValue={setValue} a11y={props} describe={describe} />;
  }
}

function ChoiceField({
  node,
  value,
  setValue,
  a11y,
  describe,
}: {
  node: UiFieldNode;
  value: unknown;
  setValue: (value: string | string[]) => void;
  a11y: A11yProps;
  describe: ReactNode;
}) {
  const labelId = useId();
  const options = node.options ?? [];
  const picked = Array.isArray(value) ? value : typeof value === "string" ? [value] : [];
  const toggle = (option: string) =>
    node.multi
      ? setValue(picked.includes(option) ? picked.filter((each) => each !== option) : [...picked, option])
      : setValue(option);
  if (choiceLook(node) === "menu")
    return (
      <div className="uis-field" {...a11y}>
        <label className="uis-field-label" htmlFor={`${labelId}-s`}>
          {node.label}
        </label>
        <select
          id={`${labelId}-s`}
          className="uis-select"
          value={picked[0] ?? ""}
          onChange={(event) => setValue(event.currentTarget.value)}
        >
          {picked.length === 0 && <option value="" disabled />}
          {options.map((option) => (
            <option key={option.value} value={option.value}>
              {option.label}
            </option>
          ))}
        </select>
        {describe}
      </div>
    );
  return (
    <div className="uis-field" {...a11y}>
      <span className="uis-field-label" id={labelId}>
        {node.label}
      </span>
      <div className="uis-chips" role={node.multi ? "group" : "radiogroup"} aria-labelledby={labelId}>
        {options.map((option) => {
          const on = picked.includes(option.value);
          return (
            <button
              key={option.value}
              type="button"
              className="uis-chip"
              role={node.multi ? "checkbox" : "radio"}
              aria-checked={on}
              onClick={() => toggle(option.value)}
            >
              {node.multi && on && <Check size={12} />}
              {option.label}
            </button>
          );
        })}
      </div>
      {describe}
    </div>
  );
}

// ---------- approval ----------

function ApprovalNode({ node }: { node: UiApprovalNode }) {
  const t = useT();
  const actions = useContext(SurfaceActionsContext);
  const { props, describe } = useA11y(node);
  const titleId = useId();
  const look = approvalLook(node);
  const approved = node.approve && actions.answered.has(node.approve.id);
  const denied = node.deny && actions.answered.has(node.deny.id);
  const answer = approved ? t("uiSurface.approved") : denied ? t("uiSurface.denied") : undefined;
  const buttons = answer ? (
    <span className="uis-answer" role="status">
      {approved ? <Check size={12} /> : null}
      {answer}
    </span>
  ) : (
    <div className="acpmux-ask-actions">
      {node.deny && (
        <button
          type="button"
          className="acpmux-ask-action"
          disabled={actions.locked}
          aria-pressed={actions.waiting === node.deny.id ? true : undefined}
          aria-keyshortcuts="n"
          onClick={() => node.deny && actions.act(node.deny)}
        >
          {t("permission.deny")}
        </button>
      )}
      {node.approve && (
        <button
          type="button"
          className={`acpmux-ask-action ${look === "danger" ? "is-danger" : "is-primary"}`}
          disabled={actions.locked}
          aria-pressed={actions.waiting === node.approve.id ? true : undefined}
          aria-keyshortcuts="y"
          onClick={() => node.approve && actions.act(node.approve)}
        >
          {t("uiSurface.approve")}
        </button>
      )}
    </div>
  );
  if (look === "compact")
    return (
      <div className="uis-approval uis-approval--compact" role="group" aria-labelledby={titleId} {...props}>
        <div className="acpmux-ask-row">
          <span className="uis-approval-title" id={titleId}>
            {node.title}
          </span>
          {buttons}
        </div>
        {describe}
      </div>
    );
  return (
    <div className={`uis-approval uis-approval--${look}`} role="group" aria-labelledby={titleId} {...props}>
      <div className="uis-approval-head">
        {look === "danger" && (
          <span className="uis-approval-mark" aria-hidden="true">
            <AlertCircle size={16} />
          </span>
        )}
        <strong className="uis-approval-title" id={titleId}>
          {node.title}
        </strong>
        {look === "danger" && <span className="uis-risk">{t("uiSurface.riskHigh")}</span>}
      </div>
      {node.detail && <p className="uis-approval-detail">{node.detail}</p>}
      {node.facts.length > 0 && (
        <dl className="uis-facts">
          {node.facts.map((fact, index) => (
            <div key={index} className="uis-fact">
              <dt>{fact.label}</dt>
              <dd>{fact.value}</dd>
            </div>
          ))}
        </dl>
      )}
      <div className="uis-approval-foot">{buttons}</div>
      {describe}
    </div>
  );
}

// ---------- review ----------

function ReviewNode({ node }: { node: UiReviewNode }) {
  const t = useT();
  const actions = useContext(SurfaceActionsContext);
  const { props, describe } = useA11y(node);
  const titleId = useId();
  const [value, setValue] = useSurfaceValue(valueKey(node));
  const picked = Array.isArray(value) ? value : typeof value === "string" ? [value] : [];
  const sent = node.submit && actions.answered.has(node.submit.id);
  const look = reviewLook(node);
  const toggle = (id: string) => {
    if (sent) return;
    if (node.multi) setValue(picked.includes(id) ? picked.filter((each) => each !== id) : [...picked, id]);
    else setValue(id);
  };
  const role = node.multi ? "checkbox" : "radio";
  return (
    <div className={`uis-review uis-review--${look}`} role="group" aria-labelledby={titleId} {...props}>
      <strong className="uis-review-title" id={titleId}>
        {node.title}
      </strong>
      {node.prompt && <p className="uis-review-prompt">{node.prompt}</p>}
      <div
        className={look === "chips" ? "uis-chips" : "uis-options"}
        role={node.multi ? "group" : "radiogroup"}
        aria-labelledby={titleId}
      >
        {node.options.map((option, index) => {
          const on = picked.includes(option.id);
          if (look === "chips")
            return (
              <button
                key={option.id}
                type="button"
                className="uis-chip"
                role={role}
                aria-checked={on}
                aria-disabled={sent ? true : undefined}
                onClick={() => toggle(option.id)}
              >
                {option.label}
              </button>
            );
          return (
            <button
              key={option.id}
              type="button"
              className="uis-option"
              role={role}
              aria-checked={on}
              aria-disabled={sent ? true : undefined}
              onClick={() => toggle(option.id)}
            >
              <span className={`uis-option-mark${node.multi ? " is-box" : ""}`} aria-hidden="true">
                {on && (node.multi ? <Check size={12} /> : <span className="uis-option-dot" />)}
              </span>
              {look === "ranked" && (
                <span className="uis-option-rank" aria-hidden="true">
                  {index + 1}
                </span>
              )}
              <span className="uis-option-text">
                <span className="uis-option-label">{option.label}</span>
                {option.detail && <span className="uis-option-detail">{option.detail}</span>}
              </span>
            </button>
          );
        })}
      </div>
      {node.submit && (
        <div className="uis-review-foot">
          {sent ? (
            <span className="uis-answer" role="status">
              <Check size={12} />
              {t("uiSurface.sent")}
            </span>
          ) : (
            <button
              type="button"
              className="acpmux-ask-action is-primary"
              disabled={actions.locked || picked.length === 0}
              aria-pressed={actions.waiting === node.submit.id ? true : undefined}
              onClick={() => node.submit && actions.act(node.submit)}
            >
              {t("uiSurface.submit")}
            </button>
          )}
        </div>
      )}
      {describe}
    </div>
  );
}

// ---------- table, chart, progress, fallback ----------

const plain = (text: string) => text;

function TableNode({ node }: { node: UiTableNode }) {
  const t = useT();
  const { props, describe } = useA11y(node);
  const table = useMemo(
    () => ({
      header: node.columns.map((column) => column.label),
      align: node.columns.map((column) => column.align ?? null),
      rows: node.rows,
    }),
    [node],
  );
  return (
    <div className="uis-table" {...props}>
      <TableBlock table={table} cell={plain} />
      {node.truncated && <p className="uis-caption">{t("uiSurface.truncated", { count: node.rows.length })}</p>}
      {describe}
    </div>
  );
}

function ChartNode({ node }: { node: UiChartNode }) {
  const { props, describe } = useA11y(node);
  const t = useT();
  const source = useMemo(() => chartSource(node), [node]);
  if (!source) return <FallbackNode node={{ type: "fallback", id: node.id, text: t("uiSurface.chart") }} />;
  return (
    <div className="uis-chart" role="figure" aria-label={node.a11y?.label ?? node.yLabel} {...props}>
      <DiagramBlock lang="vega-lite" code={source} />
      {describe}
    </div>
  );
}

function ProgressNode({ node }: { node: UiProgressNode }) {
  const t = useT();
  const { props, describe } = useA11y(node);
  const max = node.max ?? 100;
  const determinate = node.value !== undefined;
  const ratio = determinate ? Math.max(0, Math.min(1, (node.value ?? 0) / (max || 1))) : 0;
  return (
    <div className={`uis-progress is-${node.state}`} {...props}>
      <span className="uis-progress-head">
        {node.state === "done" ? (
          <Check size={12} />
        ) : node.state === "failed" ? (
          <AlertCircle size={12} />
        ) : (
          <Spinner size={12} loading={!determinate} />
        )}
        <span className="uis-progress-label">{node.label}</span>
        {determinate && <span className="uis-progress-count">{`${Math.round(ratio * 100)}%`}</span>}
        {node.state !== "running" && (
          <span className="uis-sr">{t(node.state === "done" ? "uiSurface.done" : "uiSurface.failed")}</span>
        )}
      </span>
      {determinate && (
        <span
          className="uis-progress-track"
          role="progressbar"
          aria-label={node.label}
          aria-valuemin={0}
          aria-valuemax={max}
          aria-valuenow={node.value}
        >
          <span className="uis-progress-fill" style={{ inlineSize: `${ratio * 100}%` }} />
        </span>
      )}
      {describe}
    </div>
  );
}

function FallbackNode({ node }: { node: Extract<UiNode, { type: "fallback" }> }) {
  const t = useT();
  const { props, describe } = useA11y(node);
  return (
    <p className="uis-fallback" role="note" {...props}>
      {t("uiSurface.cannotShow", { what: node.text })}
      {describe}
    </p>
  );
}
