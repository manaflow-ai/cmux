// A Chief's editor as a page (u2586): New Chief (#/new/chief) and Edit Chief (#/chief/<agent>/edit)
// on the right side of Home, and the same component in Settings > Chief > Chiefs. Name, role and
// picture; personality and instructions; the backend (an acpmux harness, its model and effort, or
// one the person brings); the grant (tools, harnesses); the lock; and the record's history with
// Undo. Every write goes through `service` (chiefEditing.ts). Creating a Chief and the gesture
// fields need the person's click, which the host relays: without a host they show read-only with
// "Do this in the cmux app". Instructions are added after cmux's base rules; they never replace them.
import { useEffect, useId, useRef, useState, type FormEvent } from "react";
import type { Strings } from "../shared/i18n";
import { Avatar } from "./Avatar";
import { ChiefBackendPicker, type BackendCheck } from "./ChiefBackendPicker";
import { ChiefHistory } from "./ChiefHistory";
import { describeError, engineChange, type ChiefEditorService } from "./chiefEditing";
import {
  CENTERED,
  preparePicture,
  STILL_MAX_BYTES,
  withinPixels,
  type PictureCrop as Crop,
  type PreparedPicture,
} from "./picture";
import { PictureCrop } from "./PictureCrop";
import {
  CHIEF_HARNESSES,
  CHIEF_TOOLS,
  DEFAULT_CHIEF_TOOLS,
  type HomeChief,
  type HomeChiefEngine,
  type HomeChiefGrant,
  type HomeChiefGrantChange,
  type HomeChiefProfile,
} from "./types";
import "./chief-editor.css";

export interface ChiefPageProps {
  service: ChiefEditorService;
  strings: Strings;
  /** The Chief to edit; absent: a new Chief. */
  chief?: HomeChief;
  /** Its picture now (a data URL). */
  picture?: string;
  /** Names a Chief that made a revision (History: "who"). */
  chiefName?: (id: string) => string | undefined;
}

const profileOf = (chief?: HomeChief): HomeChiefProfile => ({
  name: chief?.name ?? "",
  role: chief?.role ?? "",
  personality: chief?.personality ?? "",
  instructions: chief?.instructions ?? "",
});
const engineOf = (chief?: HomeChief): HomeChiefEngine => ({
  harness: chief?.engine?.harness ?? "",
  model: chief?.engine?.model ?? "",
  effort: chief?.engine?.effort ?? "",
});
// What the page shows: the record's grant, or the owner's defaults for a new Chief. A record with
// no harness named means every harness, so every harness shows checked.
const grantOf = (chief?: HomeChief): HomeChiefGrant => ({
  tools: chief ? chief.tools : [...DEFAULT_CHIEF_TOOLS],
  harnesses: chief && chief.harnesses.length > 0 ? chief.harnesses : [...CHIEF_HARNESSES],
});
const same = (a: readonly string[], b: readonly string[]) => [...a].sort().join() === [...b].sort().join();

