"use client";

import Image from "next/image";
import { useEffect, useMemo, useState } from "react";
import type { CSSProperties } from "react";
import landingImage from "@/app/[locale]/(landing)/assets/landing-image.png";
import { HeroPhone } from "./hero-phone";
import {
  heroTerminalTheme,
  heroTerminalThemes,
  heroThemeVariables,
  type HeroAppearance,
} from "./hero-playground-theme";

export function HeroPlayground() {
  const [appearance, setAppearance] = useState<HeroAppearance>("system");
  const [systemDark, setSystemDark] = useState(false);
  const [themeID, setThemeID] = useState("catppuccin-mocha");
  const [transparency, setTransparency] = useState(18);
  const [loaded, setLoaded] = useState(false);

  useEffect(() => {
    const media = window.matchMedia("(prefers-color-scheme: dark)");
    const update = () => setSystemDark(media.matches);
    update();
    media.addEventListener?.("change", update);
    return () => media.removeEventListener?.("change", update);
  }, []);

  const effectiveAppearance = appearance === "system"
    ? (systemDark ? "dark" : "light")
    : appearance;
  const theme = heroTerminalTheme(themeID);
  const variables = useMemo(
    () => heroThemeVariables(theme, effectiveAppearance, transparency),
    [effectiveAppearance, theme, transparency],
  );
  const tintOpacity = 0.12 + transparency / 100 * 0.42;

  return (
    <div className="relative">
      <div
        className={`relative overflow-hidden rounded-[1.1rem] border border-black/20 bg-[var(--cmux-surface-background)] shadow-[0_24px_44px_rgba(0,0,0,0.55)] transition-opacity duration-700 ${loaded ? "opacity-100" : "opacity-0"}`}
        style={variables as CSSProperties}
      >
        <Image
          src={landingImage}
          alt="cmux terminal app screenshot"
          priority
          quality={85}
          sizes="(min-width: 1440px) 1440px, 100vw"
          onLoad={() => setLoaded(true)}
          className="block w-full"
        />
        <div
          aria-hidden="true"
          className="pointer-events-none absolute inset-0"
          style={{
            backgroundColor: "var(--cmux-terminal-background)",
            mixBlendMode: "color",
            opacity: tintOpacity,
          }}
        />
        <div
          aria-hidden="true"
          className="pointer-events-none absolute inset-0"
          style={{
            backgroundColor: "var(--cmux-surface-background)",
            mixBlendMode: "soft-light",
            opacity: transparency / 100 * 0.45,
          }}
        />
        <HeroPhone />
      </div>

      <div
        className="mt-4 flex flex-wrap items-center justify-between gap-3 rounded-2xl border border-border bg-background/85 p-3 text-xs text-muted shadow-lg backdrop-blur-md"
        style={variables as CSSProperties}
      >
        <fieldset className="flex items-center gap-1" aria-label="Appearance">
          <legend className="sr-only">Appearance</legend>
          {(["system", "light", "dark"] as const).map((value) => (
            <button
              key={value}
              type="button"
              aria-pressed={appearance === value}
              onClick={() => setAppearance(value)}
              className="rounded-lg px-2.5 py-1.5 capitalize transition-colors hover:bg-[var(--cmux-hover)] hover:text-foreground aria-pressed:bg-[var(--cmux-selection)] aria-pressed:text-foreground"
            >
              {value}
            </button>
          ))}
        </fieldset>

        <label className="flex items-center gap-2">
          <span className="sr-only">Terminal theme</span>
          <select
            value={themeID}
            onChange={(event) => setThemeID(event.target.value)}
            className="max-w-[12rem] rounded-lg border border-border bg-transparent px-2.5 py-1.5 text-foreground outline-none focus:border-[var(--cmux-accent)]"
            aria-label="Terminal theme"
          >
            {heroTerminalThemes.map((option) => (
              <option key={option.id} value={option.id}>{option.label}</option>
            ))}
          </select>
        </label>

        <label className="flex min-w-[11rem] items-center gap-2">
          <span>Transparency</span>
          <input
            type="range"
            min="0"
            max="60"
            value={transparency}
            onChange={(event) => setTransparency(Number(event.target.value))}
            className="accent-[var(--cmux-accent)]"
            aria-label="Transparency"
          />
          <output className="w-8 text-right tabular-nums">{transparency}%</output>
        </label>
      </div>
    </div>
  );
}
