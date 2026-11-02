// A feature tip (leo-workspace design/feature-tips.md): a small glass callout under (or over) the
// control it is about, with an arrow at that control, a title, a "New" pill, a close X and one
// sentence. It is placed and dismissed by its caller (ui/featureTips/FeatureTipHost.tsx, which holds
// the rules for when one may show). It never takes focus: it opens while the person is idle and
// must not move the caret or the keyboard's target. It opens in one frame, as a menu does (Leo
// 2026-10-24: "you click, you get a response"), and fades out as a popup does (ui/popupSurface.css).
import { useId, type KeyboardEvent, type Ref } from "react";
import { Tooltip as BaseTooltip } from "@base-ui/react/tooltip";
import { usePortalContainer } from "./UiProvider";
import { cx } from "./cx";
import "./featureTip.css";

/** The callout's look. `glass` is the shipped one; the other two stay in the gallery. */
export type FeatureTipLook = "glass" | "accent" | "veil";

export interface FeatureTipProps {
  /** The control the tip is about; nothing shows while it is null. */
  anchor: Element | null;
  /** False keeps it placed while it fades out. */
  open: boolean;
  title: string;
  /** One sentence. */
  body: string;
  /** The pill's text ("New"). */
  newLabel: string;
  /** The X's accessible name ("Close tip"). */
  closeLabel: string;
  /** The X, and Escape while focus is inside the tip. */
  onClose(): void;
  look?: FeatureTipLook;
  side?: "top" | "bottom";
  /** The tip's element, for its host's inside and outside checks. */
  popupRef?: Ref<HTMLDivElement>;
}

/** The space the arrow takes between the control and the card. */
export const FEATURE_TIP_GAP = 8;

export function FeatureTip({
  anchor,
  open,
  title,
  body,
  newLabel,
  closeLabel,
  onClose,
  look = "glass",
  side = "bottom",
  popupRef,
}: FeatureTipProps) {
  const container = usePortalContainer();
  const titleId = useId();
  const onKeyDown = (event: KeyboardEvent<HTMLDivElement>) => {
    if (event.key !== "Escape") return;
    event.stopPropagation();
    onClose();
  };
  return (
    <BaseTooltip.Root open={open && anchor !== null}>
      <BaseTooltip.Portal container={container}>
        <BaseTooltip.Positioner
          className="ui-positioner"
          anchor={anchor}
          side={side}
          align="center"
          sideOffset={FEATURE_TIP_GAP}
          collisionPadding={8}
        >
          <BaseTooltip.Popup
            ref={popupRef}
            className={cx("ui-popup ui-glass ui-feature-tip")}
            data-look={look}
            data-feature-tip=""
            // oxlint-disable-next-line jsx-a11y/prefer-tag-over-role -- Base UI's positioned popup; a native <dialog> would bring its own modal semantics and styles.
            role="dialog"
            aria-modal={false}
            aria-labelledby={titleId}
            onKeyDown={onKeyDown}
          >
            <BaseTooltip.Arrow className="ui-feature-tip-arrow" />
            <div className="ui-feature-tip-head">
              <span id={titleId} className="ui-feature-tip-title">
                {title}
              </span>
              <span className="ui-feature-tip-new">{newLabel}</span>
              <button type="button" className="ui-feature-tip-close" aria-label={closeLabel} onClick={onClose}>
                <svg viewBox="0 0 16 16" width="10" height="10" aria-hidden="true">
                  <path d="M3.5 3.5l9 9m0-9l-9 9" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" />
                </svg>
              </button>
            </div>
            <p className="ui-feature-tip-body">{body}</p>
          </BaseTooltip.Popup>
        </BaseTooltip.Positioner>
      </BaseTooltip.Portal>
    </BaseTooltip.Root>
  );
}
