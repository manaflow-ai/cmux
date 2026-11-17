import type { Metadata } from "next";
import { legalMetadata } from "../../legal-metadata";

// DRAFT, legal review needed. Not in the sitemap and not indexed until legal sign-off.
export const metadata: Metadata = {
  ...legalMetadata(
    "/cmux-cloud/dpa",
    "cmux Cloud Data Processing Addendum — cmux",
    "Data Processing Addendum for teams that use cmux Cloud",
  ),
  robots: {
    index: false,
    follow: false,
  },
};

export default function CmuxCloudDpaPage() {
  return (
    <>
      <h1>cmux Cloud Data Processing Addendum</h1>
      <p>
        <strong>DRAFT, legal review needed.</strong> Items marked
        &ldquo;[LEGAL REVIEW]&rdquo; are not decided.
      </p>
      <p>
        This Data Processing Addendum (&ldquo;DPA&rdquo;) is part of the{" "}
        <a href="https://cmux.com/terms-of-service#cmux-cloud">Terms of Service</a>{" "}
        between Manaflow, Inc. (&ldquo;Company&rdquo;) and the organization that
        uses cmux Cloud (&ldquo;Customer&rdquo;). cmux Cloud means the hosted
        service at <a href="https://cmux.cloud">cmux.cloud</a> and the cloud
        machines that Customer creates from the cmux app or the cmux.com
        dashboard. If this DPA and the Terms conflict about personal data, this
        DPA controls. [LEGAL REVIEW: how Customer accepts this DPA.]
      </p>

      <h2>1. Roles</h2>
      <p>
        For personal data in the content that Customer and its users put into
        or create with cmux Cloud, including Slack data, files, meeting
        recordings and transcripts, calendar data, data from connected tools,
        agent work, and memory (&ldquo;Customer Personal Data&rdquo;), Customer
        is the controller and Company is the processor. For account, billing,
        security, and usage data that Company needs to run its business,
        Company is the controller, as the{" "}
        <a href="https://cmux.com/privacy-policy#cmux-cloud">Privacy Policy</a>{" "}
        describes.
      </p>

      <h2>2. Instructions</h2>
      <p>
        Company processes Customer Personal Data only to provide cmux Cloud,
        on Customer&rsquo;s documented instructions. The Terms, this DPA,
        Customer&rsquo;s settings and policies, and the tasks that Customer&rsquo;s
        users give to agents are those instructions. Company tells Customer if
        it believes that an instruction breaks the law. Company does not sell
        Customer Personal Data and does not use it to train generalized AI
        models.
      </p>

      <h2>3. Confidentiality and security</h2>
      <p>
        Company makes sure that its staff who can access Customer Personal Data
        are bound by confidentiality. Company keeps technical and organizational
        security measures, including encryption in transit, encrypted storage
        of access credentials, isolated cloud machines, access controls, and
        audit logs. [LEGAL REVIEW: attach a security measures annex.]
      </p>

      <h2>4. Subprocessors</h2>
      <p>
        Customer authorizes Company to use the subprocessors listed on the{" "}
        <a href="https://cmux.com/cmux-cloud/subprocessors">subprocessor page</a>.
        Company binds each subprocessor by a written contract with data
        protection duties no less protective than this DPA, where the
        subprocessor offers such terms, and stays responsible for its
        subprocessors. AI model providers operate their models under their own
        terms. [LEGAL REVIEW: AI model provider terms on each route, including
        training and retention.] Company gives notice of a new subprocessor at
        least [LEGAL REVIEW: number of] days before it starts to process
        Customer Personal Data. Customer can object on reasonable data
        protection grounds; if the parties cannot solve the objection, Customer
        can end its use of the affected service.
      </p>

      <h2>5. Assistance</h2>
      <p>
        Company helps Customer, by appropriate measures and as far as possible,
        to answer requests from individuals who use their data protection
        rights, and with data protection impact assessments and consultations
        with authorities about cmux Cloud. If Company receives such a request
        directly, it sends the request to Customer and does not answer it
        itself unless Customer agrees or the law requires it.
      </p>

      <h2>6. Personal data breaches</h2>
      <p>
        Company tells Customer without undue delay, and no later than [LEGAL
        REVIEW: number of] hours, after it becomes aware of a personal data
        breach that affects Customer Personal Data. The notice describes the
        breach, the data and people affected, the likely consequences, and the
        measures taken, as far as this information is known.
      </p>

      <h2>7. Return and deletion</h2>
      <p>
        While Customer&rsquo;s account is active, Customer can delete Customer
        Personal Data in cmux Cloud and can ask for a copy of it. When the
        account ends, Company deletes Customer Personal Data from its live
        systems within 30 days and from backups within 35 days, except data
        that the law requires Company to keep.
      </p>

      <h2>8. Audits</h2>
      <p>
        Company gives Customer the information that is reasonably necessary to
        show that Company complies with this DPA. [LEGAL REVIEW: audit rights,
        reports, and frequency.]
      </p>

      <h2>9. International transfers</h2>
      <p>
        Company and its subprocessors process Customer Personal Data in the
        United States and in other countries. [LEGAL REVIEW: transfer mechanism
        for data from the European Economic Area, the United Kingdom, and
        Switzerland. No transfer mechanism is in place today.]
      </p>

      <h2>Annex: details of processing</h2>
      <ul>
        <li>
          Subject matter and duration: providing cmux Cloud while Customer uses
          it, and until deletion as Section 7 says.
        </li>
        <li>
          Nature and purpose: hosting, storage, transcription, AI model
          processing, running agents and cloud machines, and delivering
          results, as Customer and its users ask.
        </li>
        <li>
          Data subjects: Customer&rsquo;s users; members of Customer&rsquo;s
          Slack workspace; participants in meetings that the notetaker joins;
          people whose data is in Customer&rsquo;s calendars, files, and
          connected tools.
        </li>
        <li>
          Categories of data: names, email addresses, and profile details;
          messages and files; voices, words, and names in meeting recordings
          and transcripts; calendar event details; code and other content in
          connected tools and cloud machines; memory.
        </li>
        <li>
          Special categories: none intended. Customer must not use cmux Cloud
          for special categories of data unless Company agreed to it in
          writing.
        </li>
      </ul>
    </>
  );
}
