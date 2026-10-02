// The 44px title row over the transcript (overview.png): sidebar toggle, the chat's title
// with its folder icon, then ⋯ and the Changes toggle at the right. cmux owns the window
// chrome; this row is the pane's own.
import { IconFolder, IconMore, IconSidebar } from "../shell/icons";
import { SummaryToggle } from "../conversation/icons";

export type TitleRowProps = {
  title: string;
  inProject: boolean;
  sidebarOpen: boolean;
  changesOpen: boolean;
  onToggleSidebar: () => void;
  onToggleChanges: () => void;
};

export function TitleRow({
  title,
  inProject,
  sidebarOpen,
  changesOpen,
  onToggleSidebar,
  onToggleChanges,
}: TitleRowProps) {
  return (
    <header className="pt-titlerow">
      <button
        type="button"
        className={`pt-titlebtn${sidebarOpen ? " is-active" : ""}`}
        aria-label="Toggle sessions"
        aria-pressed={sidebarOpen}
        onClick={onToggleSidebar}
      >
        <IconSidebar size={16} />
      </button>
      <div className="pt-titlerow__title">
        {inProject && <IconFolder size={16} className="pt-titlerow__icon" />}
        <span className="pt-titlerow__text">{title}</span>
      </div>
      <div className="pt-titlerow__tools">
        <button type="button" className="pt-titlebtn" aria-label="Chat actions">
          <IconMore size={16} />
        </button>
        <button
          type="button"
          className={`pt-titlebtn${changesOpen ? " is-active" : ""}`}
          aria-label="Toggle changes"
          aria-pressed={changesOpen}
          onClick={onToggleChanges}
        >
          <SummaryToggle size={16} strokeWidth={1.2} />
        </button>
      </div>
    </header>
  );
}
