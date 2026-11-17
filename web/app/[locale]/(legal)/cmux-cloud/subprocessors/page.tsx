import type { Metadata } from "next";
import { legalMetadata } from "../../legal-metadata";

// DRAFT, legal review needed. Not in the sitemap and not indexed until legal sign-off.
export const metadata: Metadata = {
  ...legalMetadata(
    "/cmux-cloud/subprocessors",
    "cmux Cloud subprocessors — cmux",
    "Service providers that process personal data for cmux Cloud",
  ),
  robots: {
    index: false,
    follow: false,
  },
};

type Subprocessor = {
  readonly category: string;
  readonly name: string;
  readonly purpose: string;
  readonly location: string;
};

// [confirm]: not yet confirmed against contracts and production configuration.
const subprocessors: readonly Subprocessor[] = [
  {
    category: "Cloud hosting and storage",
    name: "Cloudflare, Inc.",
    purpose: "Runs the cmux.cloud service, stores files and conversation archives, and serves the web app.",
    location: "United States and global edge network",
  },
  {
    category: "Cloud hosting",
    name: "Vercel, Inc.",
    purpose: "Hosts the cmux.com website and the cloud machine dashboard.",
    location: "United States",
  },
  {
    category: "Database",
    name: "PlanetScale, Inc.",
    purpose: "Stores account, team, conversation, meeting, calendar, and billing records.",
    location: "United States",
  },
  {
    category: "Analytics database",
    name: "ClickHouse, Inc. [confirm]",
    purpose: "Stores usage and cost records.",
    location: "United States [confirm]",
  },
  {
    category: "Cloud machines",
    name: "Freestyle [confirm legal entity]",
    purpose: "Runs the cloud machines where agents work and the cloud VMs that you create.",
    location: "United States [confirm]",
  },
  {
    category: "Cloud machines",
    name: "Daytona [confirm legal entity]",
    purpose: "Runs cloud machines when a team chooses this provider.",
    location: "[confirm]",
  },
  {
    category: "AI model providers",
    name: "Vercel, Inc. (AI Gateway)",
    purpose: "Routes AI model requests to the model providers below.",
    location: "United States",
  },
  {
    category: "AI model providers",
    name: "OpenRouter, Inc.",
    purpose: "Routes AI model requests when the primary route is not available.",
    location: "United States",
  },
  {
    category: "AI model providers",
    name: "OpenAI, L.L.C.",
    purpose: "AI models, and speech-to-text for audio and video files.",
    location: "United States",
  },
  {
    category: "AI model providers",
    name: "Anthropic, PBC; Google LLC; and other model providers reached through the routes above [confirm list]",
    purpose: "AI models.",
    location: "United States [confirm]",
  },
  {
    category: "Meeting recording service",
    name: "Recall.ai, Inc.",
    purpose: "Joins meetings as the notetaker, records their audio, and makes the transcript.",
    location: "United States",
  },
  {
    category: "Sign-in service",
    name: "Hexclave (Stack Auth) [confirm legal entity]",
    purpose: "Sign-in, sessions, and account management.",
    location: "United States [confirm]",
  },
  {
    category: "Payment processor",
    name: "Stripe, Inc.",
    purpose: "Payments, credits, and invoices.",
    location: "United States",
  },
  {
    category: "Product analytics",
    name: "PostHog, Inc.",
    purpose: "Product usage analytics.",
    location: "United States",
  },
  {
    category: "Error monitoring",
    name: "Functional Software, Inc. (Sentry)",
    purpose: "Error and crash reports for the cmux.com website and apps.",
    location: "United States",
  },
  {
    category: "Email delivery",
    name: "[confirm provider]",
    purpose: "Sends service email.",
    location: "[confirm]",
  },
];

export default function CmuxCloudSubprocessorsPage() {
  return (
    <>
      <h1>cmux Cloud subprocessors</h1>
      <p>
        <strong>DRAFT, legal review needed.</strong> This list is not final.
      </p>
      <p>
        Manaflow, Inc. uses the service providers below to provide cmux Cloud:
        the hosted service at <a href="https://cmux.cloud">cmux.cloud</a> and
        the cloud machines that you create from the cmux app or the cmux.com
        dashboard. They process personal data only for us, to provide their
        service, under written contracts. Our{" "}
        <a href="https://cmux.com/privacy-policy#cmux-cloud">Privacy Policy</a>{" "}
        and our{" "}
        <a href="https://cmux.com/cmux-cloud/dpa">Data Processing Addendum</a>{" "}
        describe how we use them.
      </p>
      <p>
        AI model providers operate their models under their own terms. Tools
        that you connect, such as Slack, Google, GitHub, and Linear, are not our
        subprocessors: you choose them, and their own terms apply to the data
        that agents send to them for you. When your team uses its own AI model
        provider keys or endpoints, or its own cloud machine provider account,
        that provider is your provider, not ours.
      </p>

      <h2>Service providers</h2>
      <ul>
        {subprocessors.map((entry) => (
          <li key={`${entry.category}-${entry.name}`}>
            <strong>{entry.name}</strong> ({entry.category}): {entry.purpose}{" "}
            Location: {entry.location}.
          </li>
        ))}
      </ul>

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
