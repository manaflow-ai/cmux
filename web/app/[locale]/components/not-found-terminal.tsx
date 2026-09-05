"use client";

import { Fragment, useEffect, useRef, useState, type PointerEvent as ReactPointerEvent } from "react";
import { NotFoundLink } from "./not-found-link";

type TerminalProps = {
  title: string;
  command: string;
  welcome: string;
  docsLabel: string;
  docsHref: string;
};

type AtlasTerminal = {
  open: (element: HTMLElement) => void;
  write: (text: string) => void;
  atlasReady: Promise<void>;
  dispose?: () => void;
};

type AtlasModule = {
  init: () => Promise<void>;
  Terminal: {
    loadAtlas: (path: string) => Promise<unknown>;
    new (options: Record<string, unknown>): AtlasTerminal;
  };
};

const ART_FRAME_A = [
  "  ::",
  "    ::::              cmux",
  "      ::::::",
  "        ::::::        the open source terminal",
  "      ::::::          built for coding agents",
  "    ::::",
  "  ::",
].join("\n");

const ART_FRAME_B = [
  "    ::",
  "      ::::            cmux",
  "        ::::::",
  "          ::::::      the open source terminal",
  "        ::::::        built for coding agents",
  "      :::: ",
  "    ::",
].join("\n");

const MONOKAI = {
  background: "#272822",
  foreground: "#fcfff1",
  cursor: "#c0c1b5",
  cursorAccent: "#8d8e82",
  selectionBackground: "#57584f",
  selectionForeground: "#fcfff1",
  black: "#272822",
  red: "#f92672",
  green: "#a6e22e",
  yellow: "#e6db74",
  blue: "#66d9ef",
  magenta: "#ae81ff",
  cyan: "#a6e22e",
  white: "#fcfff1",
  brightBlack: "#75715e",
  brightRed: "#f92672",
  brightGreen: "#a6e22e",
  brightYellow: "#e6db74",
  brightBlue: "#66d9ef",
  brightMagenta: "#ae81ff",
  brightCyan: "#a6e22e",
  brightWhite: "#f8f8f2",
};

function colorizeArt(art: string) {
  const colors = ["#43d1fc", "#44b2f7", "#4d93f2", "#5a75ee", "#6c56ec", "#7848ea", "#833ae9"];
  return art
    .split("\n")
    .map((line, index) => `\x1b[38;2;${hexRgb(colors[index])}m${line}\x1b[0m`)
    .join("\r\n");
}

const ANSI = {
  gray: "\x1b[38;2;146;148;139m",
  white: "\x1b[38;2;252;255;241m",
  purple: "\x1b[38;2;178;129;252m",
  green: "\x1b[38;2;165;225;62m",
  cyan: "\x1b[38;2;116;214;237m",
  yellow: "\x1b[38;2;226;220;122m",
  pink: "\x1b[38;2;243;59;117m",
  bold: "\x1b[1m",
  reset: "\x1b[0m",
};

function colorizeWelcome(welcome: string, art: string) {
  return welcome
    .replace(ART_FRAME_A, colorizeArt(art))
    .split("\n")
    .map((line) => {
      if (line.trim() === "Shortcuts" || line.trim() === "ショートカット") {
        return `${ANSI.bold}${ANSI.white}${line}${ANSI.reset}`;
      }
      const shortcut = line.match(/^(\s+[⌘⌥⇧A-Za-z]+)(\s+)(.+)$/);
      if (shortcut) {
        return `${ANSI.white}${shortcut[1]}${ANSI.gray}${shortcut[2]}${shortcut[3]}${ANSI.reset}`;
      }
      const link = line.match(/^(\s+(?:Docs|Discord|GitHub|Email))(\s+)(.+)$/);
      if (link) {
        return `${ANSI.white}${link[1]}${ANSI.gray}${link[2]}${link[3]}${ANSI.reset}`;
      }
      const run = line.match(/^(\s+Run )([^ ]+)(.*)$/);
      if (run) {
        return `${ANSI.gray}${run[1]}${ANSI.bold}${ANSI.white}${run[2]}${ANSI.reset}${ANSI.gray}${run[3]}${ANSI.reset}`;
      }
      return `${ANSI.gray}${line}${ANSI.reset}`;
    })
    .join("\r\n");
}

