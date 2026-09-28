"use client";

import { useTranslations } from "next-intl";
import { useReducer, useState } from "react";
import { Link, useRouter } from "@/i18n/navigation";
import { TEAM_PRICING_USD } from "@/services/billing/plans";
import { InlineError } from "../../components/settings-ui/feedback";
import { settingsButtonClass, settingsInputClass, settingsLabelClass } from "../../components/settings-ui/styles";
import { InviteLinkCreator, InviteMembersForm } from "../invite-panel";
import { useCreateTeam } from "../team-api";
import { TEAM_NAME_MAX_LENGTH, teamCheckoutHref, validateTeamName } from "../team-logic";
import { useTeamErrorText } from "../team-ui";

type CreatedTeam = { readonly id: string; readonly displayName: string };

export type NewTeamFlowState =
  | { readonly step: "name" }
  | { readonly step: "plan"; readonly team: CreatedTeam }
  | { readonly step: "invite"; readonly team: CreatedTeam };

export type NewTeamFlowAction =
  | { readonly type: "created"; readonly team: CreatedTeam }
  | { readonly type: "choseFree" }
  | { readonly type: "backToPlan" };

/**
 * Step machine for team creation. The team exists after the first step, so
 * there is no way back to the name step; later steps only move forward, with
 * one way back from invitations to the plan choice.
 */
export function newTeamFlowReducer(state: NewTeamFlowState, action: NewTeamFlowAction): NewTeamFlowState {
  switch (action.type) {
    case "created":
      return state.step === "name" ? { step: "plan", team: action.team } : state;
    case "choseFree":
      return state.step === "plan" ? { step: "invite", team: state.team } : state;
    case "backToPlan":
      return state.step === "invite" ? { step: "plan", team: state.team } : state;
  }
}

const STEP_ORDER = ["name", "plan", "invite"] as const;

export function NewTeamFlow({ initialState = { step: "name" } }: { readonly initialState?: NewTeamFlowState }) {
  const t = useTranslations("dashboard.teams.new");
  const [state, dispatch] = useReducer(newTeamFlowReducer, initialState);
  const stepIndex = STEP_ORDER.indexOf(state.step);

  return (
    <div className="grid max-w-2xl gap-4">
      <ol className="flex gap-3 text-xs text-muted" aria-label={t("stepsLabel")}>
        {STEP_ORDER.map((step, index) => (
          <li
            key={step}
            aria-current={index === stepIndex ? "step" : undefined}
            className={index === stepIndex ? "font-medium text-foreground" : undefined}
          >
            {index + 1}. {t(`steps.${step}`)}
          </li>
        ))}
      </ol>
      {state.step === "name" ? <NameStep onCreated={(team) => dispatch({ type: "created", team })} /> : null}
      {state.step === "plan" ? <PlanStep team={state.team} onFree={() => dispatch({ type: "choseFree" })} /> : null}
      {state.step === "invite" ? <InviteStep team={state.team} onBack={() => dispatch({ type: "backToPlan" })} /> : null}
    </div>
  );
}

function NameStep({ onCreated }: { readonly onCreated: (team: CreatedTeam) => void }) {
  const t = useTranslations("dashboard.teams.new");
  const errorText = useTeamErrorText();
  const create = useCreateTeam();
  const [name, setName] = useState("");
  const [validation, setValidation] = useState<"empty" | "tooLong" | null>(null);

  return (
    <form
      className="grid gap-3 border border-border p-4"
      onSubmit={(event) => {
        event.preventDefault();
        const result = validateTeamName(name);
        if (!result.ok) {
          setValidation(result.reason);
          return;
        }
        setValidation(null);
        create.mutate(result.value, { onSuccess: ({ team }) => onCreated(team) });
      }}
    >
      <h2 className="text-sm font-medium">{t("nameTitle")}</h2>
      <label>
        <span className={settingsLabelClass}>{t("nameLabel")}</span>
        <input
          value={name}
          autoFocus
          maxLength={TEAM_NAME_MAX_LENGTH + 20}
          onChange={(event) => {
            setName(event.target.value);
            setValidation(null);
          }}
          placeholder={t("namePlaceholder")}
          className={`${settingsInputClass} mt-1`}
        />
      </label>
      {validation ? <InlineError message={t(`nameError.${validation}`, { max: TEAM_NAME_MAX_LENGTH })} /> : null}
      {create.isError ? <InlineError message={errorText(create.error)} /> : null}
      <div className="flex justify-end gap-2">
        <Link href="/dashboard/teams" className={settingsButtonClass("secondary")}>
          {t("cancel")}
        </Link>
        <button type="submit" disabled={create.isPending} className={settingsButtonClass("primary")}>
          {create.isPending ? t("creating") : t("createAction")}
        </button>
      </div>
    </form>
  );
}

