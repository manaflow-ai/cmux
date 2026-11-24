// Screens and panels the pane draws only after the person opens them: History, the context
// and harness pages, the inspector, a sandboxed run, and the background tasks panel. Each loads
// from its own chunk on first render, so the pane's first graph (pane.js and the chunks it
// preloads) does not parse them. The wrappers take the screens' own props; a screen that has not
// loaded yet draws nothing for the few milliseconds the local file takes. The stylesheets are
// part of pane.css whichever way the code loads.
import { lazy, Suspense, type ComponentProps } from "react";
import type { BackgroundTasksPanel as BackgroundTasksPanelScreen } from "./backgroundTasks/BackgroundTasksPanel";
import type { ContextScreen as ContextScreenScreen } from "./context/ContextScreen";
import type { HarnessesScreen as HarnessesScreenScreen } from "./harnesses/HarnessesScreen";
import type { Inspector as InspectorScreen } from "./Inspector";
import type { HistoryScreen as HistoryScreenScreen } from "./newtab/HistoryScreen";
import type { SandboxRunView as SandboxRunViewScreen } from "./SandboxRunView";

const BackgroundTasksPanelLoaded = lazy(() =>
  import("./backgroundTasks/BackgroundTasksPanel").then((module) => ({ default: module.BackgroundTasksPanel })),
);
const ContextScreenLoaded = lazy(() =>
  import("./context/ContextScreen").then((module) => ({ default: module.ContextScreen })),
);
const HarnessesScreenLoaded = lazy(() =>
  import("./harnesses/HarnessesScreen").then((module) => ({ default: module.HarnessesScreen })),
);
const InspectorLoaded = lazy(() => import("./Inspector").then((module) => ({ default: module.Inspector })));
const HistoryScreenLoaded = lazy(() =>
  import("./newtab/HistoryScreen").then((module) => ({ default: module.HistoryScreen })),
);
const SandboxRunViewLoaded = lazy(() =>
  import("./SandboxRunView").then((module) => ({ default: module.SandboxRunView })),
);

export function BackgroundTasksPanel(props: ComponentProps<typeof BackgroundTasksPanelScreen>) {
  return (
    <Suspense fallback={null}>
      <BackgroundTasksPanelLoaded {...props} />
    </Suspense>
  );
}

export function ContextScreen(props: ComponentProps<typeof ContextScreenScreen>) {
  return (
    <Suspense fallback={null}>
      <ContextScreenLoaded {...props} />
    </Suspense>
  );
}

export function HarnessesScreen(props: ComponentProps<typeof HarnessesScreenScreen>) {
  return (
    <Suspense fallback={null}>
      <HarnessesScreenLoaded {...props} />
    </Suspense>
  );
}

export function Inspector(props: ComponentProps<typeof InspectorScreen>) {
  return (
    <Suspense fallback={null}>
      <InspectorLoaded {...props} />
    </Suspense>
  );
}

export function HistoryScreen(props: ComponentProps<typeof HistoryScreenScreen>) {
  return (
    <Suspense fallback={null}>
      <HistoryScreenLoaded {...props} />
    </Suspense>
  );
}

export function SandboxRunView(props: ComponentProps<typeof SandboxRunViewScreen>) {
  return (
    <Suspense fallback={null}>
      <SandboxRunViewLoaded {...props} />
    </Suspense>
  );
}
