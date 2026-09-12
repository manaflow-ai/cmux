"use client";

import { Fragment, useRef, useState, type PointerEvent, type ReactNode } from "react";

type TerminalProps = {
  command: string;
  welcome: string;
  lastLogin: string;
  dragLabel: string;
};

const ART_LINE_COUNT = 7;
const TERMINAL_COLUMN_WIDTH = 154;
const ART_COLORS = ["#60d1fa", "#54b2f4", "#4f94ee", "#5376e9", "#5f58e7", "#694be5", "#743ee4"];
const ANSI = {
  gray: "text-[#92948b]",
  white: "text-[#fdfff2]",
  purple: "text-[#a783f7]",
  green: "text-[#b3e053]",
};

/** Renders the fixed cmux welcome transcript used by the 404 reference. */
function renderWelcome(welcome: string): ReactNode[] {
  let lineNumber = 0;
  const lines = welcome.split("\n");
  return lines.map((line) => {
    const currentLine = lineNumber++;
    const art = line.match(/^(\s*:+)(\s*)(.*)$/);
    let content: ReactNode = <span className={ANSI.gray}>{line}</span>;

    if (currentLine < ART_LINE_COUNT && art) {
      content = (
        <>
          <span style={{ color: ART_COLORS[currentLine] }}>{art[1]}{art[2]}</span>
          {art[3] ? <span className={art[3] === "cmux" ? "text-[#60d1fa]" : "text-[#82828b]"}>{art[3]}</span> : null}
        </>
      );
    } else if (line.trim() === "Shortcuts" || line.trim() === "ショートカット") {
      content = <span className={`font-bold ${ANSI.white}`}>{line}</span>;
    } else {
      const shortcut = line.match(/^(\s+[⌘⌥⇧A-Za-z]+)(\s+)(.+)$/);
      const link = line.match(/^(\s+(?:Docs|Community|Source|Email))(\s+)(.+)$/);
      const command = line.match(/^(\s+Run )([^ ]+)(.*)$/);

      if (shortcut || link) {
        const match = shortcut ?? link;
        content = (
          <>
            <span className={ANSI.white} style={{ display: "inline-block", width: TERMINAL_COLUMN_WIDTH }}>{match?.[1]}</span>
            <span className={ANSI.gray}>{match?.[3]}</span>
          </>
        );
      } else if (command) {
        content = (
          <>
            <span className={ANSI.gray}>{command[1]}</span>
            <span className={`font-bold ${ANSI.white}`}>{command[2]}</span>
            <span className={ANSI.gray}>{command[3]}</span>
          </>
        );
      }
    }

    return (
      <Fragment key={`line-${currentLine}-${line}`}>
        {content}
        {currentLine < lines.length - 1 ? "\n" : null}
      </Fragment>
    );
  });
}

/** Renders the shell prompt shown before and after the welcome transcript. */
function Prompt({ command }: { command?: string }) {
  return (
    <>
      <span className={ANSI.purple}>cmux</span>
      <span className={ANSI.white}> in </span>
      <span className={ANSI.green}>~/fun</span>
      <span className={ANSI.white}> λ</span>
      {command ? <span className={ANSI.white}> {command}</span> : null}
    </>
  );
}

