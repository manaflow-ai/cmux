// l10n-allow-file: gallery labels are fixture content, not shipped UI.
// Every role of the Surface primitive on one sheet: the content roles (ask, card, pill) and the floating
// ones (popover, menu, hover card, tooltip, toast, sheet). Over the four backdrops (none, light, dark,
// busy) and in both appearances through scripts/gallery/capture-states.mjs (surface.capture.json): a
// surface reads at 4.5:1 over every one, and the ask card is the same material, corner, ring, type and
// buttons as the card beside it.
import { Keycap } from "../../agent-session/acpmux/Keycap";
import { componentEntry } from "../../gallery/format";
import { SURFACE_ROLES, Surface, surfaceMaterial, type SurfaceRole } from "./Surface";

type Props = { only?: SurfaceRole[] };

const Terminal = () => (
  <svg viewBox="0 0 16 16" fill="none" stroke="currentColor" strokeWidth="1.25" aria-hidden="true">
    <rect x="2" y="3" width="12" height="10" rx="2" />
    <path d="M5 7l2 1.5L5 10M8.5 10H11" strokeLinecap="round" strokeLinejoin="round" />
  </svg>
);

const COPY: Record<SurfaceRole, string> = {
  ask: "A prompt the agent waits on, in the transcript.",
  card: "A transcript, settings or sidebar card.",
  popover: "A picker or find bar beside what opened it.",
  menu: "A menu, context menu or dropdown.",
  hoverCard: "A preview that follows the pointer.",
  tooltip: "A label for one control.",
  toast: "Something that happened, briefly.",
  sheet: "A dialog or confirm over the window.",
  pill: "A short status or filter.",
};

function Specimen({ role }: { role: SurfaceRole }) {
  if (role === "ask")
    return (
      // oxlint-disable-next-line jsx-a11y/aria-role -- the Surface role, not an ARIA role
      <Surface as="fieldset" role="ask" aria-label="Confirm base unchanged for edited files">
        <Surface.Header icon={<Terminal />}>Confirm base unchanged for edited files</Surface.Header>
        <Surface.Body>
          <p>Bypass permissions doesn't cover this one. Allow once lets it run this time only.</p>
        </Surface.Body>
        <Surface.Inset mono>export ACPMUX_CALLER_SUBAGENT=general-purpose:ab7438a3bd69b229d</Surface.Inset>
        <Surface.Actions>
          <Surface.Action>
            Deny
            <Surface.Keys>
              <Keycap>N</Keycap>
              <Keycap>Esc</Keycap>
            </Surface.Keys>
          </Surface.Action>
          <Surface.Trailing>
            <Surface.Action kind="primary">
              Allow once
              <Surface.Keys>
                <Keycap>Y</Keycap>
                <Keycap>⌘</Keycap>
                <Keycap>↩</Keycap>
              </Surface.Keys>
            </Surface.Action>
          </Surface.Trailing>
        </Surface.Actions>
      </Surface>
    );
  if (role === "pill")
    return (
      // oxlint-disable-next-line jsx-a11y/aria-role -- the Surface role, not an ARIA role
      <Surface role="pill">
        <Surface.Header>main · 3 ahead</Surface.Header>
      </Surface>
    );
  if (role === "tooltip" || role === "menu")
    return (
      <Surface role={role}>
        <Surface.Body>{role === "menu" ? "Copy path" : "Run the checks"}</Surface.Body>
      </Surface>
    );
  const actions = role === "sheet" || role === "toast";
  return (
    <Surface role={role} aria-label={role}>
      <Surface.Header icon={<Terminal />}>{role === "toast" ? "Checks passed" : "Tokenizer fixes"}</Surface.Header>
      <Surface.Body>
        <p>{COPY[role]}</p>
      </Surface.Body>
      {actions && (
        <Surface.Actions>
          <Surface.Trailing>
            <Surface.Action>Dismiss</Surface.Action>
            <Surface.Action kind="primary">Open</Surface.Action>
          </Surface.Trailing>
        </Surface.Actions>
      )}
    </Surface>
  );
}

function SurfaceGallery({ only }: Props) {
  const roles = only ?? SURFACE_ROLES;
  return (
    <div className="ui-surface-stage" data-gallery-capture="">
      {roles.map((role) => (
        <figure key={role} className="ui-surface-cell" data-role={role}>
          <figcaption>
            {role} · {surfaceMaterial(role)}
          </figcaption>
          <Specimen role={role} />
        </figure>
      ))}
    </div>
  );
}

export default componentEntry<Props>({
  id: "ui.surface",
  title: "Surface",
  area: "UI primitives",
  height: 900,
  covers: ["ui/surface/Surface.tsx#Surface"],
  load: async () => SurfaceGallery,
  styles: () => Promise.all([import("../ui.css"), import("../glass/glass.css"), import("./surface.gallery.css")]),
  variants: {
    roles: { props: {}, note: "Every role: content (ask, card, pill) and floating (the rest)." },
    ask: {
      props: { only: ["ask", "card"] },
      note: "The ask card beside a card: one material, corner, ring, type and buttons.",
    },
    floating: { props: { only: ["popover", "menu", "hoverCard", "tooltip", "toast", "sheet"] } },
  },
});
