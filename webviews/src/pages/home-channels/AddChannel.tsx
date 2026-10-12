// "Add channel": a popover at the rail row with the channel's name and its members (everyone the
// Home knows, me excluded). Create asks the owner for a titled group and opens it.
import { useState } from "react";
import { Popover } from "../../ui/Popover";
import type { Strings } from "../shared/i18n";
import { Avatar } from "./Avatar";
import type { HomeParticipant } from "./types";

export interface AddChannelProps {
  anchor: Element;
  people: readonly HomeParticipant[];
  strings: Strings;
  /** Resolves true when the owner created the channel. */
  onCreate(title: string, participants: string[]): Promise<boolean>;
  onClose(): void;
}

export function AddChannel({ anchor, people, strings, onCreate, onClose }: AddChannelProps) {
  const { t } = strings;
  const [title, setTitle] = useState("");
  const [members, setMembers] = useState<ReadonlySet<string>>(new Set());
  const [busy, setBusy] = useState(false);
  const ready = title.trim() !== "" && members.size > 0 && !busy;
  const toggle = (id: string) =>
    setMembers((current) => {
      const next = new Set(current);
      if (!next.delete(id)) next.add(id);
      return next;
    });
  return (
    <Popover
      open
      onOpenChange={(open) => {
        if (!open) onClose();
      }}
      anchor={anchor}
      side="inline-end"
      label={t("rail.addChannel")}
      className="hc-add-channel"
    >
      <form
        onSubmit={(event) => {
          event.preventDefault();
          if (!ready) return;
          setBusy(true);
          void onCreate(title, [...members]).then((created) => {
            setBusy(false);
            if (created) onClose();
          });
        }}
      >
        <h3 className="hc-add-title">{t("rail.addChannel")}</h3>
        <label className="hc-add-label">
          <span>{t("channel.name")}</span>
          <input
            className="hc-link-field"
            value={title}
            maxLength={80}
            placeholder={t("channel.namePlaceholder")}
            aria-label={t("channel.name")}
            onChange={(event) => setTitle(event.target.value)}
          />
        </label>
        <fieldset className="hc-add-members">
          <legend className="hc-add-label">{t("channel.members")}</legend>
          {people.map((person) => (
            <label key={person.id} className="hc-pick-row">
              <input
                type="checkbox"
                aria-label={person.name}
                checked={members.has(person.id)}
                onChange={() => toggle(person.id)}
              />
              <Avatar participant={person} size={20} />
              <span>{person.name}</span>
              {person.kind === "agent" && (
                <span className="hc-tag">{t(person.chief ? "chief.badge" : "agent.badge")}</span>
              )}
            </label>
          ))}
        </fieldset>
        <div className="hc-add-actions">
          <button type="button" className="hc-text-button" onClick={onClose}>
            {t("edit.cancel")}
          </button>
          <button type="submit" className="hc-text-button primary" disabled={!ready}>
            {t("channel.create")}
          </button>
        </div>
      </form>
    </Popover>
  );
}
