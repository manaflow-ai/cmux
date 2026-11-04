// Static transcript glyphs use the same cmux pack as the rest of the pane.
// Spinner and third-party marks retain their independently settled drawings.
import type { CSSProperties } from "react";
import { Icon } from "../icons/Icon";
import "./spinner.css";

export type CvIconProps = {
  size?: number;
  className?: string;
  style?: CSSProperties;
};

function glyph(name: string) {
  return function TranscriptIcon(props: CvIconProps) {
    return <Icon name={name} {...props} />;
  };
}

export const ChevronRight = glyph("disclosure.collapsed");
export const ChevronLeft = glyph("nav.previous");
export const Close = glyph("action.close");
export const ChevronDown = glyph("disclosure.expanded");
export const Globe = glyph("link.web");
export const ImageIcon = glyph("site.permission.images");
export const Copy = glyph("action.copy");
export const Pencil = glyph("action.edit");
export const ToolGroup = glyph("tool.group");
export const DiffFile = glyph("diff.file");
export const Undo = glyph("action.undo");
export const Lock = glyph("security.lock");
export const Plus = glyph("action.add");
export const Check = glyph("action.confirm");
export const Speaker = glyph("media.audio");
export const CodeBrackets = glyph("code");
export const WrapLines = glyph("text.wrap");
export const TerminalSquare = glyph("tool.shell");
export const OpenBook = glyph("tool.read");
export const Magnifier = glyph("tool.search");
export const Folder = glyph("folder");
export const FileDoc = glyph("file");
export const ArrowRight = glyph("action.go");
export const Expand = glyph("view.expand");
export const OpenTab = glyph("view.tab.trailing");
export const SaveTray = glyph("action.save");
export const Retry = glyph("action.retry");
export const AlertCircle = glyph("status.failure");
export const DoubleCheck = glyph("message.delivered");
export const Quote = glyph("action.quote");
export const StopReading = glyph("media.stop.circle");
export const Clock = glyph("time.waiting");
export const SummaryToggle = glyph("transcript.summary");
export const Connectors = glyph("sources.connected");
export const MultiTool = glyph("tool.multiple");
export const Envelope = glyph("message.send");
export const Bot = glyph("agent.bot");
export const PauseCircle = glyph("agent.paused");
export const ArrowDown = glyph("nav.down");

export const Pin = ({ filled, ...props }: CvIconProps & { filled?: boolean }) => (
  <Icon name="action.pin" selected={filled} {...props} />
);

export const TurnCopy = ({ size = 14 }: CvIconProps = {}) => <Copy size={size} />;
export const TurnFork = ({ size = 14 }: CvIconProps = {}) => <Icon name="agent.fork" size={size} />;
export const TurnAnchor = ({ size = 14 }: CvIconProps = {}) => <Icon name="bookmark" size={size} />;
export const StopSquare = (props: CvIconProps) => <Icon name="action.stop" selected {...props} />;
export const PlayTriangle = (props: CvIconProps) => <Icon name="media.play" selected {...props} />;

export const GitHubMark = ({ size = 16, className, style }: CvIconProps) => (
  <svg
    className={className}
    style={style}
    width={size}
    height={size}
    viewBox="0 0 16 16"
    fill="currentColor"
    aria-hidden="true"
  >
    <path d="M8 .2a8 8 0 0 0-2.53 15.6c.4.07.55-.17.55-.38v-1.33c-2.23.48-2.7-1.07-2.7-1.07-.36-.92-.89-1.17-.89-1.17-.73-.5.06-.49.06-.49.8.06 1.23.83 1.23.83.71 1.22 1.87.87 2.33.66.07-.52.28-.87.5-1.07-1.78-.2-3.65-.89-3.65-3.95 0-.87.31-1.59.83-2.15-.08-.2-.36-1.02.08-2.12 0 0 .67-.21 2.2.82a7.6 7.6 0 0 1 4 0c1.53-1.03 2.2-.82 2.2-.82.44 1.1.16 1.92.08 2.12.51.56.82 1.28.82 2.15 0 3.07-1.87 3.75-3.65 3.95.29.25.54.73.54 1.48v2.2c0 .21.15.46.55.38A8 8 0 0 0 8 .2Z" />
  </svg>
);

export const Spinner = ({
  size = 16,
  className,
  style,
  strokeWidth = 1.5,
  loading = false,
}: CvIconProps & { loading?: boolean; strokeWidth?: number }) => (
  <svg
    className={className ? `cv-spinner ${className}` : "cv-spinner"}
    style={style}
    width={size}
    height={size}
    viewBox="0 0 16 16"
    fill="none"
    aria-hidden="true"
    data-working={loading ? undefined : ""}
  >
    <path
      className="cv-spinner__arc"
      d="M8 2.75a5.25 5.25 0 1 1-4.55 2.63"
      stroke="currentColor"
      strokeWidth={strokeWidth}
      strokeLinecap="round"
    />
    {!loading && <circle className="cv-spinner__dot" cx="8" cy="8" r="3" />}
  </svg>
);

export const ArxivMark = ({ size = 16, className, style }: CvIconProps) => (
  <svg className={className} style={style} width={size} height={size} viewBox="0 0 16 16" aria-hidden="true">
    <path d="M3.2 2.2 12.8 13.8" stroke="#b31b1b" strokeWidth="2.2" strokeLinecap="round" />
    <path d="M12.6 2.4 3.4 13.6" stroke="#9a9a96" strokeWidth="1.6" strokeLinecap="round" />
    <path d="M3.2 2.2 8 8" stroke="#d64b3c" strokeWidth="1.4" strokeLinecap="round" />
  </svg>
);
