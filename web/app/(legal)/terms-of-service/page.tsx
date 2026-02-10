import type { Metadata } from "next";

export const metadata: Metadata = {
  title: "Terms of Service — cmux",
  description: "Terms of service for cmux",
};

export default function TermsOfServicePage() {
  return (
    <>
      <h1>Terms of Service</h1>
      <p>Last revised on: December 2, 2025</p>

      <p>
        The website located at{" "}
        <a href="https://cmux.dev">cmux.dev</a> (the
        &ldquo;Site&rdquo;) and the cmux desktop application (the
        &ldquo;Application&rdquo;) are copyrighted works belonging to Manaflow
        (&ldquo;Company&rdquo;, &ldquo;us&rdquo;, &ldquo;our&rdquo;, and
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
        and its content are owned by Company or Company&rsquo;s suppliers.
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
        use.
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
        DAMAGES WILL AT ALL TIMES BE LIMITED TO FIFTY US DOLLARS ($50).
      </p>

      <h2>7. Term and Termination</h2>
      <p>
        These Terms will remain in effect while you use the Application. We may
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
        <a href="mailto:founders@manaflow.com">founders@manaflow.com</a> within 30
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

      <h2>10. Contact</h2>
      <p>
        Questions about these Terms should be sent to{" "}
        <a href="mailto:founders@manaflow.com">founders@manaflow.com</a>.
      </p>

      <p>
        Copyright &copy; 2025 Manaflow. All rights reserved.
      </p>
    </>
  );
}
