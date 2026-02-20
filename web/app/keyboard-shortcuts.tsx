"use client";

import { useMemo, useState } from "react";

type Shortcut = {
  id: string;
  combos: string[][];
  description: string;
  note?: string;
};

type ShortcutCategory = {
  id: string;
  title: string;
  blurb?: string;
  shortcuts: Shortcut[];
};

const CATEGORIES: ShortcutCategory[] = [
  {
    id: "workspaces",
    title: "Workspaces",
    blurb: "Workspaces live in the sidebar. Each workspace has its own set of panes and surfaces.",
    shortcuts: [
      { id: "ws-new", combos: [["⌘", "N"]], description: "New workspace" },
      {
        id: "ws-jump-1-8",
        combos: [["⌘", "1–8"]],
        description: "Jump to workspace 1–8",
      },
      {
        id: "ws-jump-last",
        combos: [["⌘", "9"]],
        description: "Jump to last workspace",
      },
      {
        id: "ws-close",
        combos: [["⌘", "⇧", "W"]],
        description: "Close workspace",
      },
    ],
  },
  {
    id: "surfaces",
    title: "Surfaces",
    blurb: "Surfaces are tabs inside a pane.",
    shortcuts: [
      { id: "sf-new", combos: [["⌘", "T"]], description: "New surface" },
      {
        id: "sf-prev-1",
        combos: [["⌘", "⇧", "["]],
        description: "Previous surface",
      },
      {
        id: "sf-prev-2",
        combos: [["⌃", "⇧", "Tab"]],
        description: "Previous surface",
      },
      {
        id: "sf-jump-1-8",
        combos: [["⌃", "1–8"]],
        description: "Jump to surface 1–8",
      },
      {
        id: "sf-jump-last",
        combos: [["⌃", "9"]],
        description: "Jump to last surface",
      },
      { id: "sf-close", combos: [["⌘", "W"]], description: "Close surface" },
    ],
  },
  {
    id: "split-panes",
    title: "Split Panes",
    shortcuts: [
      { id: "sp-right", combos: [["⌘", "D"]], description: "Split right" },
      { id: "sp-down", combos: [["⌘", "⇧", "D"]], description: "Split down" },
      {
        id: "sp-focus",
        combos: [["⌥", "⌘", "←/→/↑/↓"]],
        description: "Focus pane directionally",
      },
      {
        id: "sp-browser-right",
        combos: [["⌥", "⌘", "D"]],
        description: "Split browser right",
      },
      {
        id: "sp-browser-down",
        combos: [["⌥", "⌘", "⇧", "D"]],
        description: "Split browser down",
      },
    ],
  },
  {
    id: "browser",
    title: "Browser",
    shortcuts: [
      {
        id: "br-open",
        combos: [["⌘", "⇧", "L"]],
        description: "Open browser surface",
      },
      { id: "br-addr", combos: [["⌘", "L"]], description: "Focus address bar" },
      { id: "br-forward", combos: [["⌘", "]"]], description: "Forward" },
      { id: "br-reload", combos: [["⌘", "R"]], description: "Reload page" },
      {
        id: "br-devtools",
        combos: [["⌥", "⌘", "I"]],
        description: "Open Developer Tools",
      },
    ],
  },
  {
    id: "notifications",
    title: "Notifications",
    shortcuts: [
      {
        id: "nt-panel",
        combos: [["⌘", "⇧", "I"]],
        description: "Show notifications panel",
      },
      {
        id: "nt-latest",
        combos: [["⌘", "⇧", "U"]],
        description: "Jump to latest unread",
      },
      {
        id: "nt-flash",
        combos: [["⌘", "⇧", "L"]],
        description: "Trigger flash",
      },
    ],
  },
  {
    id: "find",
    title: "Find",
    shortcuts: [
      { id: "fd-find", combos: [["⌘", "F"]], description: "Find" },
      {
        id: "fd-next-prev",
        combos: [
          ["⌘", "G"],
          ["⌘", "⇧", "G"],
        ],
        description: "Find next / previous",
      },
      {
        id: "fd-hide",
        combos: [["⌘", "⇧", "F"]],
        description: "Hide find bar",
      },
      {
        id: "fd-selection",
        combos: [["⌘", "E"]],
        description: "Use selection for find",
      },
    ],
  },
  {
    id: "terminal",
    title: "Terminal",
    shortcuts: [
      {
        id: "tm-clear",
        combos: [["⌘", "K"]],
        description: "Clear scrollback",
      },
      {
        id: "tm-copy",
        combos: [["⌘", "C"]],
        description: "Copy (with selection)",
      },
      { id: "tm-paste", combos: [["⌘", "V"]], description: "Paste" },
      {
        id: "tm-font",
        combos: [
          ["⌘", "+"],
          ["⌘", "-"],
        ],
        description: "Increase / decrease font size",
      },
      { id: "tm-reset", combos: [["⌘", "0"]], description: "Reset font size" },
    ],
  },
  {
    id: "window",
    title: "Window",
    shortcuts: [
      { id: "wn-new", combos: [["⌘", "⇧", "N"]], description: "New window" },
      { id: "wn-settings", combos: [["⌘", ","]], description: "Settings" },
      {
        id: "wn-reload",
        combos: [["⌘", "⇧", "R"]],
        description: "Reload configuration",
      },
      { id: "wn-quit", combos: [["⌘", "Q"]], description: "Quit" },
    ],
  },
];

