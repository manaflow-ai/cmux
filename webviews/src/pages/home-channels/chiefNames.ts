// A Chief's backend as people say it, never by its raw id: a model by the name its harness's catalog
// gives it (`cmux.chief.backend.list`), else a name read off the id as the composer reads one
// ("claude-opus-5-5" is "Opus 5.5"), else the id itself; an effort by the composer's level names
// ("xhigh" is "Extra High").
import { modelIdName } from "../../agent-session/acpmux/defaultChoice";
import type { HomeChiefBackend } from "./types";

type Text = { t: (key: string) => string; format: (key: string, ...args: string[]) => string };

const EFFORTS = new Set(["low", "medium", "high", "xhigh", "max"]);

/** The model's name: the catalog's (when it is more than the id), else one read off the id. */
export function chiefModelName(id: string, models: HomeChiefBackend["models"] | undefined, text: Text): string {
  const listed = models?.find((model) => model.id === id)?.name;
  if (listed && listed !== id) return listed;
  return modelIdName(id, (_key, values) => text.format("chief.model.wideContext", String(values?.name ?? id)));
}

/** The effort's name: the level's own for a level the composer names, else the harness's word. */
export function chiefEffortName(effort: string, text: Pick<Text, "t">): string {
  return EFFORTS.has(effort) ? text.t(`chief.effort.${effort}`) : effort;
}