function renderFallbackWelcome(welcome: string, frame: number) {
  const art = frame ? ART_FRAME_B : ART_FRAME_A;
  const lines = welcome.replace(ART_FRAME_A, art).split("\n");
  return lines.map((line, index) => {
    const isArt = index < ART_FRAME_A.split("\n").length;
    const color = isArt
      ? ["#43d1fc", "#44b2f7", "#4d93f2", "#5a75ee", "#6c56ec", "#7848ea", "#833ae9"][index]
      : "#92948b";
    return (
      <Fragment key={`${index}-${line}`}>
        <span style={{ color }}>{line}</span>
        {index < lines.length - 1 ? "\n" : null}
      </Fragment>
    );
  });
}

function hexRgb(color: string) {
  const value = color.slice(1);
  return `${parseInt(value.slice(0, 2), 16)};${parseInt(value.slice(2, 4), 16)};${parseInt(value.slice(4, 6), 16)}`;
}

function atlasTranscript(welcome: string, art: string, command: string) {
  const readableWelcome = welcome
    .replace(" (please leave a star ⭐)", "\n                      (please leave a star ⭐)")
    .replace(" (スターをお願いします ⭐)", "\n                      (スターをお願いします ⭐)");
  const prompt = `${ANSI.purple}user${ANSI.gray} in ${ANSI.green}~/workspace${ANSI.gray} on ${ANSI.cyan}feat/better-404 ${ANSI.yellow}●${ANSI.gray} ${ANSI.pink}●${ANSI.gray} ${ANSI.purple}λ${ANSI.reset}`;
  return `\x1b[2J\x1b[H${ANSI.gray}Last login: Fri Sep  4 03:23:17 on ttys179${ANSI.reset}\r\n${ANSI.cyan}cmux%${ANSI.reset} ${ANSI.yellow}${command}${ANSI.reset}\r\n${colorizeWelcome(readableWelcome, art)}\r\n${prompt}`;
}

function startAtlasTerminal(
  container: HTMLElement,
  welcome: string,
  command: string,
  onReady: () => void,
): (() => void) | undefined {
  const moduleUrl = process.env.NEXT_PUBLIC_GHOSTTY_WEB_MODULE_URL;
  const atlasBaseUrl = process.env.NEXT_PUBLIC_GHOSTTY_WEB_ATLAS_BASE_URL;
  if (!moduleUrl || !atlasBaseUrl) return undefined;

  let terminal: AtlasTerminal | undefined;
  let cancelled = false;
  let animation: number | undefined;
  void (async () => {
    try {
      const atlasModule = (await import(
        /* webpackIgnore: true */ moduleUrl
      )) as AtlasModule;
      await atlasModule.init();
      if (cancelled) return;
      const atlas = await atlasModule.Terminal.loadAtlas(
        `${atlasBaseUrl}/menlo-12-dpr2-v2`,
      );
      if (cancelled) return;
      terminal = new atlasModule.Terminal({
        renderer: "atlas",
        atlas,
        cols: 88,
        rows: 40,
        theme: MONOKAI,
      });
      terminal.open(container);
      await terminal.atlasReady;
      if (cancelled) return;
      let frame = 0;
      const render = () => terminal?.write(atlasTranscript(welcome, frame ? ART_FRAME_B : ART_FRAME_A, command));
      render();
      animation = window.setInterval(() => {
        frame = frame ? 0 : 1;
        render();
      }, 1200);
      onReady();
    } catch {
      // The public site keeps its text renderer when the private Atlas build is absent.
    }
  })();

  return () => {
    cancelled = true;
    if (animation !== undefined) window.clearInterval(animation);
    terminal?.dispose?.();
  };
}

