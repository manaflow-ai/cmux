// The only product facts paywall and pricing copy may state. Every served
// experiment payload is checked against this file (validator.ts): a number in
// the copy must be one of these quantities, and claims on the deny list below
// are rejected. Keep it in step with https://cmux.com/pricing and the docs it
// cites; a fact that is no longer true must be removed here first.
//
// Shared by the iOS paywall experiment and the web pricing-page experiment.

/** A unit a number in copy can carry. `null` means a bare number. */
export type FactUnit = "vm" | "vcpu" | "gb" | "vm-hour" | "day";

export type ProductFact = {
  /** Plain statement of the fact. */
  readonly text: string;
  /** Where it is published. */
  readonly source: string;
  /** The quantities the fact states, as `[number, unit]`. */
  readonly quantities: readonly (readonly [number, FactUnit])[];
};

export const PRODUCT_FACTS: readonly ProductFact[] = [
  {
    text: "Pro includes up to 5 Cloud VMs sharing 20 vCPUs and 40 GB RAM.",
    source: "https://cmux.com/pricing",
    quantities: [[5, "vm"], [20, "vcpu"], [40, "gb"]],
  },
  {
    text: "On Pro one VM can have up to 8 vCPUs and 16 GB RAM.",
    source: "https://cmux.com/pricing",
    quantities: [[8, "vcpu"], [16, "gb"]],
  },
  {
    text: "Max includes up to 5 Cloud VMs sharing 80 vCPUs and 160 GB RAM.",
    source: "https://cmux.com/pricing",
    quantities: [[5, "vm"], [80, "vcpu"], [160, "gb"]],
  },
  {
    text: "Max unlocks VM sizes of 12 vCPUs and 24 GB, 16 vCPUs and 32 GB, and up to 32 vCPUs and 64 GB on one VM.",
    source: "https://cmux.com/pricing",
    quantities: [[12, "vcpu"], [24, "gb"], [16, "vcpu"], [32, "gb"], [32, "vcpu"], [64, "gb"]],
  },
  {
    text: "Go includes 1 Cloud VM with 2 vCPUs and 4 GB RAM and 40 VM-hours a month.",
    source: "iOS plan copy (Packages/iOS/CmuxMobileBilling BillingPlanCopy) and services/vms/goUsage.ts (GO_INCLUDED_VM_HOURS)",
    quantities: [[1, "vm"], [2, "vcpu"], [4, "gb"], [40, "vm-hour"]],
  },
  {
    text: "Pro and Max include the iOS app, email support and unlimited workspaces.",
    source: "https://cmux.com/pricing",
    quantities: [],
  },
  {
    text: "Cloud VMs are persistent Linux machines that keep their files, installed tools and state.",
    source: "https://cmux.com/pricing (FAQ)",
    quantities: [],
  },
  {
    text: "Terminals on a Cloud VM keep running when you close your laptop or your Mac sleeps, so coding agents keep working.",
    source: "https://cmux.com/docs (Cloud overview and Cloud workspaces: 'keep running when you ... shut your laptop'; Base: 'while your MacBook is asleep')",
    quantities: [],
  },
  {
    text: "Agents clone repositories, run commands and open pull requests on the VM without touching your Mac.",
    source: "https://cmux.com/pricing (FAQ)",
    quantities: [],
  },
  {
    text: "Yearly billing costs less per month than monthly billing.",
    source: "https://cmux.com/pricing (yearly prices); the app shows the StoreKit price",
    quantities: [],
  },
];

/** `unlimited` is allowed only in these phrases, because the facts say so. */
export const UNLIMITED_PHRASES: readonly string[] = ["unlimited workspaces"];

/**
 * Whether a free trial product exists. False until the trial experiment
 * ships its products; while false, copy may not mention a trial.
 */
export const FREE_TRIAL_AVAILABLE = false;

/**
 * Claims that are true of some cmux offering but not of the personal plans a
 * paywall sells, or that are not published at all. Matched as whole words,
 * case-insensitive.
 */
export const UNSUPPORTED_CLAIMS: readonly string[] = [
  "gpu",
  "gpus",
  "sso",
  "saml",
  "sla",
  "soc 2",
  "priority support",
  "dedicated support",
  "24/7",
  "self-hosted",
  "self hosted",
  "air-gapped",
  "audit logs",
  "lifetime",
  "forever",
  "money-back",
  "money back",
  "refund",
  "no credit card",
];

/** Every number a fact states. */
export const FACT_NUMBERS: ReadonlySet<number> = new Set(
  PRODUCT_FACTS.flatMap((fact) => fact.quantities.map(([value]) => value)),
);

/** Every `number unit` pair a fact states, as `"5 vm"`. */
export const FACT_QUANTITIES: ReadonlySet<string> = new Set(
  PRODUCT_FACTS.flatMap((fact) => fact.quantities.map(([value, unit]) => `${value} ${unit}`)),
);
