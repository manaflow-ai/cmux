import { useRef, useState } from "react";
import { Icon } from "../icons/Icon";
import { Popover } from "../../../ui/Popover";
import { usePopoverTrigger } from "../../../ui/popoverTrigger";
import type { AcpmuxOverlap } from "../model";

/// A quiet header signal for a durable acpmux `worktree_overlap` event. The button stays compact;
/// the file and hunk detail, merge order, and one-line handoff live in its popover.
export function OverlapChip({
  overlap,
  onTell,
}: {
  overlap: AcpmuxOverlap;
  onTell?: (overlap: AcpmuxOverlap) => Promise<unknown> | void;
}) {
  const [open, setOpen] = useState(false);
  const [sent, setSent] = useState(false);
  const [failed, setFailed] = useState(false);
  const [button, setButton] = useState<HTMLButtonElement | null>(null);
  const buttonRef = useRef<HTMLButtonElement | null>(null);
  const trigger = usePopoverTrigger(open, setOpen);
  const label = `Overlaps with ${overlap.peerName}`;
  const tell = () => {
    if (!onTell) return;
    setFailed(false);
    Promise.resolve(onTell(overlap)).then(
      () => setSent(true),
      () => setFailed(true),
    );
  };
  return (
    <>
      <button
        ref={(element) => {
          buttonRef.current = element;
          setButton(element);
        }}
        type="button"
        className="acpmux-header-tool acpmux-header-overlap"
        aria-label={label}
        aria-haspopup="dialog"
        aria-expanded={open}
        {...trigger}
      >
        <Icon name="git.worktree" size={14} />
        <span className="acpmux-header-overlap-name">{label}</span>
      </button>
      <Popover
        open={open}
        onOpenChange={(next) => {
          if (!next) setOpen(false);
        }}
        anchor={button}
        label={label}
        className="acpmux-pr-status acpmux-overlap-status"
        side="bottom"
        finalFocus={buttonRef}
      >
        <div className="acpmux-pr-title">{label}</div>
        <div className="acpmux-pr-facts">
          Finish{" "}
          {overlap.smallerSessionId === overlap.peerSessionId
            ? overlap.peerName
            : "the smaller change"}{" "}
          first to keep the merge simple.
        </div>
        <ul className="acpmux-overlap-files">
          {overlap.files.map((file) => (
            <li key={`${file.repo}\0${file.path}`}>
              <code>{file.path}</code>
              <span>
                {file.ranges
                  .map((range) => `${range.mine.start}-${range.mine.end}`)
                  .join(", ")}
              </span>
            </li>
          ))}
        </ul>
        {onTell && (
          <div className="acpmux-overlap-action">
            <button type="button" onClick={tell} disabled={sent}>
              {sent ? "Told the other agent" : "Tell the other agent"}
            </button>
            {failed && <output role="alert">Could not send the note.</output>}
          </div>
        )}
      </Popover>
    </>
  );
}