export function NotFoundTerminal({
  title,
  command,
  welcome,
  docsLabel,
  docsHref,
}: TerminalProps) {
  const [offset, setOffset] = useState({ x: 0, y: 0 });
  const [artFrame, setArtFrame] = useState(0);
  const drag = useRef<{ pointerId: number; x: number; y: number } | null>(null);
  const atlasContainer = useRef<HTMLDivElement>(null);
  const [atlasActive, setAtlasActive] = useState(false);

  useEffect(() => {
    const animation = window.setInterval(() => setArtFrame((frame) => (frame ? 0 : 1)), 1200);
    return () => window.clearInterval(animation);
  }, []);

  useEffect(() => {
    if (!atlasContainer.current) return;
    const cleanup = startAtlasTerminal(atlasContainer.current, welcome, command, () => setAtlasActive(true));
    return cleanup;
  }, [welcome, command]);

  function beginDrag(event: ReactPointerEvent<HTMLDivElement>) {
    drag.current = { pointerId: event.pointerId, x: event.clientX, y: event.clientY };
    event.currentTarget.setPointerCapture(event.pointerId);
  }

  function moveDrag(event: ReactPointerEvent<HTMLDivElement>) {
    if (!drag.current || drag.current.pointerId !== event.pointerId) return;
    const deltaX = event.clientX - drag.current.x;
    const deltaY = event.clientY - drag.current.y;
    setOffset((current) => ({
      x: current.x + deltaX,
      y: current.y + deltaY,
    }));
    drag.current.x = event.clientX;
    drag.current.y = event.clientY;
  }

  function endDrag(event: ReactPointerEvent<HTMLDivElement>) {
    if (drag.current?.pointerId === event.pointerId) drag.current = null;
  }

  return (
    <div
      className="relative mx-auto w-full max-w-[72rem]"
      style={{ transform: `translate(${offset.x}px, ${offset.y}px)` }}
    >
      <div className="overflow-hidden rounded-[10px] border border-[#3a3c42] bg-[#272822] shadow-[0_28px_70px_-30px_rgba(0,0,0,0.9)]">
        <div
          className="relative flex h-[38px] cursor-grab select-none items-center border-b border-[#34363b] bg-[#1f2025] px-4 active:cursor-grabbing"
          onPointerDown={beginDrag}
          onPointerMove={moveDrag}
          onPointerUp={endDrag}
          onPointerCancel={endDrag}
          style={{ touchAction: "none" }}
          aria-label="Drag terminal window"
          role="toolbar"
        >
          <div className="absolute left-[13px] top-1/2 flex -translate-y-1/2 gap-[7px]" aria-hidden="true">
            <span className="h-[12px] w-[12px] rounded-full bg-[#ff5f57] shadow-[inset_0_0_0_0.5px_rgba(0,0,0,0.18)]" />
            <span className="h-[12px] w-[12px] rounded-full bg-[#febc2e] shadow-[inset_0_0_0_0.5px_rgba(0,0,0,0.18)]" />
            <span className="h-[12px] w-[12px] rounded-full bg-[#28c840] shadow-[inset_0_0_0_0.5px_rgba(0,0,0,0.18)]" />
          </div>
          <span className="pointer-events-none absolute inset-x-0 text-center font-sans text-[13px] font-medium tracking-[-0.01em] text-[#aeb0b5]">{title}</span>
        </div>
        <div className="relative min-h-[45rem] overflow-hidden bg-[#272822] px-5 py-5 font-mono text-[11px] leading-[1.5] text-[#f2f4f8] sm:px-6 sm:text-xs">
          <div ref={atlasContainer} className="absolute inset-0" aria-hidden="true" />
          <div className={atlasActive ? "invisible" : undefined}>
            <p className="text-[#aeb4c0]">Last login: Fri Sep  4 03:23:17 on ttys179</p>
            <p><span className="text-[#66d9ef]">cmux%</span> <span className="text-[#f8d477]">{command}</span></p>
            <pre className="mt-3 whitespace-pre-wrap text-[#e7eaf0]">{renderFallbackWelcome(welcome.replace(" (please leave a star ⭐)", "\n                      (please leave a star ⭐)").replace(" (スターをお願いします ⭐)", "\n                      (スターをお願いします ⭐)"), artFrame)}</pre>
            <p className="mt-3"><span className="text-[#66d9ef]">user in ~/workspace on feat/404 ● ● λ</span> <span className="animate-blink inline-block h-3 w-1.5 bg-[#f2f4f8] align-[-1px]" /></p>
          </div>
          <div className="relative mt-4 border-t border-[#2c3039] pt-3 text-[10px] text-[#9ddcff] sm:text-[11px]">
            <NotFoundLink href={docsHref} action="docs" className="hover:text-white hover:underline">{docsLabel}</NotFoundLink>
          </div>
        </div>
      </div>
    </div>
  );
}
