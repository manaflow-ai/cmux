import { useState } from "react";
import { Button } from "../../../ui/Button";
import { Select } from "../../../ui/Select";
import { useT } from "../i18n";
import type { ShareRole, ShareView } from "./shareState";

/** Explicit team grants alongside the unchanged bearer-link and named-person controls.
 * The native host confirms the selected team and role before requesting a scoped token. */
export function ShareTeams({
  view,
  busy,
  onTeam,
  onRemove,
  onCopy,
}: {
  view: ShareView;
  busy: boolean;
  onTeam?(teamId: string, role: ShareRole): void;
  onRemove?(shareId: string): void;
  onCopy?(url: string): void;
}) {
  const t = useT();
  const [selected, setSelected] = useState("");
  const [role, setRole] = useState<ShareRole>("view");
  const active = new Set(view.teamShares.map((share) => share.teamId));
  const available = view.teams.filter((team) => !active.has(team.id));
  // Never silently retarget a selection when the signed-in account/team list changes.
  const teamId = available.some((team) => team.id === selected) ? selected : "";
  if (view.teams.length === 0 && view.teamShares.length === 0) return null;
  const roles = [
    { value: "view", label: t("share.role.view") },
    { value: "talk", label: t("share.role.talk") },
  ];
  return (
    <section className="share-dialog__section" aria-label={t("share.teamAccess")}>
      <h3 className="share-dialog__heading">{t("share.teamAccess")}</h3>
      {available.length > 0 && (
        <div className="share-dialog__add share-dialog__team-add">
          <Select
            className="share-dialog__field"
            label={t("share.team")}
            placeholder={t("share.team")}
            value={teamId}
            options={available.map((team) => ({ value: team.id, label: team.name }))}
            disabled={busy}
            closeOnPick
            onChange={setSelected}
          />
          <Select
            label={t("share.roleFor")}
            value={role}
            options={roles}
            disabled={busy}
            closeOnPick
            onChange={(value) => setRole(value as ShareRole)}
          />
          <Button disabled={busy || !teamId || !onTeam} onClick={() => onTeam?.(teamId, role)}>
            {t("share.invite")}
          </Button>
        </div>
      )}
      <p className="share-dialog__hint">{t("share.teamHint")}</p>
      {view.teamShares.length > 0 && (
        <ul className="share-dialog__teams">
          {view.teamShares.map((share) => (
            <li className="share-dialog__person" key={share.shareId}>
              <span className="share-dialog__who">
                <span className="share-dialog__name">
                  {view.teams.find((team) => team.id === share.teamId)?.name ?? share.teamId}
                </span>
                <span className="share-dialog__hint">{roles.find((item) => item.value === share.role)?.label}</span>
              </span>
              <Button
                variant="subtle"
                disabled={busy || !share.inviteUrl || !onCopy}
                onClick={() => share.inviteUrl && onCopy?.(share.inviteUrl)}
              >
                {t("share.copyLink")}
              </Button>
              <Button variant="ghost" danger disabled={busy || !onRemove} onClick={() => onRemove?.(share.shareId)}>
                {t("share.remove")}
              </Button>
            </li>
          ))}
        </ul>
      )}
    </section>
  );
}
