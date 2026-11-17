import type { Metadata } from "next";
import { legalMetadata } from "../../legal-metadata";

// Published without counsel on the owner's instruction (2026-11-17).
export const metadata: Metadata = {
  ...legalMetadata(
    "/cmux-cloud/subprocessors",
    "cmux Cloud subprocessors — cmux",
    "Service providers that process personal data for cmux Cloud",
  ),
};

type Subprocessor = {
  /** `content`: processes the content that we process for teams (a subprocessor under the DPA). `controller`:
   * account, billing, and usage data, for which we are the controller (not a subprocessor). */
  readonly group: "content" | "controller";
  readonly category: string;
  readonly name: string;
  readonly purpose: string;
  readonly location: string;
};

// Names are the providers' service names; a location is given where it is known.
const subprocessors: readonly Subprocessor[] = [
  {
    group: "content",
    category: "Cloud hosting and storage",
    name: "Cloudflare, Inc.",
    purpose: "Runs the cmux.cloud service, stores files and conversation archives, serves the web app, and runs open AI models (Workers AI).",
    location: "United States and global edge network",
  },
  {
    group: "content",
    category: "Cloud hosting",
    name: "Vercel, Inc.",
    purpose: "Hosts the cmux.com website and the cloud machine dashboard.",
    location: "United States",
  },
  {
    group: "content",
    category: "Database",
    name: "PlanetScale, Inc.",
    purpose: "Stores account, team, conversation, meeting, calendar, and billing records.",
    location: "United States",
  },
  {
    group: "controller",
    category: "Analytics database",
    name: "ClickHouse",
    purpose: "Stores usage and cost records.",
    location: "See the provider's privacy policy",
  },
  {
    group: "content",
    category: "Cloud machines",
    name: "Freestyle",
    purpose: "Runs the cloud machines where agents work and the cloud VMs that you create.",
    location: "See the provider's privacy policy",
  },
  {
    group: "content",
    category: "Cloud machines",
    name: "Daytona",
    purpose: "Runs Windows cloud machines.",
    location: "See the provider's privacy policy",
  },
  {
    group: "content",
    category: "AI model providers",
    name: "Vercel, Inc. (AI Gateway)",
    purpose: "Routes AI model requests to the model providers below.",
    location: "United States",
  },
  {
    group: "content",
    category: "AI model providers",
    name: "OpenRouter, Inc.",
    purpose: "Routes AI model requests when the primary route is not available.",
    location: "United States",
  },
  {
    group: "content",
    category: "AI model providers",
    name: "OpenAI, L.L.C.",
    purpose: "AI models, and speech-to-text for audio and video files.",
    location: "United States",
  },
  {
    group: "content",
    category: "AI model providers",
    name: "The provider of each AI model that your team uses on the routes above (for example Anthropic, PBC, OpenAI, L.L.C., and Google LLC)",
    purpose: "AI models.",
    location: "See the provider's privacy policy",
  },
  {
    group: "content",
    category: "Web search and page reading",
    name: "Exa",
    purpose: "Receives the search words that agents write and the addresses of public pages.",
    location: "See the provider's privacy policy",
  },
  {
    group: "content",
    category: "Page reading",
    name: "Jina AI",
    purpose: "Receives the addresses of public pages that agents read.",
    location: "See the provider's privacy policy",
  },
  {
    group: "content",
    category: "Page reading",
    name: "Internet Archive",
    purpose: "Receives the addresses of public pages that agents read.",
    location: "United States",
  },
  {
    group: "content",
    category: "Meeting recording service",
    name: "Recall.ai, Inc.",
    purpose: "Joins meetings as the notetaker, records their audio, makes the transcript, sends the live transcript, chat messages, and join and leave events to cmux during the meeting, and posts the notices and answers in the meeting chat.",
    location: "United States",
  },
  {
    group: "controller",
    category: "Sign-in service",
    name: "Hexclave (Stack Auth)",
    purpose: "Sign-in, sessions, account management, and sign-in emails.",
    location: "See the provider's privacy policy",
  },
  {
    group: "controller",
    category: "Payment processor",
    name: "Stripe, Inc.",
    purpose: "Payments, credits, and invoices.",
    location: "United States",
  },
  {
    group: "controller",
    category: "Product analytics",
    name: "Capless",
    purpose: "Page and click analytics of the cmux.cloud web app, without page text.",
    location: "See the provider's privacy policy",
  },
  {
    group: "controller",
    category: "Product analytics",
    name: "PostHog, Inc.",
    purpose: "Product usage analytics.",
    location: "United States",
  },
  {
    group: "content",
    category: "Error monitoring",
    name: "Functional Software, Inc. (Sentry)",
    purpose: "Error reports and performance traces for cmux.cloud, the cmux.com website, and the apps.",
    location: "United States",
  },
  {
    group: "content",
    category: "Logs and traces",
    name: "Axiom, Inc.",
    purpose: "Stores service logs and traces of cmux.cloud.",
    location: "See the provider's privacy policy",
  },
  {
    group: "content",
    category: "Secrets vault",
    name: "Microsoft Corporation (Azure)",
    purpose: "Runs the vault that stores encrypted access credentials and makes the calls to connected tools that need them; the content of those calls passes through it.",
    location: "United States (West US)",
  },
];

