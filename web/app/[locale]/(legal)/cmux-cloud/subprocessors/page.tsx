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
  /** `content`: processes the content that we process for teams (a subprocessor under the DPA). `controller`:
   * account, billing, and usage data, for which we are the controller (not a subprocessor). */
  readonly group: "content" | "controller";
  readonly category: string;
  readonly name: string;
  readonly purpose: string;
  readonly location: string;
};

// [LEGAL REVIEW: confirm ...]: not yet confirmed against contracts and production configuration.
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
    name: "ClickHouse, Inc. [LEGAL REVIEW: confirm]",
    purpose: "Stores usage and cost records.",
    location: "United States [LEGAL REVIEW: confirm]",
  },
  {
    group: "content",
    category: "Cloud machines",
    name: "Freestyle [LEGAL REVIEW: confirm the legal entity]",
    purpose: "Runs the cloud machines where agents work and the cloud VMs that you create.",
    location: "United States [LEGAL REVIEW: confirm]",
  },
  {
    group: "content",
    category: "Cloud machines",
    name: "Daytona [LEGAL REVIEW: confirm the legal entity]",
    purpose: "Runs Windows cloud machines.",
    location: "[LEGAL REVIEW: confirm]",
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
    name: "Anthropic, PBC; Google LLC; and other model providers reached through the routes above [LEGAL REVIEW: list here only the providers with a data processing agreement in place]",
    purpose: "AI models.",
    location: "United States [LEGAL REVIEW: confirm]",
  },
  {
    group: "content",
    category: "Meeting recording service",
    name: "Recall.ai, Inc.",
    purpose: "Joins meetings as the notetaker, records their audio, makes the transcript, and sends the live transcript, chat messages, and join and leave events to cmux during the meeting.",
    location: "United States",
  },
  {
    group: "controller",
    category: "Sign-in service",
    name: "Hexclave (Stack Auth) [LEGAL REVIEW: confirm the legal entity]",
    purpose: "Sign-in, sessions, and account management.",
    location: "United States [LEGAL REVIEW: confirm]",
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
    name: "Capless [LEGAL REVIEW: confirm the legal entity]",
    purpose: "Page and click analytics of the cmux.cloud web app, without page text.",
    location: "[LEGAL REVIEW: confirm]",
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
    location: "United States [LEGAL REVIEW: confirm]",
  },
  {
    group: "controller",
    category: "Secrets vault",
    name: "Microsoft Corporation (Azure)",
    purpose: "Runs the vault that stores encrypted access credentials for connected tools.",
    location: "United States (West US)",
  },
  {
    group: "controller",
    category: "Email delivery",
    name: "[LEGAL REVIEW: name the email provider]",
    purpose: "Sends service email.",
    location: "[LEGAL REVIEW: confirm]",
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
        dashboard. Our subprocessors process personal data only for us, to
        provide their service, under written contracts. Two groups are
        different: our payment processor (see &ldquo;Other service
        providers&rdquo;), and the providers of AI models that have no such
        contract with us (see &ldquo;AI model providers that your team
        directs&rdquo;). [LEGAL REVIEW: confirm a data processing agreement
        with each listed provider before publication.] Our{" "}
        <a href="https://cmux.com/privacy-policy#cmux-cloud">Privacy Policy</a>{" "}
        and our{" "}
        <a href="https://cmux.com/cmux-cloud/dpa">Data Processing Addendum</a>{" "}
        describe how we use them.
      </p>
      <p>
        AI model providers operate their models under their own terms. These
        terms can let a provider keep prompts and answers for a time. For most
        models, cmux Cloud asks the route to use only providers that do not
        train on the requests; for some models no such provider exists, and
        their providers can use prompts and answers to improve their models.
        [LEGAL REVIEW: owner decision on these models; see the PR comments.]
        Tools
        that you connect, such as Slack, Google, GitHub, and Linear, are not our
        subprocessors: you choose them, and their own terms apply to the data
        that agents send to them for you. When your team uses its own AI model
        provider keys or endpoints, or its own cloud machine provider account,
        that provider is your provider, not ours.
      </p>

      <p>Last updated: [LEGAL REVIEW: publication date].</p>

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

      <h2>AI model providers that your team directs</h2>
      <p>
        When your team chooses one of these models, your team instructs us to
        send the data to its provider, and that provider&rsquo;s terms apply
        (Data Processing Addendum, section 5). They are not our subprocessors.
        [LEGAL REVIEW: list these models and providers after the owner
        decision.]
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
