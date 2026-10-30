// DESKTOP-FEEL (R139): the shared desktop layer loads first.
import "../pages/shared/desktop";
import { useEffect, useState } from "react";
import { createRoot } from "react-dom/client";
import { groups, initialActivityState, reduceActivity } from "./model";
import { native } from "./native";
import "../ui/ui.css";
import "./styles.css";
import { ActivityView } from "./view";

function App() {
  const [state, setState] = useState(initialActivityState);
  const [error, setError] = useState<string>();
  useEffect(() => {
    native.onState((raw) => setState((current) => reduceActivity(current, { type: "snapshot", state: raw })));
    native.request("ready").catch((e) => setError(String(e)));
    return () => {
      delete (window as any).cmuxActivityReceive;
    };
  }, []);
  const followIDs =
    state.layout === "split"
      ? state.selectedSessionID
        ? [state.selectedSessionID]
        : []
      : groups(state)
          .flatMap((group) => group.sessions)
          .map((session) => session.id);
  const followKey = followIDs.join(",");
  useEffect(() => {
    const ids = followKey ? followKey.split(",") : [];
    void native.request("follow", { ids }).catch(() => undefined);
  }, [followKey]);
  const dispatch = (action: any) => {
    setState((s) => reduceActivity(s, action));
    if (action.type === "select") void native.request("select", { id: action.id }).catch(() => undefined);
    if (action.type === "scrub") void native.request("scrub", { seq: action.seq ?? null }).catch(() => undefined);
    // A frame opened from the timeline or grid: its session and that frame, in one request.
    if (action.type === "open")
      void native.request("open", { id: action.id, seq: action.seq ?? null }).catch(() => undefined);
    if (action.type === "filter") void native.request("filter", { value: action.value }).catch(() => undefined);
    if (action.type === "layout") void native.request("layout", { value: action.value }).catch(() => undefined);
  };
  return <ActivityView state={state} dispatch={dispatch} error={error} />;
}

(document.documentElement as HTMLElement).dataset.cmuxWebviewKind = "agent-activity";
createRoot(document.getElementById("root")!).render(<App />);