export function ChiefPage({ service, strings, chief: given, picture, chiefName }: ChiefPageProps) {
  const { t, format } = strings;
  const titleId = useId();
  // The record the editor started from; an Undo or Restore replaces it (and the fields).
  const [base, setBase] = useState<HomeChief | undefined>(given);
  const chief = base;
  const [profile, setProfile] = useState<HomeChiefProfile>(() => profileOf(given));
  const [grant, setGrant] = useState<HomeChiefGrant>(() => grantOf(given));
  const [engine, setEngine] = useState<HomeChiefEngine>(() => engineOf(given));
  const [locked, setLocked] = useState(given?.locked === true);
  // The backend check of the harness the person picked (a real hello turn before it is saved).
  const [check, setCheck] = useState<BackendCheck>({ state: "idle" });
  const [historyStamp, setHistoryStamp] = useState(0);
  // A GIF ready to send, null to go back to the default picture, undefined for no change.
  const [image, setImage] = useState<(PreparedPicture & { url: string }) | null | undefined>();
  // A still being placed in the circle; it is drawn at its crop when the page saves.
  const [placing, setPlacing] = useState<
    { file: File; url: string; size: { width: number; height: number } } | undefined
  >();
  const [crop, setCrop] = useState<Crop>(CENTERED);
  const [imageError, setImageError] = useState<string | undefined>();
  const [error, setError] = useState<string | undefined>();
  const [busy, setBusy] = useState(false);
  const fileInput = useRef<HTMLInputElement | null>(null);
  const first = useRef<HTMLInputElement | null>(null);
  useEffect(() => {
    first.current?.focus({ preventScroll: true });
  }, []);

  const grants = service.grants;
  const readOnly = !grants;
  const startGrant = grantOf(chief);
  // A Chief needs at least one harness to think: none checked is not a choice.
  const noHarness = grant.harnesses.length === 0;
  // Only the fields the person changed are sent; never an empty harness list.
  const grantChange: HomeChiefGrantChange = {
    ...(same(grant.tools, startGrant.tools) ? {} : { tools: grant.tools }),
    ...(same(grant.harnesses, startGrant.harnesses) ? {} : { harnesses: grant.harnesses }),
  };
  const engineChanged = engineChange(chief, engine);
  // A new harness is saved only after its check passed.
  const harnessWaits = engineChanged.harness !== undefined && engine.harness !== "" && check.state !== "passed";
  const ready = profile.name.trim() !== "" && !busy && (grants || chief !== undefined) && !noHarness && !harnessWaits;
  const field = (key: keyof HomeChiefProfile) => (value: string) => setProfile((p) => ({ ...p, [key]: value }));
  const toggle = (key: keyof HomeChiefGrant, name: string) =>
    setGrant((g) => ({
      ...g,
      [key]: g[key].includes(name) ? g[key].filter((item) => item !== name) : [...g[key], name],
    }));
  const refuse = (kind: "type" | "size" | "tooBig" | "pixels" | "unreadable") =>
    setImageError(
      t(
        {
          type: "chief.picture.type",
          size: "chief.picture.size",
          tooBig: "chief.picture.tooBig",
          pixels: "chief.picture.pixels",
          unreadable: "chief.picture.type",
        }[kind],
      ),
    );
  const choose = async (file: File | undefined) => {
    if (!file) return;
    setImageError(undefined);
    if (file.type !== "image/gif") {
      // A still is placed first and drawn when the page saves. Its bytes and pixels are checked
      // before the preview decodes it: a small file can decode to gigabytes.
      if (file.size > STILL_MAX_BYTES) return refuse("tooBig");
      const url = URL.createObjectURL(file);
      const size = await naturalSize(url);
      if (!size || !withinPixels(size)) {
        URL.revokeObjectURL(url);
        return refuse(size ? "pixels" : "unreadable");
      }
      setImage(undefined);
      setCrop(CENTERED);
      setPlacing({ file, url, size });
      return;
    }
    const read = await preparePicture(file, CENTERED, { width: 1, height: 1 });
    if ("error" in read) return refuse(read.error);
    setPlacing(undefined);
    setImage({ ...read, url: `data:${read.mediaType};base64,${read.data}` });
  };
  // The person picked a harness: check it now (a real hello turn), so Save stays in their click.
  const runCheck = (harness: string) => {
    if (!harness || harness === (chief?.engine?.harness ?? "")) return setCheck({ state: "idle" });
    setCheck({ state: "checking", harness });
    service.checkBackend(harness).then(
      (result) =>
        setCheck((now) =>
          now.state === "checking" && now.harness === harness
            ? result.ok
              ? { state: "passed", harness }
              : { state: "failed", harness, step: result.steps.find((step) => !step.ok) }
            : now,
        ),
      (failure: unknown) =>
        setCheck((now) =>
          now.state === "checking" && now.harness === harness
            ? { state: "failed", harness, step: { name: "doctor", ok: false, detail: describeError(failure) } }
            : now,
        ),
    );
  };
  const pickEngine = (next: HomeChiefEngine) => {
    if (next.harness !== engine.harness) runCheck(next.harness);
    setEngine(next);
  };
  // A backend the person brought passed its check: pick it (Save then writes it).
  const brought = (harness: string, model: string) => {
    setEngine({ harness, model, effort: "" });
    setCheck({ state: "passed", harness });
  };
  const submit = async (event?: FormEvent) => {
    event?.preventDefault();
    // Return in a Bring Your Own field adds that backend; it never saves the Chief. The click
    // runs in the same Return key event, so the host still sees the person's gesture.
    const byo = event?.currentTarget.querySelector("[data-chief-byo]");
    if (byo?.contains(document.activeElement)) {
      byo.querySelector<HTMLButtonElement>("[data-chief-byo-add]:not(:disabled)")?.click();
      return;
    }
    if (!ready) return;
    setBusy(true);
    setError(undefined);
    let sent = image === null ? null : image && { mediaType: image.mediaType, data: image.data };
    if (placing) {
      const drawn = await preparePicture(placing.file, crop, placing.size);
      if ("error" in drawn) {
        setBusy(false);
        return refuse(drawn.error);
      }
      sent = drawn;
    }
    const save = {
      profile,
      ...(grants && Object.keys(grantChange).length > 0 ? { grant: grantChange } : {}),
      ...(grants && Object.keys(engineChanged).length > 0 ? { engine: engineChanged } : {}),
      ...(grants && locked !== (chief?.locked === true) ? { locked } : {}),
      picture: sent,
    };
    const done = chief ? service.update(chief, save) : service.create(save);
    void done.finally(() => setBusy(false));
  };
  const reset = (record: HomeChief) => {
    setBase(record);
    setProfile(profileOf(record));
    setGrant(grantOf(record));
    setEngine(engineOf(record));
    setLocked(record.locked === true);
    setCheck({ state: "idle" });
    setImage(undefined);
    setPlacing(undefined);
    setHistoryStamp((n) => n + 1);
  };
  const undo = async (toRev?: number) => {
    if (!chief) return;
    setError(undefined);
    try {
      const record = await service.undo(chief, toRev);
      if (record) reset(record);
      else setHistoryStamp((n) => n + 1);
    } catch (failure) {
      setError(describeError(failure));
    }
  };
  const shownPicture = image === null ? undefined : (image?.url ?? picture);
  const lead =
    !chief && readOnly
      ? `${t("sheet.newChief.lead")} ${t("chief.appOnly")}`
      : t(chief ? "sheet.editChief.lead" : "sheet.newChief.lead");
  return (
    <section className="chief-editor" aria-labelledby={titleId} data-chief-page={chief ? "edit" : "new"}>
      <form className="ce-form" onSubmit={(event) => void submit(event)} aria-busy={busy || undefined}>
        <header className="ce-head">
          <button
            type="button"
            className="ce-icon-button"
            aria-label={t("chief.page.back")}
            onClick={() => service.close()}
          >
            <svg
              width="16"
              height="16"
              viewBox="0 0 20 20"
              fill="none"
              stroke="currentColor"
              strokeWidth="1.5"
              strokeLinecap="round"
              strokeLinejoin="round"
              aria-hidden="true"
              focusable="false"
            >
              <path d="M12.5 4.5 7 10l5.5 5.5" />
            </svg>
          </button>
          <div className="ce-head-text">
            <h1 id={titleId} className="ce-title">
              {chief ? format("sheet.editChief.title", chief.name) : t("sheet.newChief.title")}
            </h1>
            <p className="ce-lead">{lead}</p>
          </div>
        </header>
        <div className="ce-body">
          <div className="ce-identity lg-chief-identity">
            <span className="ce-picture">
              {shownPicture ? (
                <img src={shownPicture} alt={t("chief.field.picture")} />
              ) : (
                <Avatar participant={{ id: "", kind: "agent", name: profile.name || "?", chief: true }} size={56} />
              )}
            </span>
            <div className="ce-names">
              <label className="ce-field">
                <span className="ce-label">{t("chief.field.name")}</span>
                <input
                  ref={first}
                  className="ce-input"
                  aria-label={t("chief.field.name")}
                  value={profile.name}
                  maxLength={100}
                  required
                  disabled={!chief && readOnly}
                  placeholder={t("chief.field.namePlaceholder")}
                  onChange={(event) => field("name")(event.target.value)}
                />
              </label>
              <label className="ce-field">
                <span className="ce-label">{t("chief.field.role")}</span>
                <input
                  className="ce-input"
                  aria-label={t("chief.field.role")}
                  value={profile.role}
                  maxLength={200}
                  disabled={!chief && readOnly}
                  placeholder={t("chief.field.rolePlaceholder")}
                  onChange={(event) => field("role")(event.target.value)}
                />
              </label>
            </div>
          </div>
          <div className="ce-field">
            <span className="ce-label">{t("chief.field.picture")}</span>
            <span className="ce-row">
              <button
                type="button"
                className="ce-button"
                disabled={!chief && readOnly}
                onClick={() => fileInput.current?.click()}
              >
                {t(shownPicture || placing ? "chief.picture.change" : "chief.picture.choose")}
              </button>
              {(shownPicture || placing) && (
                <button
                  type="button"
                  className="ce-button"
                  disabled={!chief && readOnly}
                  onClick={() => {
                    setPlacing(undefined);
                    setImageError(undefined);
                    setImage(chief?.avatar ? null : undefined);
                  }}
                >
                  {t("chief.picture.useDefault")}
                </button>
              )}
              <input
                ref={fileInput}
                className="ce-hidden"
                type="file"
                accept="image/png,image/jpeg,image/gif,image/webp"
                aria-label={t("chief.field.picture")}
                onChange={(event) => void choose(event.target.files?.[0])}
              />
              {imageError && <span className="ce-error">{imageError}</span>}
            </span>
            {placing && (
              <PictureCrop
                url={placing.url}
                size={placing.size}
                crop={crop}
                onChange={setCrop}
                labels={{ zoom: t("chief.picture.zoom"), hint: t("chief.picture.cropHint") }}
              />
            )}
          </div>
          <label className="ce-field">
            <span className="ce-label">{t("chief.field.personality")}</span>
            <textarea
              className="ce-input ce-text"
              aria-label={t("chief.field.personality")}
              rows={2}
              maxLength={4000}
              disabled={readOnly}
              value={profile.personality}
              placeholder={t("chief.field.personalityPlaceholder")}
              onChange={(event) => field("personality")(event.target.value)}
            />
          </label>
          <label className="ce-field">
            <span className="ce-label">{t("chief.field.instructions")}</span>
            <textarea
              className="ce-input ce-text"
              aria-label={t("chief.field.instructions")}
              rows={5}
              maxLength={32000}
              disabled={readOnly}
              value={profile.instructions}
              onChange={(event) => field("instructions")(event.target.value)}
            />
            <span className="ce-note">
              {t("chief.field.instructionsNote")}
              {readOnly ? ` ${t("chief.appOnly")}` : ""}
            </span>
          </label>
          <ChiefBackendPicker
            service={service}
            strings={strings}
            engine={engine}
            disabled={readOnly}
            check={check}
            onChange={pickEngine}
            onRecheck={() => runCheck(engine.harness)}
            onBrought={brought}
          />
          <fieldset className="ce-field ce-grant lg-grant" disabled={readOnly}>
            <legend className="ce-label">{t("chief.field.tools")}</legend>
            <span className="ce-grant-items">
              {CHIEF_TOOLS.map((tool) => (
                <label key={tool} className="ce-grant-item">
                  <input
                    type="checkbox"
                    aria-label={t(`chief.tool.${tool}`)}
                    checked={grant.tools.includes(tool)}
                    onChange={() => toggle("tools", tool)}
                  />
                  <span>{t(`chief.tool.${tool}`)}</span>
                </label>
              ))}
            </span>
          </fieldset>
          <fieldset className="ce-field ce-grant lg-grant" disabled={readOnly}>
            <legend className="ce-label">{t("chief.field.harnesses")}</legend>
            <span className="ce-grant-items">
              {CHIEF_HARNESSES.map((harness) => (
                <label key={harness} className="ce-grant-item">
                  <input
                    type="checkbox"
                    aria-label={harness}
                    checked={grant.harnesses.includes(harness)}
                    onChange={() => toggle("harnesses", harness)}
                  />
                  <span>{harness}</span>
                </label>
              ))}
            </span>
            <span className={noHarness ? "ce-error" : "ce-note"}>
              {readOnly ? t("chief.appOnly") : noHarness ? t("chief.harnesses.pick") : ""}
            </span>
          </fieldset>
          <label className="ce-switch-row">
            <span className="ce-switch-text">
              <span className="ce-switch-title">{t("chief.lock.title")}</span>
              <span className="ce-note">{t("chief.lock.note")}</span>
            </span>
            <input
              type="checkbox"
              className="ce-switch"
              data-chief-lock=""
              aria-label={t("chief.lock.title")}
              checked={locked}
              disabled={readOnly}
              onChange={(event) => setLocked(event.target.checked)}
            />
          </label>
          {chief && (
            <ChiefHistory
              key={historyStamp}
              service={service}
              strings={strings}
              chief={chief}
              disabled={readOnly}
              chiefName={(id) => (id === chief.id ? chief.name : chiefName?.(id))}
              onUndo={(toRev) => void undo(toRev)}
            />
          )}
          {error && (
            <output className="ce-error selectable" role="alert">
              {error}
            </output>
          )}
        </div>
        <footer className="ce-actions lg-form-actions">
          {harnessWaits && check.state !== "failed" && <span className="ce-note">{t("chief.backend.needsCheck")}</span>}
          <button type="button" className="ce-button" onClick={() => service.close()}>
            {t("edit.cancel")}
          </button>
          <button type="submit" className="ce-button primary" disabled={!ready}>
            {t(chief ? "chief.save" : "chief.create")}
          </button>
        </footer>
      </form>
    </section>
  );
}

/** An image's pixel size, or null when the browser cannot decode it. */
function naturalSize(url: string): Promise<{ width: number; height: number } | null> {
  return new Promise((resolve) => {
    const image = new Image();
    image.onload = () =>
      resolve(image.naturalWidth > 0 ? { width: image.naturalWidth, height: image.naturalHeight } : null);
    image.onerror = () => resolve(null);
    image.src = url;
  });
}
