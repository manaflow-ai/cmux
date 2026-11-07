import type { CSSProperties } from "react";
import { Icon } from "../../agent-session/acpmux/icons/Icon";
import { Spinner } from "../../agent-session/acpmux/conversation/icons";
import {
  sidebarGroups,
  sidebarTokens,
  sidebarVariantClass,
  type SidebarAppearance,
  type SidebarDensity,
  type SidebarVariant,
} from "./sidebarShapeModel";
import "./sidebarShapes.css";

export function SidebarShapes({
  variant,
  density,
  appearance,
  uiScale = 1,
}: {
  variant: SidebarVariant;
  density: SidebarDensity;
  appearance: SidebarAppearance;
  uiScale?: number;
}) {
  const tokens = sidebarTokens(density, uiScale);
  const style = Object.fromEntries(
    Object.entries(tokens).map(([key, value]) => [
      `--sidebar-${key.replace(/[A-Z]/g, (c) => `-${c.toLowerCase()}`)}`,
      key === "scale" ? value : `calc(${value}px * var(--cmux-interface-scale, 1))`,
    ]),
  ) as CSSProperties;
  return (
    <aside
      className={`sidebar-shape ${sidebarVariantClass(variant)}`}
      data-density={density}
      data-appearance={appearance}
      style={style}
      aria-label="Workspaces"
    >
      {sidebarGroups(variant).map((group) => (
        <section
          className="sidebar-shape__group"
          key={group.title}
          style={{ "--sidebar-group-colour": group.colour ?? "currentColor" } as CSSProperties}
        >
          <div className="sidebar-shape__label">
            <span>{group.title}</span>
            <span className="sidebar-shape__disclosure" aria-hidden>
              ⌄
            </span>
          </div>
          <div className="sidebar-shape__members">
            {group.rows.map((row) => (
              <div className="sidebar-shape__row" key={row.title} aria-selected={row.selected || undefined}>
                <span className="sidebar-shape__icon" aria-hidden>
                  {variant === "D" && row.icon && <Icon name={row.icon} size={tokens.iconSize} row fit />}
                </span>
                <span className="sidebar-shape__title">{row.title}</span>
                <span className="sidebar-shape__trail" aria-hidden>
                  {row.detail === "Working" && <Spinner size={tokens.iconSize} />}
                </span>
                <button className="sidebar-shape__more" aria-label={`More for ${row.title}`}>
                  ···
                </button>
              </div>
            ))}
          </div>
        </section>
      ))}
    </aside>
  );
}
