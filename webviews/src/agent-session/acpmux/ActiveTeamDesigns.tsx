// l10n-allow-file: gallery-only design study (sample names and copy), not shipped UI.
// Ways to make the active team obvious (Leo, 2026-11-09: "i guess is team? it's kinda hard to
// realize tho"; "but does this not mean it's already connected?"; "what is this?"). Each design
// draws the account menu, Switch Active Team and the Cloud row with the same team data; the menu
// and the palette are native, so they are drawn here as their shape, with the real TeamTag for the
// web surfaces. `list` is the one that ships.
import { Icon } from "./icons/Icon";
import { TeamTag, teamIconName, type ActiveTeamTag } from "./TeamTag";

export type ActiveTeamDesign = "list" | "submenu" | "header" | "badge";

type Team = ActiveTeamTag & { id: string; detail: string };

const TEAMS: Team[] = [
  { id: "cmux", name: "cmux", personal: false, detail: "Team · Team plan" },
  { id: "dup", name: "leo@example.com's Team", personal: false, detail: "Team" },
  { id: "personal", name: "Personal", personal: true, detail: "leo@example.com" },
];
const ACTIVE = "cmux";

function Check({ on }: { on: boolean }) {
  return <span className="atd-check">{on ? "✓" : ""}</span>;
}

function TeamMenuRow({ team, detail = true }: { team: Team; detail?: boolean }) {
  return (
    <div className="atd-row" data-team={team.id}>
      <Check on={team.id === ACTIVE} />
      <Icon name={teamIconName(team)} size={14} />
      <span className="atd-text">
        <span>{team.name}</span>
        {detail && <span className="atd-detail">{team.detail}</span>}
      </span>
    </div>
  );
}

function Person() {
  return (
    <div className="atd-row" data-person="">
      <Check on={false} />
      <span className="atd-avatar">L</span>
      <span className="atd-text">
        <span>Leo</span>
        <span className="atd-detail">leo@example.com</span>
      </span>
    </div>
  );
}

function AccountMenu({ design }: { design: ActiveTeamDesign }) {
  const active = TEAMS.find((team) => team.id === ACTIVE)!;
  return (
    <div className="atd-menu" aria-label="Account menu">
      <Person />
      <div className="atd-sep" />
      {design === "list" && TEAMS.map((team) => <TeamMenuRow key={team.id} team={team} />)}
      {design === "submenu" && (
        <div className="atd-row">
          <Check on={false} />
          <Icon name={teamIconName(active)} size={14} />
          <span className="atd-text">
            <span>Team: {active.name}</span>
          </span>
          <span className="atd-chevron">›</span>
        </div>
      )}
      {design === "header" && (
        <>
          <div className="atd-section">Team</div>
          {TEAMS.map((team) => (
            <TeamMenuRow key={team.id} team={team} detail={false} />
          ))}
        </>
      )}
      {design === "badge" &&
        TEAMS.map((team) => (
          <div className="atd-row" key={team.id}>
            <Check on={team.id === ACTIVE} />
            <Icon name={teamIconName(team)} size={14} />
            <span className="atd-text">
              <span>{team.name}</span>
            </span>
            {team.id === ACTIVE && <span className="atd-badge">Active</span>}
          </div>
        ))}
      <div className="atd-sep" />
      <div className="atd-row atd-muted">
        <Check on={false} />
        <span className="atd-text">Default profile ›</span>
      </div>
    </div>
  );
}

function Palette() {
  return (
    <div className="atd-palette" aria-label="Switch Active Team">
      <div className="atd-palette-title">Switch Active Team · Choose Team…</div>
      {TEAMS.map((team) => (
        <div className="atd-palette-row" key={team.id}>
          <Icon name={teamIconName(team)} size={16} />
          <span className="atd-text">
            <span>{team.name}</span>
            <span className="atd-detail">{team.detail}</span>
          </span>
          <span className="atd-accessory">{team.id === ACTIVE ? "✓" : ""}</span>
        </div>
      ))}
    </div>
  );
}

function CloudSurfaces() {
  const active = TEAMS.find((team) => team.id === ACTIVE)!;
  return (
    <div className="atd-cloud">
      <div className="atd-cloud-row">
        <span>Cloud</span>
        <TeamTag team={active} />
        <span className="atd-check">{"✓"}</span>
      </div>
      <div className="atd-machines-header">
        Cloud <TeamTag team={active} />
      </div>
    </div>
  );
}

export function ActiveTeamDesigns({ design }: { design: ActiveTeamDesign }) {
  return (
    <div className="atd" data-design={design}>
      <AccountMenu design={design} />
      <Palette />
      <CloudSurfaces />
    </div>
  );
}
