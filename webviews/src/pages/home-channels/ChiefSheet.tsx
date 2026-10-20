// A Chief's profile: a new Chief (#/new/chief) or an edit (#/chief/<agent>/edit). The page changes
// a Chief's name, role and picture itself. Creating a Chief and changing its personality,
// instructions or grant (tools, harnesses) need the person's click, which the host relays (the
// app's page relay): in a plain browser those show read-only with "Do this in the cmux app".
// Instructions are added after cmux's base rules; they never replace them.
import { useRef, useState } from "react";
import type { Strings } from "../shared/i18n";
import { Avatar } from "./Avatar";
import { FormDialog } from "./FormDialog";
import {
  CENTERED,
  preparePicture,
  STILL_MAX_BYTES,
  withinPixels,
  type PictureCrop as Crop,
  type PreparedPicture,
} from "./picture";
import { PictureCrop } from "./PictureCrop";
import type { HomeSheets } from "./sheets";
import {
  CHIEF_BACKENDS,
  CHIEF_HARNESSES,
  CHIEF_TOOLS,
  chiefBackend,
  chiefBackendLabel,
  DEFAULT_CHIEF_BACKEND,
  DEFAULT_CHIEF_TOOLS,
  type HomeChief,
  type HomeChiefGrant,
  type HomeChiefGrantChange,
  type HomeChiefProfile,
} from "./types";

export interface ChiefSheetProps {
  sheets: HomeSheets;
  strings: Strings;
  /** The Chief to edit; absent: a new Chief. */
  chief?: HomeChief;
  /** Its picture now (a data URL). */
  picture?: string;
  /** The host relays the person's click (create, personality, instructions, the grant). */
  grants: boolean;
}

