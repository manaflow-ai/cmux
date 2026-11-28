// l10n-allow-file: gallery fixtures, not shipped UI.
import type { ReactNode } from "react";
import { Icon } from "./Icon";
import { ICON_STROKE, ROW_VIEWBOX } from "./iconSize";

/**
 * The icon audit's hill-climb backlog (2026-11-22). Leo: "go look for good icons while you're at it.
 * customize and design our own if we want. like, we can hill climb this." Every row is one pack icon whose
 * metaphor is a matter of taste: the current drawing first, then candidates drawn on the pack's 24 grid at
 * 1.5 (rendered here at the pack's row weight, as `<Icon row>` draws). Each shows in a transcript row and a
 * toolbar button, in light and dark. A pick moves into `design/icons/source/*.json` (the old drawing kept as
 * an alt) and this row leaves the backlog.
 */
export interface IconHillClimbGalleryProps {
  scheme: "light" | "dark";
}

type Candidate = { label: string; note: string } & ({ pack: string } | { draw: ReactNode });

interface Item {
  icon: string;
  row: string;
  why: string;
  candidates: Candidate[];
}

const BACKLOG: Item[] = [
  {
    icon: "tool.multiple",
    row: "Used 4 tools",
    why: "Four linked rings read as the Command key (⌘) at 13 px. Lucide, Phosphor and Tabler draw a group of tools as stacked layers or a 2x2 grid.",
    candidates: [
      { label: "Current", note: "four rings", pack: "tool.multiple" },
      {
        label: "Layers",
        note: "Lucide layers, Phosphor stack",
        draw: <path d="M12 4.25 20 8.5 12 12.75 4 8.5Z M4 12.25l8 4.25 8-4.25 M4 15.75 12 20l8-4.25" />,
      },
      {
        label: "2x2 tiles",
        note: "Tabler apps, SF square.grid.2x2",
        draw: (
          <path d="M6 4h3a2 2 0 0 1 2 2v3a2 2 0 0 1-2 2H6a2 2 0 0 1-2-2V6a2 2 0 0 1 2-2Z M15 4h3a2 2 0 0 1 2 2v3a2 2 0 0 1-2 2h-3a2 2 0 0 1-2-2V6a2 2 0 0 1 2-2Z M6 13h3a2 2 0 0 1 2 2v3a2 2 0 0 1-2 2H6a2 2 0 0 1-2-2v-3a2 2 0 0 1 2-2Z M15 13h3a2 2 0 0 1 2 2v3a2 2 0 0 1-2 2h-3a2 2 0 0 1-2-2v-3a2 2 0 0 1 2-2Z" />
        ),
      },
    ],
  },
  {
    icon: "tool.thought",
    row: "Thought for 12s",
    why: "An eight-stroke brain is the busiest glyph in the transcript and smudges at 13 px. Claude and Codex show the word Thinking with no glyph; the sets that draw one use a lightbulb or a thought bubble.",
    candidates: [
      { label: "Current", note: "brain", pack: "tool.thought" },
      {
        label: "Lightbulb",
        note: "Lucide lightbulb, SF lightbulb",
        draw: (
          <path d="M12 3.75a5.75 5.75 0 0 0-3.5 10.3c.6.5 1 1.2 1 2v.7h5v-.7c0-.8.4-1.5 1-2A5.75 5.75 0 0 0 12 3.75Z M10 20.25h4" />
        ),
      },
      {
        label: "Thought bubble",
        note: "SF bubble.left with trailing dots",
        draw: (
          <>
            <ellipse cx="13" cy="9.5" rx="7" ry="5.5" />
            <circle cx="7" cy="17" r="1.25" />
            <circle cx="4.75" cy="19.5" r=".6" />
          </>
        ),
      },
    ],
  },
  {
    icon: "agent.bot",
    row: "Agent",
    why: "A robot face with antenna and eyes is the cutest glyph left after the fork change. Claude and Codex mark an agent with their own logo; neutral sets use a chat bubble or an asterisk spark.",
    candidates: [
      { label: "Current", note: "robot face", pack: "agent.bot" },
      { label: "Chat bubble", note: "the pack's agent.chat", pack: "agent.chat" },
      {
        label: "Spark",
        note: "six-spoke asterisk (Lucide asterisk)",
        draw: <path d="M12 4v16 M5.07 8l13.86 8 M5.07 16l13.86-8" />,
      },
    ],
  },
  {
    icon: "action.quote",
    row: "Quote selection",
    why: "Quote draws the Reply arrow, which also means reply in Mail and Slack. Lucide, Phosphor and Tabler all draw quote as quotation marks or a barred text block.",
    candidates: [
      { label: "Current", note: "reply arrow", pack: "action.quote" },
      {
        label: "Quote marks",
        note: "Lucide quote, Tabler quote",
        draw: (
          <path d="M4.5 12h4.75v5H4.5Z M4.5 12c0-2.4 1.25-4.1 3.75-5 M14.25 12H19v5h-4.75Z M14.25 12c0-2.4 1.25-4.1 3.75-5" />
        ),
      },
      {
        label: "Text quote",
        note: "Lucide text-quote, SF text.quote",
        draw: <path d="M5 6.5v11 M9.5 7h9.5 M9.5 12h9.5 M9.5 17h6" />,
      },
    ],
  },
  {
    icon: "sources.connected",
    row: "3 sources connected",
    why: "Three nodes on a diagonal read as a molecule or a slider, not a connection. Lucide and SF use a plug or a link for connected sources.",
    candidates: [
      { label: "Current", note: "three linked nodes", pack: "sources.connected" },
      {
        label: "Plug",
        note: "Lucide plug, SF powerplug",
        draw: <path d="M9 3.5v4 M15 3.5v4 M6.5 7.5h11v3a5.5 5.5 0 0 1-11 0Z M12 16v4.5" />,
      },
      { label: "Link", note: "the pack's link", pack: "link" },
    ],
  },
  {
    icon: "tool.read",
    row: "Read App.tsx",
    why: "Reading a file draws an open book, so a Read row and a docs row look alike. Claude Code and Codex label it Read with a file; Lucide and Tabler use file-text or eye.",
    candidates: [
      { label: "Current", note: "open book", pack: "tool.read" },
      { label: "File with lines", note: "the pack's file.text", pack: "file.text" },
      { label: "Eye", note: "the pack's action.show", pack: "action.show" },
    ],
  },
  {
    icon: "agent.handoff",
    row: "Continue in Codex",
    why: "Two tiles under an arching arrow is five strokes and reads as a cloud upload at 13 px. Lucide forward and SF arrowshape.turn.up.right say pass it on in one stroke.",
    candidates: [
      { label: "Current", note: "two tiles, arc", pack: "agent.handoff" },
      {
        label: "Forward",
        note: "Lucide forward, SF arrowshape.turn.up.right",
        draw: <path d="M15 6.5l5 5-5 5 M4 17.5v-2a4 4 0 0 1 4-4h12" />,
      },
      {
        label: "Arrow into tile",
        note: "arrow crossing into a rounded square",
        draw: <path d="M14 5h3.5A2.5 2.5 0 0 1 20 7.5v9a2.5 2.5 0 0 1-2.5 2.5H14 M4 12h11 M11.5 8.5 15 12l-3.5 3.5" />,
      },
    ],
  },
];

