// Updates > App Update: Go Back to Previous Build. Leo (2026-11-21): "we ought to have good recovery
// and bisecting either automatically or agents being able to just say "actually let's go back to
// this other version :)" and/or the user should be able to easily access it too". The row names the
// build this Mac kept (number, day, commit) and takes the one rollback path the palette, the app
// menu and `cmux settings rollback-update` take; when that path would refuse, the button is off and
// the host's reason shows under it. Every text is the host's.
//
// Three looks for the pick (rulebook: more than two; settings.gallery `settings.previous-build`).
// Shipped: `row`, a row like every other Settings row: the build's identity in the help line, one
// quiet button on the trailing edge. `line` is a sentence under the status with an inline link (the
// quietest, and the easiest to miss on a bad day); `panel` gives the build a box of its own (the
// loudest, and a second card inside a card).
import { useState } from "react";
import { Button } from "../../../ui/Button";
import type { PreviousBuild } from "../ops";

export type PreviousBuildLook = "row" | "line" | "panel";

type Props = {
  previous: PreviousBuild;
  look?: PreviousBuildLook;
  /** Locks the button while another of the card's actions runs. */
  busy?: boolean;
  /** Runs the rollback; answers the host's refusal, else null (the app quits into the build). */
  onGoBack: (build: string) => Promise<string | null>;
};

/** The build's identity: "Build 3418 · 2026-11-20 · 1a2b3c4d", the commit linked when known. */
function Identity({ previous }: { previous: PreviousBuild }) {
  return (
    <>
      <span className="selectable" data-previous-build-number="">
        {previous.build_label}
      </span>
      {previous.date && ` · ${previous.date}`}
      {previous.commit && (
        <>
          {" · "}
          {previous.commit_url ? (
            <a href={previous.commit_url} className="channel-link font-mono" data-previous-build-commit="">
              {previous.commit}
            </a>
          ) : (
            <span className="font-mono">{previous.commit}</span>
          )}
        </>
      )}
    </>
  );
}

export function PreviousBuildRow({ previous, look = "row", busy = false, onGoBack }: Props) {
  const [running, setRunning] = useState(false);
  const [failure, setFailure] = useState<string | null>(null);
  const refused = previous.refusal !== null;
  const goBack = async () => {
    setRunning(true);
    setFailure(null);
    const why = await onGoBack(previous.build);
    // Success quits the app; a refusal brings the button back with the reason.
    setRunning(false);
    setFailure(why);
  };
  const note = previous.refusal ?? failure;
  const button = (
    <Button
      variant="subtle"
      type="button"
      className={look === "line" ? "button previous-build-link" : "button"}
      data-previous-build-go=""
      disabled={refused || running || busy}
      aria-describedby={note ? `previous-build-note-${previous.build}` : undefined}
      onClick={() => void goBack()}
    >
      {previous.action}
    </Button>
  );
  const reason = note && (
    <div className="row-error" id={`previous-build-note-${previous.build}`} data-previous-build-refusal="">
      {note}
    </div>
  );
  const attrs = {
    "data-previous-build": previous.build,
    "data-look": look,
    "data-refused": refused ? "" : undefined,
    "data-running": running ? "" : undefined,
  };
  if (look === "line") {
    return (
      <div className="row previous-build previous-build-line" {...attrs}>
        <div className="row-help">
          {previous.title}: <Identity previous={previous} /> {button}
        </div>
        {reason}
      </div>
    );
  }
  if (look === "panel") {
    return (
      <div className="row previous-build previous-build-panel" {...attrs}>
        <div className="previous-build-box">
          <div className="row-main">
            <div className="row-label">
              <div className="row-title">{previous.title}</div>
              <div className="previous-build-version selectable">{previous.version}</div>
              <div className="row-help">
                <Identity previous={previous} />
              </div>
              <div className="row-help">{previous.detail}</div>
            </div>
            <div className="row-control action-row-control">{button}</div>
          </div>
          {reason}
        </div>
      </div>
    );
  }
  return (
    <div className="row previous-build" tabIndex={-1} data-action-row="" {...attrs}>
      <div className="row-main">
        <div className="row-label">
          <div className="row-title">{previous.title}</div>
          <div className="row-help">
            <Identity previous={previous} />
          </div>
          {!refused && <div className="row-help">{previous.detail}</div>}
          {reason}
        </div>
        <div className="row-control action-row-control">{button}</div>
      </div>
    </div>
  );
}
