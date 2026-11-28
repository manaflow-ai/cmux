/**
 * The "How cmux NEXT fits together" figure. Drawn in currentColor, so it follows the docs theme in
 * light and dark; the caption carries the same content in words for screen readers, search, and
 * the page's .md variant (agent-page-markdown.ts drops svg).
 */

type Box = { x: number; y: number; w: number; h: number; title: string; lines: string[]; frame?: boolean };

const boxes: Box[] = [
  { x: 10, y: 10, w: 440, h: 250, title: "This Mac", lines: [], frame: true },
  { x: 30, y: 44, w: 400, h: 70, title: "cmux app", lines: ["native window, web views, Rust core", "palette, menus, CLI and MCP from one action catalog"] },
  { x: 30, y: 150, w: 185, h: 90, title: "cmux-tui daemon", lines: ["terminals, panes, layout", "cmux CLI, cmux mcp serve"] },
  { x: 245, y: 150, w: 185, h: 90, title: "acpmux daemon", lines: ["agent sessions by name", "Claude Code, Codex, more", "cost ledger"] },
  { x: 490, y: 10, w: 220, h: 110, title: "Machines you add", lines: ["cmux-tui + acpmux", "over SSH or your", "private network"] },
  { x: 490, y: 150, w: 220, h: 110, title: "Cloud machines", lines: ["cmux-tui + acpmux", "from a prepared image", ".cmux/machine.toml"] },
  { x: 10, y: 300, w: 700, h: 80, title: "cmux Cloud", lines: ["your account, machines and spares, vault, team hub for messages between sessions, GitHub connection"] },
];

// [x1, y1, x2, y2]: the links between parts, drawn with arrowheads at both ends.
const links: [number, number, number, number][] = [
  [122, 114, 122, 150],
  [337, 114, 337, 150],
  [430, 180, 490, 80],
  [430, 205, 490, 205],
  [230, 260, 230, 300],
  [600, 260, 600, 300],
];

export function ArchitectureDiagram({ caption }: { caption: string }) {
  return (
    <figure className="my-6">
      <svg
        viewBox="0 0 720 390"
        aria-hidden="true"
        className="h-auto w-full text-foreground"
        fontFamily="inherit"
      >
        <defs>
          <marker id="arch-arrow" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="6" markerHeight="6" orient="auto-start-reverse">
            <path d="M0 0L10 5L0 10z" fill="currentColor" fillOpacity="0.55" />
          </marker>
        </defs>
        {boxes.map((box) => (
          <g key={box.title}>
            <rect
              x={box.x}
              y={box.y}
              width={box.w}
              height={box.h}
              rx={10}
              fill="currentColor"
              fillOpacity={box.frame ? 0.02 : 0.05}
              stroke="currentColor"
              strokeOpacity={box.frame ? 0.25 : 0.4}
              strokeDasharray={box.frame ? "5 4" : undefined}
            />
            <text x={box.x + 14} y={box.y + 22} fill="currentColor" fontSize={14} fontWeight={600}>
              {box.title}
            </text>
            {box.lines.map((line, index) => (
              <text key={line} x={box.x + 14} y={box.y + 42 + index * 17} fill="currentColor" fillOpacity={0.7} fontSize={12}>
                {line}
              </text>
            ))}
          </g>
        ))}
        {links.map(([x1, y1, x2, y2]) => (
          <line
            key={`${x1},${y1},${x2},${y2}`}
            x1={x1}
            y1={y1}
            x2={x2}
            y2={y2}
            stroke="currentColor"
            strokeOpacity={0.55}
            strokeWidth={1.5}
            markerStart="url(#arch-arrow)"
            markerEnd="url(#arch-arrow)"
          />
        ))}
      </svg>
      <figcaption className="mt-2 text-sm text-muted">{caption}</figcaption>
    </figure>
  );
}
