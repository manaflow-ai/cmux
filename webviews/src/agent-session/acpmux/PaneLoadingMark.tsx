// A page still connecting, once the host's loading state gave up on it (App.tsx): the same spinner as
// the host's, after the same beat (AgentPaneLoadingView.markDelay), so a page that is about to draw
// shows no mark that pops up and goes (cmux#48605). The wait is one timer, never a CSS animation delay
// (the host's animations-off setting forces every delay to 0): it fires once, or is cleared when the
// page draws and this leaves. The status is announced all along; only the spinner waits.
import { useEffect, useState } from "react";
import { Spinner } from "./conversation/icons";

/// The host's beat before its loading spinner shows (AgentPaneLoadingView.markDelay).
const LATE_MS = 600;

export function PaneLoadingMark({ label }: { label: string }) {
  const [late, setLate] = useState(false);
  useEffect(() => {
    // timeout: a page that draws within the host's beat shows no spinner; cleared when it leaves.
    const timer = setTimeout(() => setLate(true), LATE_MS);
    return () => clearTimeout(timer);
  }, []);
  return (
    <output className="acpmux-pane-loading" aria-label={label}>
      {late && <Spinner size={20} loading />}
    </output>
  );
}
