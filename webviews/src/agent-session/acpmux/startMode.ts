import { useEffect, useState } from "react";

/// The permission mode acpmux would start a new chat on a harness in (`_acpmux/start_mode`,
/// hub/start_mode.rs, cx-wx93i): the mode id, and its name when acpmux knows it. acpmux alone
/// decides it (the latest pick, a preset, a profile that pins its mode, the settings); the pane
/// only asks, and names no mode until it has an answer.
export type StartMode = { modeId: string; name?: string };

/// Asks the connected acpmux; undefined when it sets no mode, cannot know, or predates the method.
export type AskStartMode = (harness: string, cwd?: string) => Promise<StartMode | undefined>;

let ask: AskStartMode | undefined;
const listeners = new Set<() => void>();

/// The pane's connected client answers (direct.ts `startMode`); none while disconnected. A chip
/// drawn before the client connected asks once it does.
export function setStartModeSource(next: AskStartMode | undefined): void {
  if (ask === next) return;
  ask = next;
  for (const listener of listeners) listener();
}

/// The answer for a new chat on `harness` in `cwd`, asked when `enabled` turns on or either
/// changes; undefined until it arrives, and when acpmux gives none.
export function useStartMode(harness: string | undefined, cwd: string | undefined, enabled: boolean) {
  const [answer, setAnswer] = useState<{ key: string; mode?: StartMode }>();
  const [source, setSource] = useState(() => ask);
  useEffect(() => {
    const listener = () => setSource(() => ask);
    listeners.add(listener);
    listener();
    return () => void listeners.delete(listener);
  }, []);
  const key = enabled && harness ? `${harness}\u0000${cwd ?? ""}` : undefined;
  useEffect(() => {
    if (!key || !harness || !source) return;
    let live = true;
    void source(harness, cwd).then(
      (mode) => live && setAnswer({ key, mode }),
      () => undefined,
    );
    return () => {
      live = false;
    };
  }, [key, harness, cwd, source]);
  return answer && answer.key === key ? answer.mode : undefined;
}