export default function CmuxCloudSubprocessorsPage() {
  return (
    <>
      <h1>cmux Cloud subprocessors</h1>
      <p>
        Manaflow, Inc. uses the service providers below to provide cmux Cloud:
        the hosted service at <a href="https://cmux.cloud">cmux.cloud</a> and
        the cloud machines that you create from the cmux app or the cmux.com
        dashboard. Our subprocessors process personal data for us, to provide
        their service, under their terms with us. Our payment processor also
        uses payment data for its own purposes (see &ldquo;Other service
        providers&rdquo;). Our{" "}
        <a href="https://cmux.com/privacy-policy#cmux-cloud">Privacy Policy</a>{" "}
        and our{" "}
        <a href="https://cmux.com/cmux-cloud/dpa">Data Processing Addendum</a>{" "}
        describe how we use them.
      </p>
      <p>
        AI model providers operate their models under their own terms. These
        terms can let a provider keep prompts and answers for a time. On the
        calls that we pay for, cmux Cloud sends requests only to providers that
        do not train their models on them.
        Tools
        that you connect, such as Slack, Google, GitHub, and Linear, are not our
        subprocessors: you choose them, and their own terms apply to the data
        that agents send to them for you. When your team uses its own AI model
        provider keys or endpoints, or its own cloud machine provider account,
        that provider is your provider, not ours.
      </p>

      <p>Last updated: November 17, 2026.</p>

      <h2>Subprocessors</h2>
      <p>They process the content that we process for teams, under the Data Processing Addendum.</p>
      <ul>
        {subprocessors
          .filter((entry) => entry.group === "content")
          .map((entry) => (
            <li key={`${entry.category}-${entry.name}`}>
              <strong>{entry.name}</strong> ({entry.category}): {entry.purpose}{" "}
              Location: {entry.location}.
            </li>
          ))}
      </ul>

      <h2>Other service providers</h2>
      <p>
        They process account, billing, and usage data, for which we are the
        controller. Our payment processor also uses payment data for its own
        purposes, such as fraud prevention and its legal duties, under its own
        privacy policy.
      </p>
      <ul>
        {subprocessors
          .filter((entry) => entry.group === "controller")
          .map((entry) => (
            <li key={`${entry.category}-${entry.name}`}>
              <strong>{entry.name}</strong> ({entry.category}): {entry.purpose}{" "}
              Location: {entry.location}.
            </li>
          ))}
      </ul>

      <h2>Providers that your team directs</h2>
      <p>
        When your team uses its own AI model provider keys or endpoints, or its
        own cloud machine provider account, your team instructs us to send the
        data to that provider, and that provider&rsquo;s terms apply (Data
        Processing Addendum, section 5). They are not our subprocessors.
      </p>

      <h2>Changes to this list</h2>
      <p>
        We update this page before a new subprocessor starts to process
        personal data for cmux Cloud. Teams that accepted our Data Processing
        Addendum get notice as that addendum describes. For questions, contact{" "}
        <a href="mailto:founders@cmux.com">founders@cmux.com</a>.
      </p>
    </>
  );
}
