// "Edit this view" (wow-20 idea 16, Labs: labs.editThisView): a button beside a section's title
// that opens the Customize chat with a request naming the section, its React source
// (webviews/src/pages/settings) and `cmux live start`, so the agent's edits show in this running
// page and end with Keep or Revert. Leo: "you should be able to just change your app."
import { Icon } from "../icons";
import { useRowState, useStore } from "../context";
import { t } from "../strings";

export const EDIT_THIS_VIEW_KEY = "labs.editThisView";

/** The gallery's three looks; `chip` ships. */
export type EditThisViewLook = "chip" | "icon" | "link";

export function EditThisViewButton({ look = "chip", onEdit }: { look?: EditThisViewLook; onEdit: () => void }) {
  const label = t("settingsPage.editThisView");
  return (
    <button
      type="button"
      className="edit-this-view"
      data-look={look}
      data-edit-this-view=""
      aria-label={label}
      title={look === "icon" ? label : undefined}
      onClick={onEdit}
    >
      <Icon name="wand.and.stars" />
      {look === "icon" ? null : <span>{label}</span>}
    </button>
  );
}

/** The section's title, with Edit this view beside it while the Labs switch is on. */
export function SectionTitle({ section, title }: { section: string; title: string }) {
  const store = useStore();
  const on = useRowState(EDIT_THIS_VIEW_KEY).value === true;
  if (!on) return <h1 className="section-title">{title}</h1>;
  return (
    <div className="section-head">
      <h1 className="section-title">{title}</h1>
      <EditThisViewButton onEdit={() => void store.editThisView(section, title)} />
    </div>
  );
}