const STROKE = (ICON_STROKE * 19) / 16;

function Glyph({ candidate, size }: { candidate: Candidate; size: number }) {
  if ("pack" in candidate) return <Icon name={candidate.pack} size={size} row />;
  return (
    <svg
      viewBox={ROW_VIEWBOX}
      width={size}
      height={size}
      overflow="visible"
      fill="none"
      stroke="currentColor"
      strokeWidth={STROKE}
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden="true"
      focusable="false"
    >
      {candidate.draw}
    </svg>
  );
}

export function IconHillClimbGallery({ scheme }: IconHillClimbGalleryProps) {
  return (
    <div className="icon-hillclimb" data-scheme={scheme}>
      {BACKLOG.map((item, rank) => (
        <section key={item.icon} className="icon-hillclimb-item">
          <header>
            <strong>
              {rank + 1}. {item.icon}
            </strong>
            <p>{item.why}</p>
          </header>
          <div className="icon-hillclimb-candidates">
            {item.candidates.map((candidate) => (
              <figure key={candidate.label} data-current={candidate.label === "Current" || undefined}>
                <div className="icon-hillclimb-row">
                  <Glyph candidate={candidate} size={16} />
                  <span>{item.row}</span>
                </div>
                <div className="icon-hillclimb-sizes">
                  <span className="icon-hillclimb-button">
                    <Glyph candidate={candidate} size={16} />
                  </span>
                  <Glyph candidate={candidate} size={12} />
                  <Glyph candidate={candidate} size={24} />
                </div>
                <figcaption>
                  {candidate.label}
                  <small>{candidate.note}</small>
                </figcaption>
              </figure>
            ))}
          </div>
        </section>
      ))}
    </div>
  );
}
