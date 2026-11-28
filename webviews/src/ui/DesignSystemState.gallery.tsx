// l10n-allow-file: gallery labels and fixtures, not shipped UI.
// Where the design system stands (Leo, 2026-11-22: "the toast is this awkward pill glass. im not
// sure if it should be that rounded. what's our design language?" and "idk what the state of our
// design systems are"). One board of the shared primitives and the bespoke look-alikes beside them.
// Under each specimen the caption prints what the browser computed (corner radius, height, tint,
// blur, shadow), re-read whenever a stylesheet is added, so a capture of an arm (the capture spec's
// CSS strings) carries its own numbers. Menu, popover, tooltip and dialog are drawn as their
// surface classes in place (their real components only render in a positioned portal); the toast,
// buttons and pill are the real components.
import { useCallback, useEffect, useRef, useState, type ReactNode } from "react";
import { componentEntry } from "../gallery/format";
import { Button } from "./Button";
import { Notice } from "./Notice";
import { Pill } from "../kit/Pill";
import { PermissionCard } from "../agent-session/acpmux/PermissionCard";
import type { AcpmuxPermission } from "../agent-session/acpmux/model";

/** The ask in Leo's capture ("Confirm base unchanged for edited files": Deny, Allow once). */
const ASK: AcpmuxPermission = {
  permissionId: "design-system-ask",
  kind: "execute",
  title: "Confirm base unchanged for edited files",
  command: "export CALLER_SUBAGENT=general-purpose:ab7438a3",
  description: "Bypass permissions doesn't cover this one. Allow once lets it run this time only.",
  pending: true,
  options: [
    { id: "allow_once", name: "Allow once", kind: "allow_once", allow: true },
    { id: "reject_once", name: "Deny", kind: "reject_once", allow: false },
  ],
};

const noop = () => undefined;

/** One printed line per measured element: radius, height and material, from getComputedStyle. */
function measure(label: string, el: Element): string {
  const style = getComputedStyle(el);
  const radius = style.borderTopLeftRadius.split(" ")[0];
  const height = Math.round(el.getBoundingClientRect().height * 2) / 2;
  const alpha = /\/\s*([\d.]+)\s*\)|rgba\([^)]*,\s*([\d.]+)\)/.exec(style.backgroundColor);
  const fill = style.backgroundColor === "rgba(0, 0, 0, 0)" ? 0 : alpha ? Number(alpha[1] ?? alpha[2]) : 1;
  const filter =
    style.backdropFilter === "none" ? style.getPropertyValue("-webkit-backdrop-filter") : style.backdropFilter;
  const blur = /blur\(([\d.]+px)\)/.exec(filter ?? "")?.[1];
  const shadow = style.boxShadow === "none" ? "no shadow" : "shadow";
  const material = fill === 0 && !blur ? "no fill" : `fill ${Math.round(fill * 100)}%${blur ? ` blur ${blur}` : ""}`;
  return `${label}: r ${radius} · h ${height} · ${material} · ${shadow}`;
}

function Spec({
  id,
  measure: targets,
  children,
}: {
  id: string;
  measure: Record<string, string>;
  children: ReactNode;
}) {
  const wanted = useRef(targets);
  const ref = useRef<HTMLElement>(null);
  const [lines, setLines] = useState("");
  const read = useCallback(() => {
    const root = ref.current;
    if (!root) return;
    setLines(
      Object.entries(wanted.current)
        .flatMap(([label, selector]) =>
          [...root.querySelectorAll(selector)].slice(0, 1).map((el) => measure(label, el)),
        )
        .join("\n"),
    );
  }, []);
  useEffect(() => {
    read();
    // An arm is a stylesheet added after mount: read again, once the frame has used it.
    const watch = new MutationObserver(() => requestAnimationFrame(() => requestAnimationFrame(read)));
    watch.observe(document.head, { childList: true });
    watch.observe(document.documentElement, { attributes: true });
    return () => watch.disconnect();
  }, [read]);
  return (
    <figure className="ds-state-spec" data-ds-spec={id} ref={ref}>
      {children}
      <figcaption className="ds-state-measure" data-ds-caption>
        {lines}
      </figcaption>
    </figure>
  );
}

