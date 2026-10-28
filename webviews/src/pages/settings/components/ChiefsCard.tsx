// Settings > Chief > Chiefs (u2586): every Chief (picture, name, role, backend, locked), each row
// opening the same editor Home shows (home-channels/ChiefPage.tsx), and New Chief. The card has
// no daemon connection of its own: it reads and writes through the host's page relay to the Chief
// owner (`cmux.chief.profile.*`) and the host's harness center (`cmux.chief.backend.*`), as Home's
// editor does; the person's click on Save, Undo or a backend is the gesture the host confirms.
// A Chief with no picture of its own wears the chosen pet character (`home.chiefPetMascot`, orb
// by default, whether or not the pet floats), as every other Chief surface does: never a letter.
// The Engine row (`home.chiefEngine`, Leo's list 89(3)) leads the card: which Chief Home opens,
// Auto (this Mac's optchat-chief while it runs, else Hosted; #64), This Mac or Hosted. Each
// Chief's own harness stays in its editor.
import { useCallback, useEffect, useMemo, useState } from "react";
import { ChiefPage } from "../../home-channels/ChiefPage";
import { ChiefHost, HostChiefEditor } from "../../home-channels/chiefEditing";
import { chiefEffortName, chiefModelName } from "../../home-channels/chiefNames";
import {
  chiefBackend,
  chiefBackendLabel,
  DEFAULT_CHIEF_BACKEND,
  type HomeChief,
  type HomeChiefBackend,
} from "../../home-channels/types";
import { formatString, type Strings } from "../../shared/i18n";
import { useRowState, useStore } from "../context";
import { rowsByKey } from "../schema";
import { locale, t } from "../strings";
import { CHIEF_PET_MASCOT, CHIEF_PET_MASCOTS } from "./ChiefPetCard";
import { SettingRow } from "./SettingRow";

export const CHIEF_ENGINE = "home.chiefEngine";
/** The rows this card draws in place of their group. */
export const CHIEFS_ROWS: ReadonlySet<string> = new Set([CHIEF_ENGINE]);

type Open = { kind: "new" } | { kind: "edit"; id: string } | null;

/** The Settings table as the editor's strings (the editor's keys come from the Home catalog). */
function settingsStrings(): Strings {
  return { language: locale(), t: (key) => t(key), format: (key, ...args) => formatString(t(key), args) };
}

/** A row's backend: the engine's name as Home's chip shows it (an absent or "default" harness
 * is the default engine), then its model and effort by name (chiefNames.ts: "Opus 5.5", "Extra
 * High"), never by id. The default engine with neither reads `chief.backend.default` ("Default
 * (Chief's usual)"), as the editor's backend picker does. */
function backendLine(chief: HomeChief, backends: readonly HomeChiefBackend[], strings: Strings): string {
  const engine = chief.engine;
  if (chiefBackend(engine?.harness) === DEFAULT_CHIEF_BACKEND && !engine?.model && !engine?.effort)
    return t("chief.backend.default");
  const models = backends.find((backend) => backend.id === chiefBackend(engine?.harness))?.models;
  return [
    chiefBackendLabel(t, engine?.harness),
    engine?.model && chiefModelName(engine.model, models, strings),
    engine?.effort && chiefEffortName(engine.effort, strings),
  ]
    .filter(Boolean)
    .join(" · ");
}

