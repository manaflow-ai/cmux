// A model the person cannot use is never a dead end (Leo 2026-10-26: "if user picks a model they
// don't have api key, we offer them to add credits or add their own api key"). This is the Add
// Credits half, run on the person's click in the pane (AgentPaneModel+Actions.swift accessActions):
// Add Credits… is the one paid-plan path every paywall takes (PaidPlanUpgrade, source inference),
// Checkout on cmux.com that returns to this app, else the pricing page.
// Where it shows: a failed turn the cmux model router refused (failureCopy.ts `needs-credits`: no paid
// plan and no credits, `inference.plan_required`, or a credit-funded caller still without a paid plan
// whose credits do not cover the call, `credits.insufficient`; backend inference/route.ts
// resolveCaller), both lifted by a paid plan. Not the model picker: credits pay only for the cmux model
// router, so a signed-out local harness keeps its own Log In alone. Add API Key… waits for key plumbing: no placement makes a saved key usable yet (acpmux
// starts local harnesses with the login environment and their own sign-in, and the router uses only
// its own server keys), so nothing offers it.

/// The app action behind the offer. The host runs it only on the person's gesture in the pane.
export const ACCESS_ACTIONS = { addCredits: "palette.pro.upgrade" } as const;

/// The offer as the pane wires it.
export type AccessOffer = {
  addCredits(): void;
};