function Group({ title, wide, children }: { title: string; wide?: boolean; children: ReactNode }) {
  return (
    <section className="ds-state-group" data-wide={wide ? "" : undefined}>
      <h3 className="ds-state-title">{title}</h3>
      {children}
    </section>
  );
}

function DesignSystemState() {
  return (
    <div className="ds-state">
      <Group title="Toast (ui/Notice.tsx, stack placement)">
        <Spec id="toast" measure={{ toast: ".ui-notice" }}>
          <Notice kind="toast" placement="stack" message="Copied the link." />
        </Spec>
        <Spec id="toast-action" measure={{ "toast + action": ".ui-notice" }}>
          <Notice
            kind="toast"
            placement="stack"
            message="Archived 3 chats."
            actions={[{ id: "undo", label: "Undo", onSelect: noop }]}
          />
        </Spec>
      </Group>

      <Group title="Tooltips (ui/Tooltip.tsx vs ui/titleTooltips.ts)">
        <Spec id="tooltip" measure={{ "Tooltip (data-host-glass)": ".ui-tooltip" }}>
          <div className="ui-tooltip ui-glass" data-host-glass="chip" data-host-glass-cover="">
            <span className="ui-tooltip-text">New chat</span>
          </div>
        </Spec>
        <Spec id="title-tooltip" measure={{ "title= tooltip": ".ui-title-tooltip" }}>
          <div className="ui-title-tooltip ui-glass">New chat</div>
        </Spec>
      </Group>

      <Group title="Menu and popover (ui/Menu.tsx, ui/Popover.tsx)">
        <Spec id="menu" measure={{ menu: ".ui-menu", "menu row": ".ui-menu-item[data-highlighted]" }}>
          <div className="ui-popup ui-glass ui-menu" role="menu" aria-label="Demo menu">
            <div className="ui-menu-item" role="menuitem">
              Rename
            </div>
            <div className="ui-menu-item" role="menuitem" data-highlighted="">
              Duplicate
            </div>
            <div className="ui-menu-item" role="menuitem">
              Archive
            </div>
            <div className="ui-menu-item" role="menuitem">
              Delete
            </div>
          </div>
        </Spec>
        <Spec id="popover" measure={{ popover: ".ui-popover" }}>
          <div className="ui-popup ui-glass ui-popover" role="dialog" aria-label="Demo popover">
            Anchored content, a short body.
          </div>
        </Spec>
      </Group>

      <Group title="Buttons (ui/Button.tsx) and raw look-alikes" wide>
        <Spec
          id="buttons"
          measure={{
            "Button sm": '.ui-button[data-size="sm"]',
            "Button md": '.ui-button[data-size="md"]',
            "Button lg": '.ui-button[data-size="lg"]',
            "Button icon": ".ui-button[data-icon]",
          }}
        >
          <div className="ds-state-row">
            {(["ghost", "subtle", "solid"] as const).map((variant) =>
              (["sm", "md", "lg"] as const).map((size) => (
                <Button key={`${variant}-${size}`} variant={variant} size={size}>
                  {variant} {size}
                </Button>
              )),
            )}
            <Button variant="subtle" icon aria-label="Icon button">
              +
            </Button>
          </div>
        </Spec>
        <Spec
          id="buttons-raw"
          measure={{
            "ui/ghost.css .ui-ghost": ".ui-ghost",
            "pages/stats .stats-range": ".stats-range",
            "icon-picker .icon-picker-back": ".icon-picker-back",
          }}
        >
          <div className="ds-state-row">
            <button type="button" className="ui-ghost" data-ds-bespoke="button">
              Ghost
            </button>
            <span className="stats-ranges">
              <button type="button" className="stats-range is-selected" data-ds-bespoke="button">
                7 days
              </button>
              <button type="button" className="stats-range" data-ds-bespoke="button">
                30 days
              </button>
            </span>
            <button type="button" className="icon-picker-back" data-ds-bespoke="button" aria-label="Back">
              ‹
            </button>
          </div>
        </Spec>
      </Group>

      <Group title="Dialog (ui/Dialog.tsx surface)">
        <Spec id="dialog" measure={{ dialog: ".ui-dialog" }}>
          <div className="ui-dialog ui-glass ui-glass-floats" role="dialog" aria-label="Demo dialog">
            <strong>Delete this chat?</strong>
            <span>Its messages go too.</span>
            <div className="ds-state-row">
              <Button variant="ghost">Cancel</Button>
              <Button variant="solid">Delete</Button>
            </div>
          </div>
        </Spec>
      </Group>

      <Group title="Pills and chips (kit/Pill.tsx and bespoke)" wide>
        <Spec
          id="pills"
          measure={{ "kit Pill sm": '.kit-pill[data-size="sm"]', "kit Pill md": '.kit-pill[data-size="md"]' }}
        >
          <div className="ds-state-row">
            <Pill size="sm">sm</Pill>
            <Pill size="md" tone="accent">
              md accent
            </Pill>
            <Pill size="md">md</Pill>
          </div>
        </Spec>
        <Spec
          id="chips"
          measure={{
            "composer .acpmux-file-chip": ".acpmux-file-chip",
            "server .sv-pill": ".sv-pill",
            "feed .feed-chip": ".feed-chip",
            "changelog .wn-notes-chip": ".wn-notes-chip",
          }}
        >
          <div className="ds-state-row">
            <span className="acpmux-attachment-file">
              <span className="acpmux-file-chip" data-ds-bespoke="chip">
                notes.md
              </span>
            </span>
            <span className="sv-pill" data-ds-bespoke="chip">
              running
            </span>
            <span className="feed-chip" data-ds-bespoke="chip">
              #47826
            </span>
            <span className="wn-notes-chip" data-ds-bespoke="chip">
              feat/worktree
            </span>
          </div>
        </Spec>
      </Group>

      <Group title="Ask card (agent chat) and link hover card">
        <Spec
          id="ask"
          measure={{ "ask card": ".acpmux-permission-card", "ask button": ".acpmux-permission-buttons button" }}
        >
          <div className="acpmux-shell ds-state-shell">
            <div className="acpmux-main">
              <div className="acpmux-permission acpmux-asks-stack">
                <PermissionCard permission={ASK} harness="claude" shortcuts={false} onAnswer={noop} />
              </div>
            </div>
          </div>
        </Spec>
        <Spec
          id="hover-card"
          measure={{ "link hover card": ".cv-link-preview", "its Open split": ".cv-link-preview__split" }}
        >
          <div className="ui-tooltip ui-card ui-glass cv-link-preview" data-host-glass="popover">
            <div className="cv-link-preview__content">
              <div className="cv-link-preview__head">
                <span className="cv-link-preview__titles">
                  <span className="cv-link-preview__site">Fix sidebar scroll thumb</span>
                  <span className="cv-link-preview__target">example/repo#49859</span>
                </span>
                <span className="cv-link-preview__split">
                  <button type="button" className="cv-link-preview__open">
                    Open
                  </button>
                </span>
              </div>
            </div>
          </div>
        </Spec>
        <p className="ds-state-measure">Tab hover preview: native only (no web component), not drawn.</p>
      </Group>

      <Group title="Card and composer shell">
        <Spec id="card" measure={{ ".ui-card .ui-glass-content": ".ui-card" }}>
          <div className="ui-card ui-glass ui-glass-content">A card in the content layer.</div>
        </Spec>
        <Spec id="composer" measure={{ "composer shell": ".ds-state-composer" }}>
          <div className="ds-state-composer">Ask anything</div>
        </Spec>
      </Group>
    </div>
  );
}

export default componentEntry<Record<string, never>>({
  id: "ui.design-system-state",
  title: "Design system state",
  area: "UI primitives",
  height: 1100,
  covers: ["ui/DesignSystemState.gallery.tsx"],
  load: async () => DesignSystemState,
  styles: () =>
    Promise.all([
      import("./ui.css"),
      import("./popupSurface.css"),
      import("./Notice"),
      import("../kit/kit.css"),
      import("./ghost.css"),
      import("../pages/stats/styles.css"),
      import("../icon-picker/styles.css"),
      import("../pages/server-cards/server/server.css"),
      import("../pages/feed/styles.css"),
      import("../pages/changelog/updateSurfaces.css"),
      import("../agent-session/acpmux/composerAttachments.css"),
      import("../agent-session/acpmux/styles.css"),
      import("../agent-session/acpmux/conversation/conversation.css"),
      import("../agent-session/acpmux/chips/linkCard.css"),
      import("./DesignSystemState.gallery.css"),
    ]),
  variants: { board: { props: {}, note: "Every specimen with its computed radius, height and material." } },
});
