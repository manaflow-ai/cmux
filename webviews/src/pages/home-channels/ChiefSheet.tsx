// A Chief's profile: a new Chief (#/new/chief) or an edit (#/chief/<agent>/edit). The page changes
// a Chief's name, role and picture itself. Creating a Chief and changing its personality,
// instructions or grant (tools, harnesses) need the person's click, which the host relays (the
// app's page relay): in a plain browser those show read-only with "Do this in the cmux app".
// Instructions are added after cmux's base rules; they never replace them.
import { useRef, useState } from "react";
import type { Strings } from "../shared/i18n";
import { Avatar } from "./Avatar";
import { FormDialog } from "./FormDialog";
import { readPicture, type HomeSheets } from "./sheets";
import {
  CHIEF_HARNESSES,
  CHIEF_TOOLS,
  DEFAULT_CHIEF_TOOLS,
  type HomeChief,
  type HomeChiefGrant,
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
  const startGrant: HomeChiefGrant = {
    tools: chief ? chief.tools : [...DEFAULT_CHIEF_TOOLS],
    harnesses: chief ? chief.harnesses : [],
  };
  const [grant, setGrant] = useState<HomeChiefGrant>(startGrant);
  const [image, setImage] = useState<{ mediaType: string; data: string; url: string } | undefined>();
  const [imageError, setImageError] = useState<string | undefined>();
  const [busy, setBusy] = useState(false);
  const fileInput = useRef<HTMLInputElement | null>(null);
  // A new Chief is made only through the host; an edit saves what the page may change without it.
  const ready = profile.name.trim() !== "" && !busy && (grants || chief !== undefined);
  const locked = !grants;
  const same = (a: readonly string[], b: readonly string[]) => [...a].sort().join() === [...b].sort().join();
  const grantChanged = !same(grant.tools, startGrant.tools) || !same(grant.harnesses, startGrant.harnesses);
  const field = (key: keyof HomeChiefProfile) => (value: string) => setProfile((p) => ({ ...p, [key]: value }));
  const toggle = (key: keyof HomeChiefGrant, name: string) =>
    setGrant((g) => ({
      ...g,
      [key]: g[key].includes(name) ? g[key].filter((item) => item !== name) : [...g[key], name],
    }));
  const choose = async (file: File | undefined) => {
    if (!file) return;
    const read = await readPicture(file);
    if ("error" in read) {
      setImageError(t(read.error === "type" ? "chief.picture.type" : "chief.picture.size"));
      return;
    }
    setImageError(undefined);
    setImage({ ...read, url: `data:${read.mediaType};base64,${read.data}` });
  };
  const submit = () => {
    if (!ready) return;
    setBusy(true);
    const changed = grants && grantChanged ? grant : undefined;
    const done = chief
      ? sheets.updateChief(chief, profile, changed, image)
      : sheets.createChief(profile, changed, image).then(Boolean);
    void done.finally(() => setBusy(false));
  };
  const shownPicture = image?.url ?? picture;
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
      onSubmit={submit}
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
            {t(shownPicture ? "chief.picture.change" : "chief.picture.choose")}
          </button>
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
      </div>
      <label className="lg-form-field">
        <span className="lg-form-label">{t("chief.field.personality")}</span>
        <textarea
          className="hc-link-field lg-form-text"
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
              <input type="checkbox" checked={grant.tools.includes(tool)} onChange={() => toggle("tools", tool)} />
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
                checked={grant.harnesses.includes(harness)}
                onChange={() => toggle("harnesses", harness)}
              />
              <span>{harness}</span>
            </label>
          ))}
        </span>
        <span className="lg-form-note">{grants ? t("chief.harnesses.none") : t("chief.appOnly")}</span>
      </fieldset>
    </FormDialog>
  );
}
