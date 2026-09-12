"use client";

import { useState, type ReactNode } from "react";

type PricingAudience = "individual" | "team";

export function PricingAudienceSelector({
  individualLabel,
  teamLabel,
  ariaLabel,
  individual,
  team,
}: {
  individualLabel: string;
  teamLabel: string;
  ariaLabel: string;
  individual: ReactNode;
  team: ReactNode;
}) {
  const [audience, setAudience] = useState<PricingAudience>("individual");

  return (
    <>
      <div
        className="mx-auto mt-6 flex w-fit border border-border p-1 text-sm"
        role="tablist"
        aria-label={ariaLabel}
      >
        <AudienceButton
          active={audience === "individual"}
          onClick={() => setAudience("individual")}
          label={individualLabel}
        />
        <AudienceButton
          active={audience === "team"}
          onClick={() => setAudience("team")}
          label={teamLabel}
        />
      </div>
      <div className="mt-6">
        <div hidden={audience !== "individual"}>{individual}</div>
        <div hidden={audience !== "team"}>{team}</div>
      </div>
    </>
  );
}

function AudienceButton({
  active,
  onClick,
  label,
}: {
  active: boolean;
  onClick: () => void;
  label: string;
}) {
  return (
    <button
      type="button"
      role="tab"
      aria-selected={active}
      onClick={onClick}
      className={`px-4 py-2 transition-colors ${
        active
          ? "bg-foreground text-background"
          : "text-muted hover:text-foreground"
      }`}
    >
      {label}
    </button>
  );
}
