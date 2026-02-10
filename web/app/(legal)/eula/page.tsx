import type { Metadata } from "next";

export const metadata: Metadata = {
  title: "EULA — cmux",
  description: "End-User License Agreement for cmux",
};

export default function EulaPage() {
  return (
    <>
      <h1>End-User License Agreement</h1>
      <p>Last updated: December 2, 2025</p>

      <p>
        Please read this End-User License Agreement carefully before
        downloading or using cmux.
      </p>

      <h2>Interpretation and Definitions</h2>
      <p>For the purposes of this Agreement:</p>
      <ul>
        <li>
          <strong>&ldquo;Agreement&rdquo;</strong> means this End-User License
          Agreement that forms the entire agreement between You and the Company
          regarding the use of the Application.
        </li>
        <li>
          <strong>&ldquo;Application&rdquo;</strong> means the cmux desktop
          application for macOS, a native terminal application built on Ghostty.
        </li>
        <li>
          <strong>&ldquo;Company&rdquo;</strong> (referred to as &ldquo;the
          Company&rdquo;, &ldquo;We&rdquo;, &ldquo;Us&rdquo; or
          &ldquo;Our&rdquo;) refers to Manaflow.
        </li>
        <li>
          <strong>&ldquo;Content&rdquo;</strong> refers to content such as text,
          code, images, or other information that can be created, processed, or
          displayed by the Application.
        </li>
        <li>
          <strong>&ldquo;Country&rdquo;</strong> refers to the United States.
        </li>
        <li>
          <strong>&ldquo;Device&rdquo;</strong> means any macOS computer that
          can run the Application.
        </li>
        <li>
          <strong>&ldquo;You&rdquo;</strong> means the individual accessing or
          using the Application.
        </li>
      </ul>

      <h2>Acknowledgment</h2>
      <p>
        By downloading or using the Application, You are agreeing to be bound
        by the terms of this Agreement. If You do not agree, do not download or
        use the Application.
      </p>
      <p>
        The Application is licensed, not sold, to You by the Company for use
        strictly in accordance with the terms of this Agreement.
      </p>

      <h2>License</h2>

      <h3>Scope of License</h3>
      <p>
        The Company grants You a revocable, non-exclusive, non-transferable,
        limited license to download, install and use the Application strictly in
        accordance with this Agreement, for your personal or internal business
        purposes including commercial use in connection with software
        development.
      </p>

      <h3>License Restrictions</h3>
      <p>You agree not to, and You will not permit others to:</p>
      <ul>
        <li>
          License, sell, rent, lease, assign, distribute, transmit, host, or
          otherwise commercially exploit the Application or make it available to
          any third party
        </li>
        <li>
          Remove, alter or obscure any proprietary notice (including copyright
          or trademark) of the Company
        </li>
        <li>
          Modify, make derivative works of, disassemble, decrypt, reverse
          compile or reverse engineer any part of the Application
        </li>
      </ul>

      <h2>Intellectual Property</h2>
      <p>
        The Application, including all copyrights, patents, trademarks, trade
        secrets and other intellectual property rights, is and shall remain the
        sole and exclusive property of the Company.
      </p>
      <p>
        You retain ownership of any code or content you create using the
        Application.
      </p>

      <h2>Modifications and Updates</h2>
      <p>
        The Company reserves the right to modify, suspend or discontinue the
        Application at any time, with or without notice and without liability to
        You.
      </p>
      <p>
        The Company may provide updates, patches, bug fixes, and other
        modifications. Updates may modify or remove certain features. You agree
        that all updates are subject to the terms of this Agreement.
      </p>

      <h2>Third-Party Services</h2>
      <p>
        The Application integrates with third-party services including Ghostty
        (terminal rendering engine), Sentry (error tracking), and Sparkle
        (auto-update framework). You acknowledge that the Company shall not be
        responsible for any third-party services, including their accuracy,
        completeness, or quality.
      </p>

      <h2>Term and Termination</h2>
      <p>
        This Agreement shall remain in effect until terminated by You or the
        Company. The Company may terminate this Agreement at any time for any
        reason.
      </p>
      <p>
        This Agreement will terminate immediately if you fail to comply with any
        provision. You may also terminate by deleting the Application and all
        copies from your Device.
      </p>
      <p>
        Upon termination, You shall cease all use of the Application and delete
        all copies from your Device.
      </p>

      <h2>No Warranties</h2>
      <p>
        The Application is provided &ldquo;AS IS&rdquo; and &ldquo;AS
        AVAILABLE&rdquo; without warranty of any kind. The Company expressly
        disclaims all warranties, whether express, implied, statutory or
        otherwise, including all implied warranties of merchantability, fitness
        for a particular purpose, title and non-infringement.
      </p>
      <p>
        Some jurisdictions do not allow the exclusion of certain types of
        warranties, so some of the above exclusions may not apply to You.
      </p>

      <h2>Limitation of Liability</h2>
      <p>
        The entire liability of the Company under this Agreement shall be
        limited to the amount actually paid by You for the Application, or 100
        USD if You haven&rsquo;t purchased anything.
      </p>
      <p>
        To the maximum extent permitted by law, in no event shall the Company
        be liable for any special, incidental, indirect, or consequential
        damages whatsoever.
      </p>

      <h2>Indemnification</h2>
      <p>
        You agree to indemnify and hold the Company harmless from any claim or
        demand, including reasonable attorneys&rsquo; fees, due to or arising
        out of your use of the Application or violation of this Agreement.
      </p>

      <h2>Severability and Waiver</h2>
      <p>
        If any provision of this Agreement is held to be unenforceable, it will
        be changed and interpreted to accomplish its objectives to the greatest
        extent possible, and the remaining provisions will continue in full
        force and effect.
      </p>

      <h2>Governing Law</h2>
      <p>
        The laws of the United States, excluding conflicts of law rules, shall
        govern this Agreement and your use of the Application.
      </p>

      <h2>Changes to This Agreement</h2>
      <p>
        The Company reserves the right to modify this Agreement at any time. If
        a revision is material, we will provide at least 30 days&rsquo; notice.
        By continuing to use the Application after revisions become effective,
        You agree to be bound by the revised terms.
      </p>

      <h2>Contact Us</h2>
      <p>If you have any questions about this Agreement:</p>
      <ul>
        <li>
          Email us at{" "}
          <a href="mailto:founders@manaflow.com">founders@manaflow.com</a>
        </li>
      </ul>
    </>
  );
}