/** Provides pointer and keyboard movement for the terminal title bar. */
export function NotFoundTerminal({ command, welcome, lastLogin, dragLabel }: TerminalProps) {
  const [offset, setOffset] = useState({ x: 0, y: 0 });
  const [dragging, setDragging] = useState(false);
  const drag = useRef<{ pointerId: number; x: number; y: number } | null>(null);
  const lines = renderWelcome(
    welcome
      .replace(" (please leave a star ⭐)", "\n                      (please leave a star ⭐)")
      .replace(" (スターをお願いします ⭐)", "\n                      (スターをお願いします ⭐)"),
  );

  function moveBy(x: number, y: number) {
    setOffset((current) => ({ x: current.x + x, y: current.y + y }));
  }

  function onPointerDown(event: PointerEvent<HTMLButtonElement>) {
    if (event.button !== 0) return;
    event.preventDefault();
    drag.current = { pointerId: event.pointerId, x: event.clientX, y: event.clientY };
    setDragging(true);
    event.currentTarget.setPointerCapture(event.pointerId);
  }

  function onPointerMove(event: PointerEvent<HTMLButtonElement>) {
    if (!drag.current || drag.current.pointerId !== event.pointerId) return;
    moveBy(event.clientX - drag.current.x, event.clientY - drag.current.y);
    drag.current.x = event.clientX;
    drag.current.y = event.clientY;
  }

  function onPointerEnd(event: PointerEvent<HTMLButtonElement>) {
    if (drag.current?.pointerId !== event.pointerId) return;
    drag.current = null;
    setDragging(false);
  }

  function onKeyDown(event: React.KeyboardEvent<HTMLButtonElement>) {
    const step = event.shiftKey ? 32 : 16;
    const movement = { ArrowLeft: [-step, 0], ArrowRight: [step, 0], ArrowUp: [0, -step], ArrowDown: [0, step] }[event.key];
    if (!movement) return;
    event.preventDefault();
    moveBy(movement[0], movement[1]);
  }

  return (
    <div
      className={`relative mx-auto w-full max-w-[72rem] ${dragging ? "z-[10000] select-none" : "z-10"}`}
      style={{ transform: `translate(${offset.x}px, ${offset.y}px)` }}
    >
      <div className="overflow-hidden rounded-[22px] border border-[#52534f] bg-[#272823] shadow-[0_28px_70px_-30px_rgba(0,0,0,0.9)]">
        <button
          type="button"
          className="relative block h-10 w-full touch-none cursor-grab select-none border-0 border-b border-[#353631] bg-[#272823] p-0 text-left active:cursor-grabbing"
          aria-label={dragLabel}
          aria-roledescription="draggable window"
          onKeyDown={onKeyDown}
          onPointerDown={onPointerDown}
          onPointerMove={onPointerMove}
          onPointerUp={onPointerEnd}
          onPointerCancel={onPointerEnd}
        >
          <div className="absolute left-3 top-1/2 flex -translate-y-1/2 gap-[14px]" aria-hidden="true">
            <span className="h-[18px] w-[18px] rounded-full bg-[#ec6765]" />
            <span className="h-[18px] w-[18px] rounded-full bg-[#f2ca44]" />
            <span className="h-[18px] w-[18px] rounded-full bg-[#65c466]" />
          </div>
          <span className="absolute left-0 top-0 h-0.5 w-[217px] bg-[#3478f7]" aria-hidden="true" />
          <div className="absolute inset-y-0 left-[109px] flex w-[109px] items-center gap-2 border-x border-[#353631] pl-2 pr-2 text-sm text-[#d8d8d7]" aria-hidden="true">
            <span className="flex h-[18px] w-[18px] items-center justify-center rounded-[3px] bg-[#d8d8d7] font-mono text-[7px] font-bold tracking-[-0.12em] text-[#272823]">&gt;_</span>
            <span className="min-w-0 flex-1 truncate font-medium">~/fun</span>
            <span className="text-[15px] font-light leading-none text-[#92948b]">×</span>
          </div>
        </button>
        <div className="relative min-h-[45rem] overflow-hidden bg-[#272823] px-0 text-[11.3px] leading-[14px] text-[#fdfff2]" style={{ fontFamily: 'Menlo, Monaco, "Courier New", monospace' }}>
          <div className="absolute inset-0 whitespace-pre px-0 py-0">
            <p className="text-[#fdfff2]">{lastLogin}</p>
            <p><Prompt command={command} /></p>
            <pre className="m-0 whitespace-pre text-[#e7eaf0]">{lines}</pre>
            <p><Prompt />{"  "}<span className="animate-blink inline-block h-3 w-1.5 bg-[#f2f4f8] align-[-1px]" /></p>
          </div>
        </div>
      </div>
    </div>
  );
}
