// l10n-allow-file: gallery fixtures, not shipped UI.
// Fork and pull request glyphs side by side where they show: a chat message's action row and a
// tab strip holding a forked chat beside the cmux GitHub page. The chosen drawings are the pack's
// (`agent.fork`, `git.pullrequest`); the candidates Leo compared are frozen here as paths.
import { Icon } from "../../agent-session/acpmux/icons/Icon";

export interface IconPassGalleryProps {
  fork: "peel-off" | "turned-y" | "before-y" | "node-branch";
}

/** Candidate fork drawings on the pack's 24-unit grid, stroke 1.5 (the pack's line weight). */
const FORK_PATHS: Record<Exclude<IconPassGalleryProps["fork"], "peel-off" | "node-branch">, string[]> = {
  "turned-y": ["M3 12h5c3 0 3.5-5.5 7-5.5H20M8 12c3 0 3.5 5.5 7 5.5H20", "M17 3.5 20 6.5l-3 3M17 14.5l3 3-3 3"],
  "before-y": ["M12 21v-5c0-3-5.5-3.5-5.5-7V4M12 16c0-3 5.5-3.5 5.5-7V4", "M3.5 7 6.5 4l3 3M14.5 7l3-3 3 3"],
};

function Fork({ fork, size }: { fork: IconPassGalleryProps["fork"]; size: number }) {
  if (fork === "peel-off") return <Icon name="agent.fork" size={size} />;
  if (fork === "node-branch") return <Icon name="git.branch" size={size} />;
  return (
    <svg
      width={size}
      height={size}
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      strokeWidth={1.5}
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden="true"
    >
      {FORK_PATHS[fork].map((d) => (
        <path key={d} d={d} />
      ))}
    </svg>
  );
}

export function IconPassGallery({ fork }: IconPassGalleryProps) {
  return (
    <div className="icon-pass">
      <section>
        <h3>Message actions</h3>
        <div className="icon-pass__row" role="toolbar" aria-label="Message actions">
          <span className="icon-pass__button">
            <Icon name="action.copy" size={16} />
          </span>
          <span className="icon-pass__button" data-active>
            <Fork fork={fork} size={16} />
          </span>
          <span className="icon-pass__button">
            <Icon name="action.pin" size={16} />
          </span>
          <span className="icon-pass__label">Fork from here</span>
        </div>
      </section>
      <section>
        <h3>Tabs</h3>
        <div className="icon-pass__tabs">
          <span className="icon-pass__tab">
            <Fork fork={fork} size={14} />
            Forked chat
          </span>
          <span className="icon-pass__tab" data-active>
            <Icon name="git.pullrequest" size={14} />
            GitHub
          </span>
          <span className="icon-pass__tab">
            <Icon name="git.pullrequest.merged" size={14} />
            #37574
          </span>
        </div>
      </section>
      <section>
        <h3>Sizes</h3>
        <div className="icon-pass__sizes">
          {[12, 14, 16, 20].map((size) => (
            <span key={size} className="icon-pass__size">
              <Fork fork={fork} size={size} />
              <Icon name="git.pullrequest" size={size} />
            </span>
          ))}
        </div>
      </section>
    </div>
  );
}