export function ChiefsCard({ focus = null }: { focus?: string | null }) {
  const store = useStore();
  const host = useMemo(() => new ChiefHost(store.chiefCalls), [store]);
  const strings = useMemo(settingsStrings, []);
  const character = useRowState(CHIEF_PET_MASCOT).value;
  const mascot = (CHIEF_PET_MASCOTS.find((entry) => entry.id === character) ?? CHIEF_PET_MASCOTS[0]!).art;
  const [chiefs, setChiefs] = useState<HomeChief[] | undefined>();
  const [pictures, setPictures] = useState<ReadonlyMap<string, string>>(new Map());
  const [unavailable, setUnavailable] = useState(false);
  // The harnesses' model catalogs, for the rows' model names; none yet (or none listed) reads ids.
  const [backends, setBackends] = useState<readonly HomeChiefBackend[]>([]);
  const [error, setError] = useState<string | undefined>();
  const [open, setOpen] = useState<Open>(null);
  const load = useCallback(async () => {
    try {
      const list = await host.list();
      setChiefs(list);
      setUnavailable(false);
      const read = await Promise.all(
        list
          .filter((chief) => chief.avatar)
          .map(async (chief) => [chief.id, await host.picture(chief.id).catch(() => null)] as const),
      );
      setPictures(
        new Map(
          read.flatMap(([id, picture]) =>
            picture ? [[id, `data:${picture.mediaType};base64,${picture.data}`] as const] : [],
          ),
        ),
      );
    } catch {
      setChiefs([]);
      setUnavailable(true);
    }
  }, [host]);
  useEffect(() => {
    void load();
  }, [load]);
  useEffect(() => {
    let live = true;
    host.backends().then(
      (list) => live && setBackends(list),
      () => undefined,
    );
    return () => {
      live = false;
    };
  }, [host]);
  const editor = useMemo(
    () =>
      new HostChiefEditor(
        host,
        (saved) => {
          setOpen(null);
          if (saved) void load();
        },
        setError,
      ),
    [host, load],
  );
  const editing = open?.kind === "edit" ? chiefs?.find((chief) => chief.id === open.id) : undefined;
  if (open && (open.kind === "new" || editing))
    return (
      <section className="group chiefs-card editing ui-glass" data-card="chiefs">
        <ChiefPage
          key={editing?.id ?? "new"}
          service={editor}
          strings={strings}
          chief={editing}
          picture={editing ? pictures.get(editing.id) : undefined}
          chiefName={(id) => chiefs?.find((chief) => chief.id === id)?.name}
        />
        {error && (
          <p className="row-error" role="alert">
            {error}
          </p>
        )}
      </section>
    );
  return (
    <section className="group chiefs-card ui-glass" data-card="chiefs">
      <div className="accounts-header">
        <h3 className="group-title m-0 flex-1">{t("chief.settings.title")}</h3>
        <button
          type="button"
          className="button"
          disabled={unavailable}
          onClick={() => {
            setError(undefined);
            setOpen({ kind: "new" });
          }}
        >
          {t("chief.settings.new")}
        </button>
      </div>
      <p className="row-help" data-intro="">
        {t(unavailable ? "chief.settings.unavailable" : "chief.settings.intro")}
      </p>
      <EngineRow focused={focus === CHIEF_ENGINE} />
      {chiefs && chiefs.length === 0 && !unavailable && <p className="row-help">{t("chief.settings.empty")}</p>}
      {chiefs && chiefs.length > 0 && (
        <div className="rows" data-chiefs="">
          {chiefs.map((chief) => (
            <button
              key={chief.id}
              type="button"
              className="row chiefs-row"
              data-chief={chief.id}
              onClick={() => {
                setError(undefined);
                setOpen({ kind: "edit", id: chief.id });
              }}
            >
              <span className="chiefs-picture" aria-hidden="true">
                <img
                  src={pictures.get(chief.id) ?? mascot}
                  alt=""
                  data-mascot={pictures.has(chief.id) ? undefined : ""}
                />
              </span>
              <span className="row-main">
                <span className="row-label">
                  <span className="row-title">{chief.name}</span>
                  {chief.role && <span className="row-help">{chief.role}</span>}
                </span>
              </span>
              <span className="row-help chiefs-backend">{backendLine(chief, backends, strings)}</span>
              {chief.locked && <span className="badge">{t("chief.settings.locked")}</span>}
            </button>
          ))}
        </div>
      )}
    </section>
  );
}

/** The Engine row, as the page's group list would draw it (a search result's `?focus=` reveals it). */
function EngineRow({ focused }: { focused: boolean }) {
  const row = rowsByKey.get(CHIEF_ENGINE);
  return row ? (
    <div className="rows" data-engine="">
      <SettingRow row={row} focused={focused} />
    </div>
  ) : null;
}
