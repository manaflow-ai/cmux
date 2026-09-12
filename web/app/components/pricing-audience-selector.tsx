"use client";

import { useId, useRef, useState, type ReactNode } from "react";
import { posthog } from "../lib/posthog-client";

type PricingAudience = "individual" | "team";
const audiences: PricingAudience[] = ["individual", "team"];

export function PricingAudienceSelector({ individualLabel, teamLabel, ariaLabel, individual, team, surface = "public_pricing" }: {
  individualLabel: string;
  teamLabel: string;
  ariaLabel: string;
  individual: ReactNode;
  team: ReactNode;
  surface?: "public_pricing" | "app_pricing";
}) {
  const [audience, setAudience] = useState<PricingAudience>("individual");
  const id = useId();
  const buttons = useRef<Array<HTMLButtonElement | null>>([]);
  function select(next: PricingAudience) {
    setAudience(next);
    if (next !== audience) posthog.capture("cmux_pricing_audience_selected", { audience: next, surface });
  }
  return (
    <>
      <div className="mx-auto mt-6 flex w-fit rounded-xl border border-border p-1 text-sm" role="tablist" aria-label={ariaLabel}>
        {audiences.map((value, index) => (
          <button key={value} ref={(button) => { buttons.current[index] = button; }}
            type="button" role="tab" id={`${id}-${value}-tab`} aria-controls={`${id}-${value}-panel`}
            aria-selected={audience === value} tabIndex={audience === value ? 0 : -1}
            onClick={() => select(value)}
            onKeyDown={(event) => {
              if (!["ArrowLeft", "ArrowRight", "Home", "End"].includes(event.key)) return;
              event.preventDefault();
              const next = event.key === "Home" ? 0 : event.key === "End" ? 1 : 1 - index;
              select(audiences[next]);
              buttons.current[next]?.focus();
            }}
            className={`rounded-lg px-4 py-2 transition-colors ${audience === value ? "bg-foreground text-background" : "text-muted hover:text-foreground"}`}>
            {value === "individual" ? individualLabel : teamLabel}
          </button>
        ))}
      </div>
      <div className="mt-6">
        <div role="tabpanel" id={`${id}-individual-panel`} aria-labelledby={`${id}-individual-tab`} hidden={audience !== "individual"}>{individual}</div>
        <div role="tabpanel" id={`${id}-team-panel`} aria-labelledby={`${id}-team-tab`} hidden={audience !== "team"}>{team}</div>
      </div>
    </>
  );
}
