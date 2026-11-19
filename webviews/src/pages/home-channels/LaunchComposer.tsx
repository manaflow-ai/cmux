// Home's composer before the page knows which conversation it writes to: while the daemon and the
// Chief's owner connect (DaemonGate) and while the first inbox loads (HomeChannelsPage). The person
// can type at once; what they type, and whether the field has the focus, go to the conversation the
// page opens (`OpenComposer`), so the field they typed in stays where it was with the same text.
// Nothing is sent from here: Return keeps the text until a conversation takes it.
import { useEffect, useRef, useState, type ReactNode } from "react";
import type { Strings } from "../shared/i18n";
import { Composer, type ComposerProps } from "./Composer";

/** The text typed before a conversation opened, and whether its field had the focus. */
const launch = { text: "", focused: false };

/** The page has painted once: the composer's editor is not part of the page's first frame (its first
 *  contentful paint stays the frame's), and from then on every launch composer draws at once. */
let painted = false;

/** Takes what the launch composer holds, once: the next conversation's composer starts with it. */
function takeLaunchDraft(): { text: string; focused: boolean } {
  const taken = { ...launch };
  launch.text = "";
  launch.focused = false;
  return taken;
}

/** The main column while no conversation is open yet: the header's and the timeline's places, held at
 *  their sizes, and the composer where the open conversation's composer goes. `note` is the header's
 *  one muted line (a connect that lasts). */
export function LaunchMain({ strings, note }: { strings: Strings; note?: ReactNode }) {
  const { t, format } = strings;
  const field = useRef<HTMLDivElement>(null);
  // Read once: a second launch composer (the page after the gate's) carries on with the same text.
  const [start] = useState(() => ({ ...launch }));
  const [ready, setReady] = useState(painted);
  useEffect(() => {
    if (ready) return;
    // After the first frame paints (a task after its animation frame), the editor mounts.
    let timer: ReturnType<typeof setTimeout> | undefined;
    const frame = requestAnimationFrame(() => {
      timer = setTimeout(() => {
        painted = true;
        setReady(true);
      }, 0);
    });
    return () => {
      cancelAnimationFrame(frame);
      clearTimeout(timer);
    };
  }, [ready]);
  return (
    <>
      <header className="lg-header lg-header-pending" aria-busy="true">
        {note}
      </header>
      <div className="lg-stage">
        <div className="lg-stage-pending" />
        <div
          className="lg-main-compose"
          ref={field}
          onFocus={() => (launch.focused = true)}
          onBlur={(event) => {
            // A blur to somewhere else on the page drops the focus; the field leaving the document
            // (the conversation's composer takes its place) keeps it.
            const next = event.relatedTarget;
            if (next && !field.current?.contains(next as Node)) launch.focused = false;
            else
              queueMicrotask(() => {
                if (field.current?.isConnected && !field.current.contains(document.activeElement))
                  launch.focused = false;
              });
          }}
        >
          {ready && (
            <Composer
              strings={strings}
              placeholder={format("composer.placeholder", t("page.title"))}
              label={format("composer.placeholder", t("page.title"))}
              initialValue={start.text}
              focusOnOpen={start.focused}
              onValueChange={(text) => (launch.text = text)}
              onSend={() => Promise.resolve(false)}
            />
          )}
        </div>
      </div>
    </>
  );
}

/** The open conversation's composer: the first one after launch starts with what was typed there. */
export function OpenComposer(props: ComposerProps) {
  const [start] = useState(takeLaunchDraft);
  return (
    <Composer
      {...props}
      initialValue={start.text || props.initialValue}
      focusOnOpen={start.focused || props.focusOnOpen}
    />
  );
}
