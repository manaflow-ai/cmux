// Imported instead of react-dom/client ONLY by vite.config.latency.ts.
import { Profiler, type ReactNode, type ProfilerOnRenderCallback } from "react";
import { createRoot as createProfiledRoot, hydrateRoot as hydrateProfiledRoot } from "react-dom/profiling";
import type { Root, RootOptions, HydrationOptions } from "react-dom/client";

const counters = () => {
  const scope = window as Window & {
    __latencyReactCommits?: number;
    __latencyReactRootRenders?: number;
    /** The Profiler's actualDuration summed over every commit (the rail sweep's per-move React time). */
    __latencyReactActualMs?: number;
    __latencyReactProfile?: { source: string; phase: string; actualDuration: number; commitTime: number };
  };
  scope.__latencyReactCommits ??= 0;
  scope.__latencyReactRootRenders ??= 0;
  scope.__latencyReactActualMs ??= 0;
  return scope;
};

const committed: ProfilerOnRenderCallback = (_id, phase, actualDuration, _baseDuration, _startTime, commitTime) => {
  const scope = counters();
  scope.__latencyReactCommits! += 1;
  scope.__latencyReactActualMs! += actualDuration;
  scope.__latencyReactProfile = { source: "React.Profiler.onRender", phase, actualDuration, commitTime };
};

const profile = (children: ReactNode) => (
  <Profiler id="latency-root" onRender={committed}>
    {children}
  </Profiler>
);

function instrument(root: Root): Root {
  counters();
  return {
    render(children) {
      counters().__latencyReactRootRenders! += 1;
      root.render(profile(children));
    },
    unmount: () => root.unmount(),
  };
}

export function createRoot(container: Element | DocumentFragment, options?: RootOptions): Root {
  return instrument(createProfiledRoot(container, options));
}

export function hydrateRoot(container: Element | Document, children: ReactNode, options?: HydrationOptions): Root {
  return instrument(hydrateProfiledRoot(container, profile(children), options));
}