export function ChiefSheet({ sheets, strings, chief, picture, grants }: ChiefSheetProps) {
  const { t, format } = strings;
  const [profile, setProfile] = useState<HomeChiefProfile>({
    name: chief?.name ?? "",
    role: chief?.role ?? "",
    personality: chief?.personality ?? "",
    instructions: chief?.instructions ?? "",
  });
  // What the sheet shows: the record's grant, or the owner's defaults for a new Chief. A record
  // with no harness named means every harness, so every harness shows checked.
  const startGrant: HomeChiefGrant = {
    tools: chief ? chief.tools : [...DEFAULT_CHIEF_TOOLS],
    harnesses: chief && chief.harnesses.length > 0 ? chief.harnesses : [...CHIEF_HARNESSES],
  };
  const [grant, setGrant] = useState<HomeChiefGrant>(startGrant);
  // The engine a new Chief starts on. An existing Chief's engine changes only in its settings in
  // the app (`cmux chief engine`), so the edit sheet shows it and does not send it.
  const [backend, setBackend] = useState<string>(DEFAULT_CHIEF_BACKEND);
  // A GIF ready to send, null to go back to the default picture, undefined for no change.
  const [image, setImage] = useState<(PreparedPicture & { url: string }) | null | undefined>();
  // A still being placed in the circle; it is drawn at its crop when the sheet saves.
  const [placing, setPlacing] = useState<
    { file: File; url: string; size: { width: number; height: number } } | undefined
  >();
  const [crop, setCrop] = useState<Crop>(CENTERED);
  const [imageError, setImageError] = useState<string | undefined>();
  const [busy, setBusy] = useState(false);
  const fileInput = useRef<HTMLInputElement | null>(null);
  // A new Chief is made only through the host; an edit saves what the page may change without it.
  // A Chief needs at least one harness to think: none checked is not a choice.
  const noHarness = grant.harnesses.length === 0;
  const ready = profile.name.trim() !== "" && !busy && (grants || chief !== undefined) && !noHarness;
  const locked = !grants;
  const same = (a: readonly string[], b: readonly string[]) => [...a].sort().join() === [...b].sort().join();
  // Only the fields the person changed are sent; never an empty harness list.
  const grantChange: HomeChiefGrantChange = {
    ...(same(grant.tools, startGrant.tools) ? {} : { tools: grant.tools }),
    ...(same(grant.harnesses, startGrant.harnesses) ? {} : { harnesses: grant.harnesses }),
  };
  const grantChanged = Object.keys(grantChange).length > 0;
  const field = (key: keyof HomeChiefProfile) => (value: string) => setProfile((p) => ({ ...p, [key]: value }));
  const toggle = (key: keyof HomeChiefGrant, name: string) =>
    setGrant((g) => ({
      ...g,
      [key]: g[key].includes(name) ? g[key].filter((item) => item !== name) : [...g[key], name],
    }));
  const refuse = (error: "type" | "size" | "tooBig" | "pixels" | "unreadable") =>
    setImageError(
      t(
        {
          type: "chief.picture.type",
          size: "chief.picture.size",
          tooBig: "chief.picture.tooBig",
          pixels: "chief.picture.pixels",
          unreadable: "chief.picture.type",
        }[error],
      ),
    );
  const choose = async (file: File | undefined) => {
    if (!file) return;
    setImageError(undefined);
    if (file.type !== "image/gif") {
      // A still is placed first and drawn when the sheet saves. Its bytes and pixels are checked
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
  const submit = async () => {
    if (!ready) return;
    setBusy(true);
    let sent = image === null ? null : image && { mediaType: image.mediaType, data: image.data };
    if (placing) {
      const drawn = await preparePicture(placing.file, crop, placing.size);
      if ("error" in drawn) {
        setBusy(false);
        return refuse(drawn.error);
      }
      sent = drawn;
    }
    const changed = grants && grantChanged ? grantChange : undefined;
    const done = chief
      ? sheets.updateChief(chief, profile, changed, sent)
      : sheets.createChief(profile, changed, sent ?? undefined, backend).then(Boolean);
    void done.finally(() => setBusy(false));
  };
  const shownPicture = image === null ? undefined : (image?.url ?? picture);
  return (
    <FormDialog
      wide
      title={chief ? format("sheet.editChief.title", chief.name) : t("sheet.newChief.title")}
      lead={
        !chief && locked
          ? `${t("sheet.newChief.lead")} ${t("chief.appOnly")}`
          : t(chief ? "sheet.editChief.lead" : "sheet.newChief.lead")
      }
      onClose={() => sheets.close()}
      onSubmit={() => void submit()}
      busy={busy}
      actions={
        <>
          <button type="button" className="hc-text-button" onClick={() => sheets.close()}>
            {t("edit.cancel")}
          </button>
          <button type="submit" className="hc-text-button primary" disabled={!ready}>
            {t(chief ? "chief.save" : "chief.create")}
          </button>
        </>
      }
    >
      <div className="lg-chief-identity">
        <span className="lg-chief-picture">
          {shownPicture ? (
            <img src={shownPicture} alt={t("chief.field.picture")} />
          ) : (
            <Avatar participant={{ id: "", kind: "agent", name: profile.name || "?", chief: true }} size={56} />
          )}
        </span>
        <div className="lg-chief-names">
          <label className="lg-form-field">
            <span className="lg-form-label">{t("chief.field.name")}</span>
            <input
              className="hc-link-field"
              aria-label={t("chief.field.name")}
              value={profile.name}
              maxLength={100}
              required
              disabled={!chief && locked}
              placeholder={t("chief.field.namePlaceholder")}
              onChange={(event) => field("name")(event.target.value)}
            />
          </label>
          <label className="lg-form-field">
            <span className="lg-form-label">{t("chief.field.role")}</span>
            <input
              className="hc-link-field"
              aria-label={t("chief.field.role")}
              value={profile.role}
              maxLength={200}
              disabled={!chief && locked}
              placeholder={t("chief.field.rolePlaceholder")}
              onChange={(event) => field("role")(event.target.value)}
            />
          </label>
        </div>
      </div>
      <div className="lg-form-field">
        <span className="lg-form-label">{t("chief.field.picture")}</span>
        <span className="lg-form-row">
          <button
            type="button"
            className="hc-text-button"
            disabled={!chief && locked}
            onClick={() => fileInput.current?.click()}
          >
            {t(shownPicture || placing ? "chief.picture.change" : "chief.picture.choose")}
          </button>
          {(shownPicture || placing) && (
            <button
              type="button"
              className="hc-text-button"
              disabled={!chief && locked}
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
            className="lg-hidden-file"
            type="file"
            accept="image/png,image/jpeg,image/gif,image/webp"
            aria-label={t("chief.field.picture")}
            onChange={(event) => void choose(event.target.files?.[0])}
          />
          {imageError && <span className="lg-form-error">{imageError}</span>}
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
      {chief ? (
        <div className="lg-form-field">
          <span className="lg-form-label">{t("chief.field.backend")}</span>
          <span className="lg-chief-backend">{chiefBackendLabel(t, chief.engine?.harness)}</span>
          <span className="lg-form-note">{t("chief.backend.changeInSettings")}</span>
        </div>
      ) : (
        <label className="lg-form-field">
          <span className="lg-form-label">{t("chief.field.backend")}</span>
          <select
            className="hc-link-field lg-chief-backend-select"
            aria-label={t("chief.field.backend")}
            value={backend}
            disabled={locked}
            onChange={(event) => setBackend(event.target.value)}
          >
            {CHIEF_BACKENDS.map((option) => (
              <option key={option.id} value={option.id}>
                {t(option.label)}
              </option>
            ))}
          </select>
          {chiefBackend(backend) === "unii" && (
            <span className="lg-form-note">
              {/* The command stays as typed in every language: the catalog holds its place, %@. */}
              {t("chief.backend.uniiNote")
                .split("%@")
                .flatMap((part, index) => (index === 0 ? [part] : [<code key={index}>unii login</code>, part]))}
            </span>
          )}
        </label>
      )}
      <label className="lg-form-field">
        <span className="lg-form-label">{t("chief.field.personality")}</span>
        <textarea
          className="hc-link-field lg-form-text"
          aria-label={t("chief.field.personality")}
          rows={2}
          maxLength={4000}
          disabled={locked}
          value={profile.personality}
          placeholder={t("chief.field.personalityPlaceholder")}
          onChange={(event) => field("personality")(event.target.value)}
        />
      </label>
      <label className="lg-form-field">
        <span className="lg-form-label">{t("chief.field.instructions")}</span>
        <textarea
          className="hc-link-field lg-form-text"
          aria-label={t("chief.field.instructions")}
          rows={4}
          maxLength={32000}
          disabled={locked}
          value={profile.instructions}
          onChange={(event) => field("instructions")(event.target.value)}
        />
        <span className="lg-form-note">
          {t("chief.field.instructionsNote")}
          {locked ? ` ${t("chief.appOnly")}` : ""}
        </span>
      </label>
      <fieldset className="lg-form-field lg-grant" disabled={!grants}>
        <legend className="lg-form-label">{t("chief.field.tools")}</legend>
        <span className="lg-grant-items">
          {CHIEF_TOOLS.map((tool) => (
            <label key={tool} className="lg-grant-item">
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
      <fieldset className="lg-form-field lg-grant" disabled={!grants}>
        <legend className="lg-form-label">{t("chief.field.harnesses")}</legend>
        <span className="lg-grant-items">
          {CHIEF_HARNESSES.map((harness) => (
            <label key={harness} className="lg-grant-item">
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
        <span className={noHarness ? "lg-form-error" : "lg-form-note"}>
          {!grants ? t("chief.appOnly") : noHarness ? t("chief.harnesses.pick") : ""}
        </span>
      </fieldset>
    </FormDialog>
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
