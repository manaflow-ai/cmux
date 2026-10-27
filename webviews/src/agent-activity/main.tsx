// DESKTOP-FEEL (R139): the shared desktop layer loads first.
import "../pages/shared/desktop";
import { useEffect, useLayoutEffect, useRef, useState } from "react";
import { createRoot } from "react-dom/client";
import { openPageState, restoredPageInputs } from "../pages/shared/pageState";
import {
  AGENT_ACTIVITY_PAGE,
  activityInputs,
  groups,
  initialActivityState,
  reduceActivity,
  restoredActivityInputs,
} from "./model";
import { activityPageClient, native } from "./native";
import "./styles.css";
import { ActivityView } from "./view";

// Before the first render: a restored document starts with the filter and layout it had.
const pageState = openPageState(activityPageClient, AGENT_ACTIVITY_PAGE);
const restored = restoredActivityInputs(restoredPageInputs(activityPageClient, AGENT_ACTIVITY_PAGE));

function App() {
  const [state, setState] = useState(() => ({ ...initialActivityState(), ...restored }));
  const [error, setError] = useState<string>();
  useEffect(() => {
    native.onState((raw) => setState((current) => reduceActivity(current, { type: "snapshot", state: raw })));
    native.request("ready").catch((e) => setError(String(e)));
    // The host follows the page's filter and layout; a restored page tells it the ones it came back with.
    if (restored.filter) void native.request("filter", { value: restored.filter }).catch(() => undefined);
    if (restored.layout) void native.request("layout", { value: restored.layout }).catch(() => undefined);
    return () => {
      delete (window as any).cmuxActivityReceive;
    };
  }, []);
  const latest = useRef(state);
  latest.current = state;
  // Saves on each hide; the scroll comes back from the first commit, before it paints.
  useLayoutEffect(() => pageState.keep(() => activityInputs(latest.current)), []);
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
    if (action.type === "filter") void native.request("filter", { value: action.value }).catch(() => undefined);
    if (action.type === "layout") void native.request("layout", { value: action.value }).catch(() => undefined);
  };
  return <ActivityView state={state} dispatch={dispatch} error={error} />;
}

(document.documentElement as HTMLElement).dataset.cmuxWebviewKind = "agent-activity";
createRoot(document.getElementById("root")!).render(<App />);