const PLAN_FEATURES = ["featureMembers", "featureProForEveryone", "featureCentralBilling", "featurePrioritySupport"] as const;
const FREE_FEATURES: readonly string[] = ["featureMembers"];

function PlanStep({ team, onFree }: { readonly team: CreatedTeam; readonly onFree: () => void }) {
  const t = useTranslations("dashboard.teams.new");
  const teamPrice = TEAM_PRICING_USD.month.billedAmount;
  return (
    <section className="grid gap-3">
      <h2 className="text-sm font-medium">{t("planTitle", { team: team.displayName })}</h2>
      <p className="text-xs text-muted">{t("planDescription")}</p>
      <div className="grid gap-3 md:grid-cols-2">
        <div className="grid content-start gap-2 border border-border p-4">
          <div className="text-sm font-medium">{t("freeName")}</div>
          <div className="text-xs text-muted">{t("freePrice")}</div>
          <FeatureList features={PLAN_FEATURES} included={FREE_FEATURES} />
          <button type="button" onClick={onFree} className={`${settingsButtonClass("secondary")} mt-2`}>
            {t("chooseFree")}
          </button>
        </div>
        <div className="grid content-start gap-2 border border-foreground p-4">
          <div className="text-sm font-medium">{t("teamName")}</div>
          <div className="text-xs text-muted">{t("teamPrice", { price: teamPrice })}</div>
          <FeatureList features={PLAN_FEATURES} included={PLAN_FEATURES} />
          {/* A full navigation: checkout redirects to Stripe. */}
          <a href={teamCheckoutHref(team.id)} className={`${settingsButtonClass("primary")} mt-2`}>
            {t("chooseTeam", { price: teamPrice })}
          </a>
        </div>
      </div>
      <p className="text-xs text-muted">{t("upgradeLater")}</p>
    </section>
  );
}

function FeatureList({
  features,
  included,
}: {
  readonly features: readonly string[];
  readonly included: readonly string[];
}) {
  const t = useTranslations("dashboard.teams.new");
  return (
    <ul className="grid gap-1 text-xs">
      {features.map((feature) => (
        <li key={feature} className={included.includes(feature) ? undefined : "text-muted line-through"}>
          {t(feature)}
        </li>
      ))}
    </ul>
  );
}

function InviteStep({ team, onBack }: { readonly team: CreatedTeam; readonly onBack: () => void }) {
  const t = useTranslations("dashboard.teams.new");
  const router = useRouter();
  const teamHref = `/dashboard/teams/${encodeURIComponent(team.id)}`;
  return (
    <section className="grid gap-4">
      <div>
        <h2 className="text-sm font-medium">{t("inviteTitle", { team: team.displayName })}</h2>
        <p className="mt-1 text-xs text-muted">{t("inviteDescription")}</p>
      </div>
      <div className="grid gap-2 border border-border p-4">
        <h3 className="text-xs font-medium">{t("inviteByEmail")}</h3>
        <InviteMembersForm teamId={team.id} />
      </div>
      <div className="grid gap-2 border border-border p-4">
        <h3 className="text-xs font-medium">{t("inviteByLink")}</h3>
        <InviteLinkCreator teamId={team.id} />
      </div>
      <div className="flex justify-between gap-2">
        <button type="button" onClick={onBack} className={settingsButtonClass("ghost")}>
          {t("backToPlan")}
        </button>
        <button type="button" onClick={() => router.push(teamHref)} className={settingsButtonClass("primary")}>
          {t("finish")}
        </button>
      </div>
    </section>
  );
}
