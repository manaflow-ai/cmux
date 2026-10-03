// The rejected hunks not yet sent, with an optional note, go to the agent as one prompt.
import React, { useState } from "react";
import { rejectionPrompt, type TurnFile } from "../diff";
import { rejectedHunks, type HunkReview } from "./hunkReview";

/// After a send the bar goes away with the control that had focus; `onSent` places focus again.
export function RevertBar({ files, review, onSent }: { files: TurnFile[]; review: HunkReview; onSent: () => void }) {
  const [note, setNote] = useState("");
  const rejected = rejectedHunks(files, review.decisions);
  if (rejected.length === 0) return null;
  const send = () => {
    review.requestRevert(
      rejected.map((entry) => entry.key),
      rejectionPrompt(
        rejected.map((entry) => entry.patch),
        note,
      ),
    );
    setNote("");
    onSent();
  };
  return (
    <div className="acpmux-revert-bar">
      <span className="acpmux-revert-count">
        {rejected.length === 1 ? "1 change rejected" : `${rejected.length} changes rejected`}
      </span>
      <input
        aria-label="Note for the agent"
        placeholder="Add a note (optional)"
        value={note}
        onChange={(event) => setNote(event.target.value)}
        onKeyDown={(event) => {
          // Enter sends without also pressing whatever takes focus after the send.
          if (event.key === "Enter" && !event.nativeEvent.isComposing) {
            event.preventDefault();
            send();
          }
        }}
      />
      <button type="button" className="acpmux-revert-send" onClick={send}>
        Ask agent to revert
      </button>
    </div>
  );
}
