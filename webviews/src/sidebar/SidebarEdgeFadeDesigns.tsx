// l10n-allow-file: gallery design fixtures for the native sidebar's scroll edge fade, not shipped UI.
// Leo, 2026-11-22: "and i see a hard line break at the bottom here shit doesn't fade properly
// doesn't show enough sidebar properly gradually there's simultaneously a fade AND a hard break
// ideally lessen the hard break."
// The native mask (CmuxNextDesign/ScrollEdgeFade.swift) was a 4-stop linear alpha ramp, 22 pt at
// both edges; the kink where the ramp meets full ink reads as a line, and 22 pt is too short. This
// mock sidebar puts the same mask (a CSS mask-image, not a painted band) on a glass sidebar over a
// colourful backdrop, so each curve and band length can be compared.
// Pick "eased-tall": a smoothstep ramp sampled at 9 stops, 24 px at the top and 44 px at the bottom.
// The top fades only once the list is scrolled; the bottom only while more rows are below.
import { useCallback, useLayoutEffect, useRef, useState, type CSSProperties } from "react";
import "./SidebarEdgeFadeDesigns.css";

export type EdgeFadeVariant = "linear" | "eased" | "eased-tall" | "eased-tall-under-footer";

export interface SidebarEdgeFadeDesignsProps {
  variant: EdgeFadeVariant;
}

type Curve = "linear" | "smoothstep";

/** Ink alpha along a band, t in 0...1 from the edge inward. */
function alphaAt(curve: Curve, t: number): number {
  return curve === "linear" ? t : t * t * (3 - 2 * t);
}

/** Samples per band: the linear baseline is a 2-point ramp (4 stops in all); smoothstep has 9 (t = i/8). */
function samples(curve: Curve): number[] {
  const count = curve === "linear" ? 2 : 9;
  return Array.from({ length: count }, (_, i) => i / (count - 1));
}

const fmt = (n: number) => Number(n.toFixed(4)).toString();

/**
 * The mask gradient: `top` px of fade from the top edge, `bottom` px from the bottom edge, full ink
 * between. A band of 0 px is no fade on that edge.
 */
/** One mask stop: ink at `alpha` at `at` (a mask alpha, not a colour). */
const stop = (alpha: number, at: string) => `rgb(0 0 0 / ${fmt(alpha)}) ${at}`; // colour-allow: a mask's alpha stop, never painted

export function edgeFadeMask(curve: Curve, top: number, bottom: number): string {
  const stops: string[] = [];
  if (top > 0) for (const t of samples(curve)) stops.push(stop(alphaAt(curve, t), `${fmt(t * top)}px`));
  else stops.push(stop(1, "0px"));
  if (bottom > 0)
    for (const t of samples(curve).reverse()) stops.push(stop(alphaAt(curve, t), `calc(100% - ${fmt(t * bottom)}px)`));
  else stops.push(stop(1, "100%"));
  return `linear-gradient(to bottom, ${stops.join(", ")})`;
}

const specs: Record<EdgeFadeVariant, { curve: Curve; top: number; bottom: number; underFooter: boolean }> = {
  linear: { curve: "linear", top: 22, bottom: 22, underFooter: false },
  eased: { curve: "smoothstep", top: 22, bottom: 22, underFooter: false },
  "eased-tall": {
    curve: "smoothstep",
    top: 24,
    bottom: 44,
    underFooter: false,
  },
  "eased-tall-under-footer": {
    curve: "smoothstep",
    top: 24,
    bottom: 56,
    underFooter: true,
  },
};

const titles = [
  "Sidebar edge fade: eased bottom",
  "Fix flaky reconnect after sleep",
  "Resume swarm lane after VM restart on huge-blue",
  "Land project caps sticky header",
  "Profile scroll jank in long chats",
  "Review Lawrence's daemon PR",
  "Nightly relaunch on host idle",
  "Cloud link: OAuth redirect loop",
  "Port tab drag to Rust model",
  "Gallery coverage for Settings",
  "Why is CI queued 40 minutes",
  "Draft release notes 0.62",
  "Bisect terminal font regression",
  "Agent pane: retry on 529",
  "Unread dot misaligned in RTL",
  "Move session restore to daemon",
  "Browser pane cookie import",
  "Trim webviews bundle by 20%",
  "Markdown viewer table overflow",
  "Fix CLA check on bot commits",
  "Settings search ranking",
  "Workspace rename keeps focus",
  "Offline chat-sim duress run",
  "Spinner jitter at 120 Hz",
  "Remote attach over Tailscale",
  "Dock badge count off by one",
  "Status line for long tools",
  "Notification sound picker",
  "Clean up stale worktrees",
  "Copy link to session",
];

function SearchIcon() {
  return (
    <svg width="14" height="14" viewBox="0 0 16 16" aria-hidden="true">
      <circle cx="7" cy="7" r="4.75" fill="none" stroke="currentColor" strokeWidth="1.5" />
      <path d="M10.5 10.5 14 14" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" />
    </svg>
  );
}

export function SidebarEdgeFadeDesigns({ variant }: SidebarEdgeFadeDesignsProps) {
  const spec = specs[variant];
  const scroll = useRef<HTMLDivElement>(null);
  const [edges, setEdges] = useState({ above: false, below: true });
  const measure = useCallback(() => {
    const element = scroll.current;
    if (!element) return;
    const above = element.scrollTop > 0.5;
    const below = element.scrollTop + element.clientHeight < element.scrollHeight - 0.5;
    setEdges((old) => (old.above === above && old.below === below ? old : { above, below }));
  }, []);
  useLayoutEffect(measure, [measure]);
  const mask = edgeFadeMask(spec.curve, edges.above ? spec.top : 0, edges.below ? spec.bottom : 0);
  const maskStyle = { maskImage: mask, WebkitMaskImage: mask } as CSSProperties;
  return (
    <div className="sef-stage">
      <div className="sef-sidebar" data-variant={variant} data-under-footer={spec.underFooter || undefined}>
        <div ref={scroll} className="sef-scroll" style={maskStyle} onScroll={measure}>
          <div className="sef-header">Sessions</div>
          {titles.map((title, index) => (
            <div key={title} className="sef-row" data-active={index === 0 || undefined}>
              <span className="sef-dot" data-unread={index % 7 === 3 || undefined} />
              <span className="sef-title">{title}</span>
              <span className="sef-age">{`${index + 1}h`}</span>
            </div>
          ))}
        </div>
        <div className="sef-footer">
          <span className="sef-avatar" aria-label="Account">
            L
          </span>
          <span className="sef-footer-space" />
          <button type="button" className="sef-icon" aria-label="Search">
            <SearchIcon />
          </button>
        </div>
      </div>
    </div>
  );
}
