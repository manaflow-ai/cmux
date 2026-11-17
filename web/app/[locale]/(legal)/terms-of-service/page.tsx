import type { Metadata } from "next";
import { legalMetadata } from "../legal-metadata";
import { getCurrentYear } from "@/app/lib/current-year";

export const metadata: Metadata = legalMetadata(
  "/terms-of-service",
  "Terms of Service — cmux",
  "Terms of service for the cmux website, macOS application, and cmux Cloud",
);

export default async function TermsOfServicePage() {
  const currentYear = await getCurrentYear();

  return (
    <>
      <h1>Terms of Service</h1>
      <p>Last revised on: March 18, 2026 [LEGAL REVIEW: set the publication date]</p>

      <p>
        The website located at{" "}
        <a href="https://cmux.com">cmux.com</a> (the
        &ldquo;Site&rdquo;) and the cmux desktop application (the
        &ldquo;Application&rdquo;) are copyrighted works belonging to Manaflow, Inc., a [LEGAL REVIEW:
        state of incorporation] corporation, 18428 Vantage Pointe Dr, Rowland
        Heights, CA 91748-5142, United States (&ldquo;Company&rdquo;, &ldquo;us&rdquo;, &ldquo;our&rdquo;, and
        &ldquo;we&rdquo;). These Terms of Use (these &ldquo;Terms&rdquo;) set
        forth the legally binding terms and conditions that govern your use of
        the Site and Application.
      </p>
      <p>
        By accessing or using the Site or Application, you are accepting these
        Terms and you represent and warrant that you have the right, authority,
        and capacity to enter into these Terms. You may not access or use the
        Site or Application if you are not at least 18 years old. If you do not
        agree with all of the provisions of these Terms, do not access and/or
        use the Site or Application.
      </p>
      <p>
        If you use cmux Cloud, Section 10 also applies to you. [LEGAL REVIEW:
        how acceptance is shown at sign-up and at the Slack install step.]
      </p>

      <h2>1. License</h2>
      <p>
        Subject to these Terms, Company grants you a non-transferable,
        non-exclusive, revocable, limited license to use and access the Site and
        Application for your personal or internal business purposes, including
        commercial use in connection with your software development activities.
      </p>

      <h3>Restrictions</h3>
      <p>The rights granted to you are subject to the following restrictions:</p>
      <ul>
        <li>
          You shall not license, sell, rent, lease, transfer, assign,
          distribute, host, or otherwise commercially exploit the Application
        </li>
        <li>
          You shall not modify, make derivative works of, disassemble, reverse
          compile or reverse engineer any part of the Application
        </li>
        <li>
          You shall not access the Application in order to build a similar or
          competitive product
        </li>
      </ul>

      <h3>Modification</h3>
      <p>
        Company reserves the right, at any time, to modify, suspend, or
        discontinue the Site or Application with or without notice to you.
        Company will not be liable to you or any third party for any
        modification, suspension, or discontinuation.
      </p>

      <h3>Ownership</h3>
      <p>
        You acknowledge that all intellectual property rights, including
        copyrights, patents, trademarks, and trade secrets, in the Application
        and its content (not including Your Content as defined in Section 10)
        are owned by Company or Company&rsquo;s suppliers.
        These Terms do not transfer to you any rights, title or interest in such
        intellectual property, except for the limited license above. Company and
        its suppliers reserve all rights not granted in these Terms.
      </p>

      <h3>Feedback</h3>
      <p>
        If you provide Company with any feedback or suggestions regarding the
        Application, you hereby assign to Company all rights in such feedback
        and agree that Company shall have the right to use such feedback in any
        manner it deems appropriate.
      </p>

      <h2>2. User Content</h2>
      <p>
        You retain full ownership of all code, files, and content you create or
        process using the Application. The Application runs locally on your
        device and your content is not transmitted to our servers during normal
        use. cmux Cloud is different: it processes your content on our servers,
        as Section 10 and our{" "}
        <a href="https://cmux.com/privacy-policy#cmux-cloud">Privacy Policy</a>{" "}
        describe.
      </p>

      <h2>3. Indemnification</h2>
      <p>
        You agree to indemnify and hold Company (and its officers, employees,
        and agents) harmless, including costs and attorneys&rsquo; fees, from
        any claim or demand made by any third party due to or arising out of (a)
        your use of the Application, (b) your violation of these Terms, or (c)
        your violation of applicable laws or regulations.
      </p>

      <h2>4. Third-Party Links</h2>
      <p>
        The Site may contain links to third-party websites and services. Such
        links are not under the control of Company, and Company is not
        responsible for them. You use all third-party links at your own risk.
      </p>

      <h2>5. Disclaimers</h2>
      <p>
        THE APPLICATION IS PROVIDED ON AN &ldquo;AS-IS&rdquo; AND &ldquo;AS
        AVAILABLE&rdquo; BASIS. COMPANY EXPRESSLY DISCLAIMS ANY AND ALL
        WARRANTIES AND CONDITIONS OF ANY KIND, WHETHER EXPRESS, IMPLIED, OR
        STATUTORY, INCLUDING ALL WARRANTIES OF MERCHANTABILITY, FITNESS FOR A
        PARTICULAR PURPOSE, TITLE, AND NON-INFRINGEMENT.
      </p>
      <p>
        SOME JURISDICTIONS DO NOT ALLOW THE EXCLUSION OF IMPLIED WARRANTIES, SO
        THE ABOVE EXCLUSION MAY NOT APPLY TO YOU.
      </p>

      <h2>6. Limitation on Liability</h2>
      <p>
        TO THE MAXIMUM EXTENT PERMITTED BY LAW, IN NO EVENT SHALL COMPANY BE
        LIABLE TO YOU OR ANY THIRD PARTY FOR ANY LOST PROFITS, LOST DATA, OR ANY
        INDIRECT, CONSEQUENTIAL, EXEMPLARY, INCIDENTAL, SPECIAL OR PUNITIVE
        DAMAGES ARISING FROM OR RELATING TO THESE TERMS OR YOUR USE OF THE
        APPLICATION.
      </p>
      <p>
        TO THE MAXIMUM EXTENT PERMITTED BY LAW, OUR LIABILITY TO YOU FOR ANY
        DAMAGES WILL AT ALL TIMES BE LIMITED TO THE GREATER OF FIFTY US DOLLARS
        ($50) OR THE AMOUNTS YOU PAID TO COMPANY IN THE 12 MONTHS BEFORE THE
        EVENT THAT CAUSED THE CLAIM.
      </p>

      <h2>7. Term and Termination</h2>
      <p>
        These Terms will remain in effect while you use the Application. Except
        as Section 10 says for cmux Cloud, we may
        suspend or terminate your rights at any time for any reason at our sole
        discretion. Upon termination, you shall cease all use of the Application
        and delete all copies from your devices.
      </p>

      <h2>8. Dispute Resolution</h2>
      <p>
        You agree that any dispute between you and Company relating to the
        Application or these Terms will be resolved by binding arbitration,
        rather than in court, except that either party may assert individualized
        claims in small claims court or seek equitable relief for intellectual
        property misuse. The arbitration will be conducted by JAMS under their
        applicable rules.
      </p>
      <p>
        YOU AND COMPANY WAIVE ANY CONSTITUTIONAL AND STATUTORY RIGHTS TO SUE IN
        COURT AND HAVE A TRIAL IN FRONT OF A JUDGE OR A JURY.
      </p>
      <p>
        YOU AND COMPANY AGREE THAT EACH MAY BRING CLAIMS AGAINST THE OTHER ONLY
        ON AN INDIVIDUAL BASIS AND NOT ON A CLASS, REPRESENTATIVE, OR COLLECTIVE
        BASIS.
      </p>
      <p>
        You have the right to opt out of this arbitration agreement by sending
        written notice to{" "}
        <a href="mailto:founders@cmux.com">founders@cmux.com</a> within 30
        days of first becoming subject to it.
      </p>

      <h2>9. General</h2>
      <p>
        These Terms constitute the entire agreement between you and Company
        regarding the use of the Application. Our failure to exercise or enforce
        any right or provision shall not operate as a waiver. If any provision
        is held to be invalid, the remaining provisions will remain in full
        force and effect.
      </p>

      <h2 id="cmux-cloud">10. cmux Cloud</h2>
      <p>
        This Section 10 applies to cmux Cloud, our hosted services: the service
        at <a href="https://cmux.cloud">cmux.cloud</a>, including its web app,
        command-line tools, Slack app, meeting notetaker, and the AI agents
        that run in cloud machines; and the cloud machines (cloud VMs) that you
        create from the Application or the cmux.com dashboard (together,
        &ldquo;cmux Cloud&rdquo;). For cmux Cloud,
        references in these Terms to the Application include cmux Cloud. If
        this Section 10 and another section of these Terms conflict, this
        Section 10 controls for cmux Cloud. For cmux Cloud, a signed order form or
        other written agreement with Company controls only to the extent that
        it expressly addresses the subject and conflicts with these Terms. The
        Data Processing Addendum controls over these Terms and any order form
        on personal data processing, unless the signed agreement expressly
        gives stronger protection to Customer Personal Data.
      </p>

      <h3>Teams and accounts</h3>
      <p>
        If you use cmux Cloud for an organization, &ldquo;you&rdquo; in this
        Section 10 means that organization, and &ldquo;your team&rdquo; means
        its team in cmux Cloud. The person who accepts these Terms for the
        organization represents that they have authority to bind it. A person
        who only uses a team&rsquo;s cmux Cloud agrees to follow these Terms,
        but the duties to pay and to indemnify are the organization&rsquo;s. If
        you use cmux Cloud on your own, &ldquo;you&rdquo; and &ldquo;your
        team&rdquo; mean you. You are responsible for the people you invite,
        the tools you connect, and the settings and policies you choose, and
        for keeping your sign-in credentials secure. You are the controller of
        the personal data in Your Content, and you are responsible for the
        notices to, and the legal basis for the data of, your users, the
        members of your Slack workspace, and the people in your meetings,
        calendars, files, and connected tools.
      </p>

      <h3>Your content and connected tools</h3>
      <p>
        As between you and Company, you own the content you and your team put into or create
        with cmux Cloud, including messages, files, code, meeting transcripts,
        notes, memory, and agent output (&ldquo;Your Content&rdquo;). You grant
        Company a worldwide, non-exclusive, royalty-free license to host, copy,
        process, transmit, and display Your Content, and to let our service
        providers do so for us, only as necessary to provide,
        secure, and support cmux Cloud for you, as our{" "}
        <a href="https://cmux.com/privacy-policy#cmux-cloud">Privacy Policy</a>{" "}
        describes. For personal data in Your Content, our{" "}
        <a href="https://cmux.com/cmux-cloud/dpa">Data Processing Addendum</a>{" "}
        applies. We do not use Your Content to train generalized AI models.
        The AI models in cmux Cloud are operated by AI model providers under
        their own terms; the{" "}
        <a href="https://cmux.com/cmux-cloud/subprocessors">subprocessor page</a>{" "}
        lists them.
        You represent that you have the rights and permissions necessary to
        put Your Content into cmux Cloud and to connect each tool you connect.
        Company keeps Your Content confidential and discloses it only as these
        Terms, the Data Processing Addendum, and the Privacy Policy say. The
        &ldquo;Feedback&rdquo; paragraph of Section 1 does not apply to Your
        Content: where feedback that you or an agent send contains Your
        Content, we use that part only to examine and fix what the feedback
        reports.
        Company keeps usage and billing records as the Privacy Policy
        describes. Company can make and use statistics about the use of cmux Cloud (such
        as counts, sizes, durations, models, and costs) that contain none of
        Your Content and identify no person and no customer. Your use of a
        connected tool, such as Slack, Google, GitHub, or Linear,
        is also subject to that tool&rsquo;s own terms.
      </p>

      <h3>Confidential information</h3>
      <p>
        Each party can receive non-public business, technical, security, or
        product information from the other (&ldquo;Confidential
        Information&rdquo;), including Your Content. The receiving party uses
        it only to provide or receive cmux Cloud, protects it with reasonable
        care, and discloses it only to its staff, contractors, and service
        providers who need it and are bound by confidentiality duties. These
        duties do not apply to information that is public, already known
        without restriction, independently developed, or lawfully received from
        another source. A party that the law requires to disclose Confidential
        Information gives the other party notice before, where the law allows
        it, and reasonable help. A party does not breach this paragraph when it
        sends information where the other party directs it: for Your Content,
        to the AI models and tools that you choose, to the people and
        conversations that your settings allow, and to the public when you
        publish. These duties continue for as long as the receiving party holds
        the information.
      </p>

      <h3>Agents act on your behalf</h3>
      <p>
        cmux Cloud agents can read data from, and take actions in, the tools you
        connect, and can run code, use the web, and spend credits. When you
        connect a tool or give an agent a task, you authorize cmux Cloud agents
        to act in that tool on your behalf, within the permissions you and your
        team grant and the approvals and policies you set. Actions an agent
        takes on your behalf are your actions as between you and Company. You
        are responsible for reviewing agent work before you rely on it, and for
        the permissions you grant. Subject to Section 6, and except where the
        law does not allow this exclusion, Company is not liable for actions
        that an agent takes within the permissions and instructions that you
        or your team gave. If an agent acts outside those permissions because
        of a defect in cmux Cloud, Section 6 applies.
      </p>

      <h3>AI output</h3>
      <p>
        cmux Cloud uses AI models. AI output, including code, answers, meeting
        notes, summaries, action items, and transcripts, can be incomplete,
        inaccurate, or offensive, and can differ for similar requests. Do not
        rely on AI output as your only source of truth, or as professional,
        legal, medical, financial, or safety advice. You are responsible for
        evaluating AI output and for how you use it. Other users can receive
        output that is similar to yours.
      </p>

      <h3>Meeting recording and consent</h3>
      <p>
        The cmux notetaker records the audio of, and transcribes, the meetings
        that you send it to, or that match the calendar rules you turn on.
        While it is in a meeting, the notetaker also reads the live transcript
        and the meeting chat, to obey &ldquo;cmux pause&rdquo; and &ldquo;cmux
        leave&rdquo; from any participant and to answer questions typed to it.
        If a participant paused the notetaker or made it leave, you must not
        resume it or send it to that meeting again unless that participant
        agrees or the law does not require that participant&rsquo;s consent.
        Laws about recording
        conversations differ by place, and some require the consent of every
        participant. You are responsible for giving any notice and getting any
        consent that the law requires before the notetaker records a meeting,
        and for following the rules of your organization and of the meeting
        platform. You must not use the notetaker to record a meeting unlawfully,
        to record a meeting secretly, or to record a meeting where a participant
        objected and the law requires that participant&rsquo;s consent. You
        must not hide, remove, or change the notices that the notetaker posts,
        and you must tell participants who cannot see them, such as people who
        join by phone. On Google Meet, Zoom, and Microsoft Teams, you must check
        that the chat notice appeared. [LEGAL REVIEW: owner decision on
        calendar-rule joins when no team member that the notetaker is there for
        is in the meeting; in that case nobody can do this check.] On Webex the notetaker cannot post a
        notice, so you must tell every participant before the recording starts
        that cmux is an AI notetaker from Manaflow that records the audio and
        makes a transcript. If the notice or consent that the law requires is
        not in place, remove the notetaker. If a participant objects and the
        law requires that participant&rsquo;s consent, you must remove the
        notetaker promptly and delete the transcript and notes from the places
        in cmux Cloud that you control; for the copies that you cannot delete
        in cmux Cloud (model call records and archive copies), send a deletion
        request to founders@cmux.com, and Company deletes them as the Privacy
        Policy and the Data Processing Addendum say. The notetaker records for you: Company records, transcribes,
        and stores a meeting only as your service provider.
      </p>
      <p>
        You agree to indemnify and hold Company (and its officers, employees,
        and agents) harmless, including costs and attorneys&rsquo; fees, from
        any claim or demand made by any third party arising out of a meeting
        recording, transcript, or notes made by a notetaker that joined a
        meeting for you or your team (because you or your team sent it to a
        meeting link, or because the meeting matched a calendar rule that you
        or your team turned on), including a claim that a notice or consent that the law
        requires was not given. This does not apply to the extent that the
        claim was caused by Company&rsquo;s breach of these Terms or of the
        Data Processing Addendum, or by a defect in cmux Cloud that stopped
        a notice, a deletion, or a security function from working. A notice
        that the meeting&rsquo;s or the platform&rsquo;s settings stopped is
        not a defect. Company will promptly tell you of a covered claim, let you
        control the defense and settlement, and give reasonable help at your
        cost. You may not settle a claim in a way that admits fault for
        Company or puts a duty on Company without Company&rsquo;s consent.
      </p>

      <h3>Acceptable use</h3>
      <p>You must not use cmux Cloud, including its agents and cloud machines, to:</p>
      <ul>
        <li>Break the law or violate the rights of others, including privacy and intellectual property rights</li>
        <li>Record, monitor, or collect information about people without the notice and consent that the law requires</li>
        <li>Make, send, or store malware, spam, phishing, or content that sexually exploits children</li>
        <li>Attack, scan, or get unauthorized access to any system, network, or account</li>
        <li>Mine cryptocurrency, or use resources in a way that harms cmux Cloud or other users</li>
        <li>Get around usage limits, spend limits, billing, approvals, or security controls</li>
        <li>Make decisions with legal or similarly significant effects on people without human review</li>
        <li>Store or process protected health information or payment card data, unless Company agreed to it in writing</li>
        <li>Break the acceptable use policies of the AI models and connected tools that cmux Cloud uses</li>
      </ul>

      <h3>Published apps, public links, and copyright complaints</h3>
      <p>
        You can make an app, a page, a file, or a link from cmux Cloud open to
        people outside your team. You are responsible for what you publish and
        for who can open it. We can remove or turn off published content that
        breaks these Terms or the law. If you believe that content hosted on
        cmux Cloud infringes your copyright, send a notice with the information
        that 17 U.S.C. &sect; 512(c)(3) requires to our copyright agent:
        Manaflow, Inc., Attn: Copyright Agent, 18428 Vantage Pointe Dr, Rowland
        Heights, CA 91748-5142, United States, telephone [LEGAL REVIEW:
        number],{" "}
        <a href="mailto:founders@cmux.com">founders@cmux.com</a>. [LEGAL
        REVIEW: register this agent with the US Copyright Office before
        publication.] We tell the team that published the content, and that
        team can send a counter-notice. We end the accounts of teams and users
        who infringe repeatedly.
      </p>

      <h3>Fees, credits, and spend limits</h3>
      <p>
        The service at cmux.cloud charges for usage, such as AI model use,
        transcription, and cloud machine time, at the prices shown in cmux
        Cloud or on its pricing page when the usage occurs. Usage is paid from credits that
        your team buys through our payment processor. Prices do
        not include taxes, and you are responsible for applicable taxes.
        Credits are not refundable, except where the law requires a refund.
        We give at least [LEGAL REVIEW: proposed 30] days&rsquo; notice of a
        price increase; a change applies to usage after it takes effect.
      </p>
      <p>
        Cloud machine plans. If you buy a plan for the cloud machines that you
        create from the Application or the cmux.com dashboard, you pay the plan
        price shown at checkout in advance for each billing period (a month or
        a year). The plan renews for the same period at the same price until
        you cancel. If we change the price of your plan, we tell you by email no
        less than 7 days and no more than 30 days before the change takes
        effect, with how to cancel. For a yearly plan, we send a reminder 15 to
        45 days before the plan renews. You can cancel at any time in your
        billing settings or by a message to{" "}
        <a href="mailto:founders@cmux.com">founders@cmux.com</a>. The
        cancellation takes effect at the end of the period that you paid for.
        We do not refund a period that started, except where the law requires a
        refund. [LEGAL REVIEW: confirm the cancellation path and the refund
        rule, the yearly reminder, and the price-change notice against the
        checkout.]
      </p>
      <p>
        cmux Cloud has no spend limit unless a person on your team sets one.
        You and your team set dollar limits, and you are responsible for the
        limits you set or do not set. Limits are checked at set points while
        work runs, so usage can go over a limit before work stops (for example,
        a notetaker that is already in a meeting continues until the meeting
        ends). You pay for that usage. When your credits run out or a limit is reached, cmux
        Cloud can stop or refuse work.
      </p>

      <h3>Suspension</h3>
      <p>
        We can suspend or limit access to cmux Cloud, or stop an agent, a cloud
        machine, a notetaker, or a published app or link, if payment is overdue, if you break these
        Terms, if your use creates a security or legal risk or harms cmux Cloud
        or other users, or if the law requires it. When it is practical, we
        will tell you before we suspend access and give you a chance to fix the
        problem.
      </p>

      <h3>Data export and deletion</h3>
      <p>
        While your team&rsquo;s account is active, you can delete
        conversations, files, and memory in cmux Cloud and ask us at{" "}
        <a href="mailto:founders@cmux.com">founders@cmux.com</a> for a copy of
        Your Content. This does not delete the model call records and the
        archive copy of agent conversations; we delete those within 30 days
        after your written request to founders@cmux.com. [LEGAL REVIEW: owner
        decision on a fixed limit for these records.] Until we delete Your Content from our live systems, you can ask
        for a copy. We delete Your Content from our live systems 30 days after
        the account ends, or sooner if you ask; backups that still hold it
        expire within 35 days after that deletion, as our{" "}
        <a href="https://cmux.com/privacy-policy#cmux-cloud">Privacy Policy</a>{" "}
        describes. This does not apply to data that the law requires us to
        keep. [LEGAL REVIEW: the deletion on an admin&rsquo;s request is on prime-interface main (PR 296); the automatic deletion after the account ends is off until the owner turns it on; until then it is on request.]
      </p>

      <h3>Ending the account</h3>
      <p>
        You can end your team&rsquo;s account at any time by a message to{" "}
        <a href="mailto:founders@cmux.com">founders@cmux.com</a>. We can end
        your team&rsquo;s account if you materially break these Terms and do
        not fix the breach within 30 days after our notice, at once for illegal
        use or a security risk, or for any other reason with 30 days&rsquo;
        notice. [LEGAL REVIEW: add &ldquo;in cmux Cloud&rdquo; as a way to end
        the account when the control ships.] For cmux Cloud, the modification paragraph of Section 1 and
        Section 7 apply only as this subsection and &ldquo;Suspension&rdquo;
        say. When the account ends, your right to use cmux Cloud ends, you pay
        for usage up to that time, and &ldquo;Data export and deletion&rdquo;
        applies. Sections 3, 5, 6, 8, and 9, and in this Section 10 the
        indemnity, &ldquo;Confidential information&rdquo;, &ldquo;Agents act on
        your behalf&rdquo;, &ldquo;AI output&rdquo;, &ldquo;Your content and
        connected tools&rdquo; (until deletion), &ldquo;Data export and deletion&rdquo;, and &ldquo;Law,
        disputes, and changes for cmux Cloud&rdquo; continue. [LEGAL REVIEW: owner decision on unused credits when we
        end an account without cause.]
      </p>

      <h3>Law, disputes, and changes for cmux Cloud</h3>
      <p>
        For cmux Cloud, these Terms are governed by the laws of the State of
        California, without its conflict of laws rules. [LEGAL REVIEW: confirm
        the governing law, the arbitration seat, and the court for claims that
        are not arbitrated.] Nothing in Section 8
        stops a person from using their privacy rights, from making a complaint
        to a data protection authority or another government agency, or from
        asking a court for an injunction against misuse of personal data,
        confidential information, or intellectual property. We can change these
        Terms as they apply to cmux Cloud. A change does not lower the
        protection of the Data Processing Addendum for data that we already
        hold. For a material change, we tell your team&rsquo;s
        administrators by email or in cmux Cloud at least 30 days before the
        change takes effect. If you use cmux Cloud after that date, you accept
        the change. For cmux Cloud, Section 3 does not cover a claim about a
        meeting recording, transcript, or notes; only the indemnity in
        &ldquo;Meeting recording and consent&rdquo; covers it. The exclusions
        and the procedure of that indemnity (notice, control of the defense,
        settlement) also apply to Section 3. In Sections 1 to 9 as they apply
        to cmux Cloud, &ldquo;you&rdquo; has the meaning in &ldquo;Teams and
        accounts&rdquo;. Section 6 also applies to claims under the Data
        Processing Addendum, as far as the law allows. This Section 10, the rest of these Terms, the Data
        Processing Addendum, and a separate written agreement, if there is one,
        are the entire agreement about cmux Cloud.
      </p>

      <h2>11. Contact</h2>
      <p>
        Questions and formal notices about these Terms should be sent to
        Manaflow, Inc., 18428 Vantage Pointe Dr, Rowland Heights, CA
        91748-5142, United States, or to{" "}
        <a href="mailto:founders@cmux.com">founders@cmux.com</a>.
      </p>

      <p>
        Copyright &copy; {currentYear} Manaflow, Inc. All rights reserved.
      </p>
    </>
  );
}
