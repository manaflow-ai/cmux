import type { Metadata } from "next";
import { legalMetadata } from "../../legal-metadata";

export const metadata: Metadata = {
  ...legalMetadata(
    "/cmux-cloud/dpa",
    "cmux Cloud Data Processing Addendum — cmux",
    "Data Processing Addendum for teams that use cmux Cloud",
  ),
};

export default function CmuxCloudDpaPage() {
  return (
    <>
      <h1>cmux Cloud Data Processing Addendum</h1>
      <p>Last updated: November 17, 2026.</p>
      <p>
        This Data Processing Addendum (&ldquo;DPA&rdquo;) is part of the{" "}
        <a href="https://cmux.com/terms-of-service#cmux-cloud">Terms of Service</a>{" "}
        between Manaflow, Inc. (&ldquo;Company&rdquo;) and the organization or
        person that is the customer under the Terms (&ldquo;Customer&rdquo;). cmux Cloud means the hosted
        service at <a href="https://cmux.cloud">cmux.cloud</a> and the cloud
        machines that Customer creates from the cmux app or the cmux.com
        dashboard. Customer accepts this DPA when it accepts the Terms. This DPA
        applies where data protection law requires a contract of this type, and
        for as long as Company processes Customer Personal Data. If this DPA and
        the Terms conflict about personal data, this DPA controls.
      </p>

      <h2>1. Roles</h2>
      <p>
        For personal data in the content that Customer and its users put into
        or create with cmux Cloud, including Slack data, files, meeting
        audio recordings and transcripts, the meeting service&rsquo;s records
        of participants joining and leaving and of the meeting chat (including
        messages sent to the notetaker), calendar data, data from connected
        tools, agent work, model call requests and answers, archive copies of
        agent conversations, and memory (&ldquo;Customer Personal Data&rdquo;), Customer
        is the controller and Company is the processor. The access credentials
        that Company stores to reach connected accounts are Company&rsquo;s
        security data; the content read from or sent through those accounts is
        Customer Personal Data. For account, billing, security, usage, support,
        and feedback data that Company needs to run
        its business (where feedback contains Customer Personal Data, Company
        uses that part only to examine and fix what the feedback reports),
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
        law. Company does not follow an instruction that would break the
        Google API Services User Data Policy or the Slack API Terms, and tells
        Customer. Company does not sell Customer Personal Data and does not use
        it to train generalized AI models. Company keeps usage records (counts,
        sizes, times, models, and costs, with account identifiers) as a
        controller for billing, security, and service improvement; these
        records are not made from content, but can contain the names that
        Customer gave to agents, machines, and projects, and error messages
        from providers.
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
        are bound by confidentiality. Company uses appropriate technical and
        organizational measures to give a level of security appropriate to the
        risk, as Article 32 GDPR requires, including at least the measures in
        the Security annex below. Company can change the measures but does not
        lower the overall level of security.
      </p>

      <h2>5. Subprocessors</h2>
      <p>
        Customer gives Company general authorization to use subprocessors. The
        current subprocessors are in the list &ldquo;Subprocessors&rdquo; on
        the{" "}
        <a href="https://cmux.com/cmux-cloud/subprocessors">subprocessor page</a>.
        Company imposes on each subprocessor, by a written contract, the data
        protection duties that Article 28(3) and (4) GDPR and, for
        subcontractors, US state privacy laws require, including
        confidentiality, security, assistance, breach notice, return or
        deletion, and help with audits, and Company stays fully
        liable to Customer for each subprocessor&rsquo;s performance. Company
        gives notice of a new subprocessor at least 30
        days before it starts to process Customer Personal Data, by an update
        of the subprocessor page and an email to Customer&rsquo;s team
        administrators. Customer can object in writing in that time on reasonable data
        protection grounds. If the parties cannot solve the objection, Customer
        can end its use of the affected service.
      </p>
      <p>
        AI models and providers that Customer chooses. Customer chooses the AI
        models that cmux Cloud uses for it. On the calls that Company pays for,
        Company sends requests only to providers that do not train their
        models on them. For AI models, the subprocessors are the routes that the
        subprocessor page names; the provider of a model is shown with the model
        in cmux Cloud, and Customer authorizes that provider when it or its users
        choose the model. Web search and page-reading services that agents use
        receive only search words and addresses of public pages; Customer
        instructs Company to send these to them, and they are not
        subprocessors. Where Customer uses its own provider keys, endpoints,
        or cloud machine account, that provider is not Company&rsquo;s
        subprocessor: Customer instructs Company to send Customer Personal
        Data to that provider, and that provider&rsquo;s terms apply.
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
        Company tells Customer without undue delay, and no later than 72 hours, after it becomes aware of a personal data
        breach that affects Customer Personal Data. The notice describes the
        breach, the data and people affected, the likely consequences, and the
        measures taken, as far as this information is known.
      </p>

      <h2>8. Return and deletion</h2>
      <p>
        While Customer&rsquo;s account is active, Customer can delete
        conversations, files, and memory in cmux Cloud and can ask for a copy of
        Customer Personal Data. This does not delete the model call records and
        the archive copy of agent conversations; Company deletes those within
        30 days after Customer&rsquo;s written request to founders@cmux.com. At
        Customer&rsquo;s choice, Company returns (gives a copy of) or deletes
        Customer Personal Data when the account ends. Until Company deletes the
        data from its live systems, Customer can ask for a copy. Company deletes
        Customer Personal Data from its live systems when Customer asks (at
        once or 30 days after the request) and, once the automatic deletion
        after the account ends is on, 30 days after the account ends; backups that still hold it expire
        within 35 days after that deletion. Copies in the logs, traces, and
        error reports of Company&rsquo;s log and error monitoring providers and
        in the logs of AI model providers expire after the periods listed in
        the Privacy Policy; until then they
        stay confidential and are not used for another purpose. This does not
        apply to data that the law requires Company to keep. Company keeps that data confidential
        and does not use it for another purpose.
      </p>

      <h2>9. Audits</h2>
      <p>
        Company makes available to Customer all information necessary to show
        that Company complies with this DPA, and allows and contributes to
        audits, including inspections, by Customer, an auditor that Customer
        chooses and that is bound by confidentiality, or a competent
        authority. Customer can first use the reports and written answers that
        Company gives, but this does not limit its audit right. An audit
        normally takes place once in 12 months, with 30 days&rsquo; written
        notice, in business hours, at Customer&rsquo;s cost, and without
        access to the data of other customers. These limits do not stop an
        audit that the law or an authority requires, or an audit after a
        personal data breach or for a reasonable compliance concern.
      </p>

      <h2>10. International transfers</h2>
      <p>
        Company and its subprocessors process Customer Personal Data in the
        United States and in other countries. Where Customer Personal Data that
        is subject to the GDPR, the UK GDPR, or the Swiss Federal Act on Data
        Protection is transferred to Company in a country without an adequacy
        decision, the Standard Contractual Clauses of Commission Implementing
        Decision (EU) 2021/914 are part of this DPA: Module Two where Customer
        is a controller and Module Three where Customer is a processor.
        Customer is the data exporter and Company is the data importer. Clause
        7 does not apply. Clause 9(a) Option 2 applies, with the notice time of
        Section 5. The optional text of Clause 11(a) does not apply. For
        Clauses 17 and 18, the law and the courts are those of Ireland. Annex I
        of the Clauses is the Annex of this DPA, Annex II is the Security annex,
        and Annex III is the subprocessor page. For transfers subject to the UK
        GDPR, the International Data Transfer Addendum to the EU Commission
        Standard Contractual Clauses (version B1.0) issued by the UK
        Information Commissioner is part of this DPA with the same details. For
        transfers subject to the Swiss Federal Act on Data Protection,
        references to the GDPR are read as references to that Act, and the
        competent authority is the Swiss Federal Data Protection and
        Information Commissioner; the term &ldquo;Member State&rdquo; does not
        stop a person in Switzerland from bringing a claim at their place of
        residence. Clause 17 Option 1 applies. Annex I.A: the data exporter is
        Customer, with the contact details of its account; the data importer
        is Manaflow, Inc., 18428 Vantage Pointe Dr, Rowland Heights, CA
        91748-5142, United States, founders@cmux.com. Annex I.B: the transfers
        are continuous, for the duration in the Annex of this DPA. Annex I.C:
        the competent supervisory authority is the authority that Clause 13
        gives for Customer. For the UK Addendum, Table 4: neither party can end
        the Addendum when the approved addendum changes.
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
        Section 6 says. Customer tells Company of each consumer request that
        Company must act on and gives the information that Company needs.
      </p>

      <h2>Annex: details of processing</h2>
      <ul>
        <li>
          Subject matter and duration: providing cmux Cloud while Customer uses
          it, and until deletion as Section 8 says.
        </li>
        <li>
          Nature and purpose: hosting, storage, joining meetings, recording
          audio, receiving, reading, keeping for the time of the meeting, and
          deleting live transcript lines, meeting chat messages, and participant
          records; answering questions and passing on requests that participants
          type to the notetaker; transcription, writing notes, AI model processing, running
          agents and cloud machines, delivering results, and keeping or deleting
          archive copies, as Customer and its users ask.
        </li>
        <li>
          Data subjects: Customer&rsquo;s users; members of Customer&rsquo;s
          Slack workspace; participants in meetings that the notetaker joins;
          people whose data is in Customer&rsquo;s calendars, files, and
          connected tools; people who visit the apps, pages, and links that
          Customer publishes with cmux Cloud.
        </li>
        <li>
          Categories of data: names, email addresses, and profile details;
          messages and files; voices, words, and names in meeting audio
          recordings and transcripts; meeting participant join and leave times
          and meeting chat messages; questions and requests typed to the
          notetaker; model call requests and answers; calendar
          event details; code and other
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
        <li>Encrypted storage of access credentials in a secrets vault; systems designed so that credentials are not given to AI models.</li>
        <li>Isolated cloud machines for agent work.</li>
        <li>Access controls for staff.</li>
        <li>Audit logs of actions, approvals, and policy decisions.</li>
      </ul>
    </>
  );
}
