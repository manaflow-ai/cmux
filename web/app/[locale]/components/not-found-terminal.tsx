"use client";

import { useEffect, useRef, useState, type PointerEvent as ReactPointerEvent } from "react";
import { NotFoundLink } from "./not-found-link";

type TerminalProps = {
  title: string;
  command: string;
  welcome: string;
  docsLabel: string;
  discordLabel: string;
  githubLabel: string;
  emailLabel: string;
  supportLabel: string;
  docsHref: string;
  supportHref: string;
};

type AtlasTerminal = {
  open: (element: HTMLElement) => void;
  write: (text: string) => void;
  dispose?: () => void;
};

type AtlasModule = {
  init: () => Promise<void>;
  Terminal: {
    loadAtlas: (path: string) => Promise<unknown>;
    new (options: Record<string, unknown>): AtlasTerminal;
  };
};

function startAtlasTerminal(
  container: HTMLElement,
  welcome: string,
  onReady: () => void,
): (() => void) | undefined {
  const moduleUrl = process.env.NEXT_PUBLIC_GHOSTTY_WEB_MODULE_URL;
  const atlasBaseUrl = process.env.NEXT_PUBLIC_GHOSTTY_WEB_ATLAS_BASE_URL;
  if (!moduleUrl || !atlasBaseUrl) return undefined;

  let terminal: AtlasTerminal | undefined;
  let cancelled = false;
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
        rows: 32,
        fontFamily: "Menlo, monospace",
        fontSize: 12,
        theme: { background: "#111318", foreground: "#f2f4f8" },
      });
      terminal.open(container);
      terminal.write(welcome);
      onReady();
    } catch {
      // The public site keeps its text renderer when the private Atlas build is absent.
    }
  })();

  return () => {
    cancelled = true;
    terminal?.dispose?.();
  };
}

export function NotFoundTerminal({
  title,
  command,
  welcome,
  docsLabel,
  discordLabel,
  githubLabel,
  emailLabel,
  supportLabel,
  docsHref,
  supportHref,
}: TerminalProps) {
  const [offset, setOffset] = useState({ x: 0, y: 0 });
  const drag = useRef<{ pointerId: number; x: number; y: number } | null>(null);
  const atlasContainer = useRef<HTMLDivElement>(null);
  const [atlasActive, setAtlasActive] = useState(false);

  useEffect(() => {
    if (!atlasContainer.current) return;
    const cleanup = startAtlasTerminal(atlasContainer.current, welcome, () => setAtlasActive(true));
    return cleanup;
  }, [welcome]);

  function beginDrag(event: ReactPointerEvent<HTMLDivElement>) {
    drag.current = { pointerId: event.pointerId, x: event.clientX, y: event.clientY };
    event.currentTarget.setPointerCapture(event.pointerId);
  }

  function moveDrag(event: ReactPointerEvent<HTMLDivElement>) {
    if (!drag.current || drag.current.pointerId !== event.pointerId) return;
    setOffset((current) => ({
      x: current.x + event.clientX - drag.current!.x,
      y: current.y + event.clientY - drag.current!.y,
    }));
    drag.current.x = event.clientX;
    drag.current.y = event.clientY;
  }

  function endDrag(event: ReactPointerEvent<HTMLDivElement>) {
    if (drag.current?.pointerId === event.pointerId) drag.current = null;
  }

  return (
    <div
      className="relative mx-auto w-full max-w-[38rem] lg:mx-0"
      style={{ transform: `translate(${offset.x}px, ${offset.y}px)` }}
    >
      <div className="overflow-hidden rounded-[0.9rem] border border-[#3a3f4b] bg-[#111318] shadow-[0_30px_80px_-28px_rgba(0,0,0,0.75)]">
        <div
          className="flex h-11 cursor-grab items-center border-b border-[#2c3039] bg-[#1d2027] px-4 active:cursor-grabbing"
          onPointerDown={beginDrag}
          onPointerMove={moveDrag}
          onPointerUp={endDrag}
          onPointerCancel={endDrag}
          style={{ touchAction: "none" }}
          aria-label="Drag terminal window"
        >
          <div className="flex gap-2" aria-hidden="true">
            <span className="h-3 w-3 rounded-full bg-[#ff5f57]" />
            <span className="h-3 w-3 rounded-full bg-[#febc2e]" />
            <span className="h-3 w-3 rounded-full bg-[#28c840]" />
          </div>
          <span className="mx-auto pr-14 font-mono text-[11px] text-[#aeb4c0]">{title}</span>
        </div>
        <div className="relative min-h-[24rem] overflow-hidden px-5 py-5 font-mono text-[11px] leading-[1.65] text-[#f2f4f8] sm:px-6 sm:text-xs">
          <div ref={atlasContainer} className="absolute inset-0" aria-hidden="true" />
          <div className={atlasActive ? "invisible" : undefined}>
            <p className="text-[#aeb4c0]">Last login: Fri Sep  4 03:23:17 on ttys179</p>
            <p><span className="text-[#66d9ef]">cmux%</span> <span className="text-[#f8d477]">{command}</span></p>
            <pre className="mt-3 whitespace-pre-wrap text-[#e7eaf0]">{welcome}</pre>
            <p className="mt-3"><span className="text-[#66d9ef]">user in ~/workspace on feat/404 ● ● λ</span> <span className="animate-blink inline-block h-3 w-1.5 bg-[#f2f4f8] align-[-1px]" /></p>
          </div>
          <div className="relative mt-4 flex flex-wrap gap-x-4 gap-y-1 border-t border-[#2c3039] pt-3 text-[10px] text-[#9ddcff] sm:text-[11px]">
            <NotFoundLink href={docsHref} action="docs" className="hover:text-white hover:underline">{docsLabel}</NotFoundLink>
            <NotFoundLink href="https://discord.gg/xsgFEVrWCZ" action="discord" className="hover:text-white hover:underline" target="_blank" rel="noreferrer">{discordLabel}</NotFoundLink>
            <NotFoundLink href="https://github.com/manaflow-ai/cmux" action="github" className="hover:text-white hover:underline" target="_blank" rel="noreferrer">{githubLabel}</NotFoundLink>
            <a href="mailto:founders@manaflow.com" className="hover:text-white hover:underline">{emailLabel}</a>
            <NotFoundLink href={supportHref} action="support" className="hover:text-white hover:underline">{supportLabel}</NotFoundLink>
          </div>
        </div>
      </div>
      <span className="pointer-events-none absolute -bottom-7 left-5 font-mono text-[10px] uppercase tracking-[0.16em] text-muted">drag the title bar</span>
    </div>
  );
}
