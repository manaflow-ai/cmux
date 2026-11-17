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
        dashboard. Customer accepts this DPA when it accepts the Terms. [LEGAL
        REVIEW: how the acceptance is shown in the sign-up flow.] This DPA
        applies where data protection law requires a contract of this type, and
        for as long as Company processes Customer Personal Data. If this DPA and
        the Terms conflict about personal data, this DPA controls.
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
        Company processes Customer Personal Data only to provide, secure, and
        support cmux Cloud, on Customer&rsquo;s documented instructions,
        including for transfers of personal data to another country. The Terms,
        this DPA, Customer&rsquo;s settings and policies, the AI models and
        tools that Customer chooses, and the tasks that Customer&rsquo;s users
        give to agents are those instructions. If a law that applies to Company
        requires other processing, Company tells Customer before that
        processing, unless that law forbids it. Company tells Customer
        immediately if it believes that an instruction breaks data protection
        law. Company does not sell Customer Personal Data and does not use it
        to train generalized AI models.
      </p>

      <h2>3. Customer&rsquo;s duties</h2>
      <p>
        Customer is responsible for the lawfulness of its instructions and of
        the personal data that it puts into cmux Cloud. Customer gives the
        notices and has the legal basis, and the consent where the law requires
        it, for that processing. This includes notice to its users, to the
        members of its Slack workspace, and to the participants of meetings
        that it sends the notetaker to, including participants who cannot see
        the notetaker&rsquo;s notices.
      </p>

      <h2>4. Confidentiality and security</h2>
      <p>
        Company makes sure that its staff who can access Customer Personal Data
        are bound by confidentiality. Company keeps the technical and
        organizational security measures in the Security annex below.
      </p>

      <h2>5. Subprocessors</h2>
      <p>
        Customer gives Company general authorization to use subprocessors. The
        current subprocessors are on the{" "}
        <a href="https://cmux.com/cmux-cloud/subprocessors">subprocessor page</a>.
        Company binds each subprocessor by a written contract with the same
        data protection duties as this DPA in substance, and Company stays fully
        liable to Customer for each subprocessor&rsquo;s performance. Company
        gives notice of a new subprocessor at least [LEGAL REVIEW: proposed 30]
        days before it starts to process Customer Personal Data, by an update
        of the subprocessor page and an email to Customer&rsquo;s notice
        address. Customer can object in writing in that time on reasonable data
        protection grounds. If the parties cannot solve the objection, Customer
        can end its use of the affected service.
      </p>
      <p>
        AI models and providers that Customer chooses. Customer chooses the AI
        models that cmux Cloud uses for it. Where Customer chooses a model that
        is run only by providers that do not offer terms that meet this
        section, or uses its own provider keys, endpoints, or cloud machine
        account, that provider is not Company&rsquo;s subprocessor: Customer
        instructs Company to send Customer Personal Data to that provider, and
        that provider&rsquo;s terms apply. [LEGAL REVIEW: owner decision on
        models whose providers can train on prompts; see the PR comments.]
      </p>

      <h2>6. Assistance</h2>
      <p>
        Company helps Customer, by appropriate measures and as far as possible,
        to answer requests from individuals who use their data protection
        rights. Company also helps Customer, with the information that Company
        has, to meet its duties about security, personal data breach notices,
        data protection impact assessments, and consultations with authorities.
        If Company receives a request from an individual about Customer
        Personal Data, it sends the request to Customer and does not answer it
        itself unless Customer agrees or the law requires it.
      </p>

      <h2>7. Personal data breaches</h2>
      <p>
        Company tells Customer without undue delay, and no later than [LEGAL
        REVIEW: proposed 72] hours, after it becomes aware of a personal data
        breach that affects Customer Personal Data. The notice describes the
        breach, the data and people affected, the likely consequences, and the
        measures taken, as far as this information is known.
      </p>

      <h2>8. Return and deletion</h2>
      <p>
        While Customer&rsquo;s account is active, Customer can delete Customer
        Personal Data in cmux Cloud and can ask for a copy of it. At
        Customer&rsquo;s choice, Company returns (gives a copy of) or deletes
        Customer Personal Data when the account ends. Until Company deletes the
        data from its live systems, Customer can ask for a copy. Company deletes
        Customer Personal Data from its live systems 30 days after the account
        ends, or sooner if Customer asks, and from backups within 35 days after
        the account ends, except data that the law requires Company to keep.
        Company keeps that data confidential and does not use it for another
        purpose. [LEGAL REVIEW: effective when the deletion job ships; see the
        PR comments.]
      </p>

      <h2>9. Audits</h2>
      <p>
        Company gives Customer all information necessary to show that Company
        complies with this DPA, and allows and helps with audits, including
        inspections, by Customer or an auditor that Customer chooses and that
        is bound by confidentiality. Customer first uses the reports and
        written answers that Company gives. If these do not show compliance, or
        after a personal data breach or an order of a regulator, Customer can
        audit once in 12 months, with 30 days&rsquo; written notice, in
        business hours, at Customer&rsquo;s cost, and without access to the
        data of other customers.
      </p>

      <h2>10. International transfers</h2>
      <p>
        Company and its subprocessors process Customer Personal Data in the
        United States and in other countries. [LEGAL REVIEW: owner decision on
        the transfer mechanism for data from the European Economic Area, the
        United Kingdom, and Switzerland (Standard Contractual Clauses in this
        DPA, the EU-US Data Privacy Framework, or no offer there yet). No
        transfer mechanism is in place today. Do not publish this section
        before that decision.]
      </p>

      <h2>11. US state privacy laws</h2>
      <p>
        Where the California Consumer Privacy Act or a similar US state law
        applies, Company is Customer&rsquo;s service provider. Customer
        discloses Customer Personal Data to Company only for these business
        purposes: hosting and storage, transcription, AI model processing,
        running agents and cloud machines, delivering results, security, and
        support of cmux Cloud. Company does not sell or share Customer Personal
        Data. Company does not keep, use, or disclose it for any other purpose
        or outside its direct business relationship with Customer, and does
        not combine it with personal data from other sources, except as that
        law permits. Company complies with that law and gives the level of
        privacy protection that it requires. Company tells Customer within 5
        business days if it can no longer meet these duties. Customer can take
        reasonable and appropriate steps to make sure that Company uses the
        data as this DPA says, and, after notice, to stop and correct
        unauthorized use. Company helps Customer answer consumer requests as
        Section 6 says.
      </p>

      <h2>Annex: details of processing</h2>
      <ul>
        <li>
          Subject matter and duration: providing cmux Cloud while Customer uses
          it, and until deletion as Section 8 says.
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
          messages and files; voices, words, and names in meeting audio
          recordings and transcripts; calendar event details; code and other
          content in connected tools and cloud machines; memory.
        </li>
        <li>
          Special categories: Customer Personal Data can include special
          categories of data where Customer&rsquo;s users put them into
          messages, meetings, or files. Customer must not use cmux Cloud for
          the purpose of processing special categories of data, protected
          health information, or payment card data, unless Company agreed to it
          in writing.
        </li>
      </ul>

      <h2>Security annex</h2>
      <ul>
        <li>Encryption of data in transit.</li>
        <li>Encrypted storage of access credentials in a secrets vault; credentials are not given to AI models.</li>
        <li>Isolated cloud machines for agent work.</li>
        <li>Access controls for staff.</li>
        <li>Audit logs of actions, approvals, and policy decisions.</li>
        <li>
          [LEGAL REVIEW: add encryption at rest, staff multi-factor sign-in,
          incident response, and backups only after each is confirmed true.]
        </li>
      </ul>
    </>
  );
}