function normalize(s: string) {
  return s.toLowerCase().replace(/\s+/g, " ").trim();
}

function comboToText(combo: string[]) {
  return combo.join(" ");
}

function shortcutSearchText(category: ShortcutCategory, s: Shortcut) {
  const combos = s.combos.map(comboToText).join(" ");
  return normalize(`${category.title} ${combos} ${s.description} ${s.note ?? ""}`);
}

function KeyCombo({ combo }: { combo: string[] }) {
  return (
    <span className="inline-flex items-center">
      {combo.map((k, idx) => (
        <span key={`${k}-${idx}`} className="inline-flex items-center">
          <kbd>{k}</kbd>
          {idx < combo.length - 1 && (
            <span className="text-muted/30 text-[10px] mx-[3px] select-none font-mono">
              +
            </span>
          )}
        </span>
      ))}
    </span>
  );
}

function ShortcutRow({ shortcut }: { shortcut: Shortcut }) {
  return (
    <div className="flex items-center justify-between gap-4 py-[11px] px-4 hover:bg-foreground/[0.025] transition-colors">
      <div className="min-w-0">
        <span className="text-[14px] text-foreground/90">
          {shortcut.description}
        </span>
        {shortcut.note && (
          <span className="text-[12px] text-muted/50 ml-2">
            {shortcut.note}
          </span>
        )}
      </div>
      <div className="flex items-center gap-3 shrink-0">
        {shortcut.combos.map((combo, idx) => (
          <span
            key={`${shortcut.id}-combo-${idx}`}
            className="inline-flex items-center"
          >
            {idx > 0 && (
              <span className="text-muted/30 text-[11px] select-none mr-3 font-mono">
                /
              </span>
            )}
            <KeyCombo combo={combo} />
          </span>
        ))}
      </div>
    </div>
  );
}

export function KeyboardShortcuts() {
  const [query, setQuery] = useState("");

  const filtered = useMemo(() => {
    const q = normalize(query);
    if (!q) return CATEGORIES;
    return CATEGORIES.map((cat) => ({
      ...cat,
      shortcuts: cat.shortcuts.filter((s) =>
        shortcutSearchText(cat, s).includes(q),
      ),
    })).filter((cat) => cat.shortcuts.length > 0);
  }, [query]);

  return (
    <div className="mt-2 mb-12">
      {/* Search */}
      <div className="relative mb-8">
        <div className="pointer-events-none absolute left-2.5 top-1/2 -translate-y-1/2 text-muted/40">
          <svg
            width="14"
            height="14"
            viewBox="0 0 24 24"
            fill="none"
            stroke="currentColor"
            strokeWidth="2"
            strokeLinecap="round"
            strokeLinejoin="round"
          >
            <circle cx="11" cy="11" r="8" />
            <path d="M21 21l-4.3-4.3" />
          </svg>
        </div>
        <input
          value={query}
          onChange={(e) => setQuery(e.target.value)}
          placeholder="Search shortcuts..."
          className="w-full pl-9 pr-3 py-1.5 rounded-lg border border-border bg-transparent text-[13px] placeholder:text-muted/40 focus:outline-none focus:border-foreground/20 transition-colors"
          aria-label="Search keyboard shortcuts"
        />
      </div>

      {/* Category jump links */}
      {!query && (
        <nav className="flex flex-wrap items-center gap-y-2 mb-10">
          {CATEGORIES.map((cat, idx) => (
            <span key={cat.id} className="inline-flex items-center">
              <a
                href={`#${cat.id}`}
                className="text-[13px] text-muted hover:text-foreground transition-colors"
              >
                {cat.title}
              </a>
              {idx < CATEGORIES.length - 1 && (
                <span className="text-border mx-2.5 text-[10px] select-none">
                  ·
                </span>
              )}
            </span>
          ))}
        </nav>
      )}

      {/* Content */}
      {filtered.length === 0 ? (
        <div className="py-16 text-center">
          <p className="text-[14px] text-muted/70">No shortcuts found</p>
          <p className="text-[13px] text-muted/40 mt-1.5">
            Try a different search term
          </p>
        </div>
      ) : (
        <div className="space-y-10">
          {filtered.map((cat) => (
            <section key={cat.id} id={cat.id} className="scroll-mt-20">
              <div className="mb-3">
                <div className="text-[13px] font-medium text-muted/60">
                  {cat.title}
                </div>
                {cat.blurb && (
                  <p className="text-[13px] text-muted/50 mt-1">{cat.blurb}</p>
                )}
              </div>
              <div className="rounded-xl border border-border overflow-hidden">
                <div className="divide-y divide-border/60">
                  {cat.shortcuts.map((s) => (
                    <ShortcutRow key={s.id} shortcut={s} />
                  ))}
                </div>
              </div>
            </section>
          ))}
        </div>
      )}
    </div>
  );
}
