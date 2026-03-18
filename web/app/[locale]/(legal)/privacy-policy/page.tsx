import type { Metadata } from "next";
import { Link } from "../../../../i18n/navigation";

export const metadata: Metadata = {
  title: "Privacy Policy — cmux",
  description: "Privacy policy for cmux",
  alternates: { canonical: "./" },
};

export default function PrivacyPolicyPage() {
  return (
    <>
      <h1>Privacy Policy</h1>
      <p>Last updated: March 18, 2026</p>

      <p>
        Manaflow (the &ldquo;Company&rdquo;) is committed to maintaining robust
        privacy protections for its users. This Privacy Policy is designed to
        help you understand how we collect, use and safeguard the information you
        provide to us.
      </p>
      <p>
        For purposes of this policy, &ldquo;Site&rdquo; refers to the
        Company&rsquo;s website at{" "}
        <a href="https://cmux.com">cmux.com</a>.
        &ldquo;Application&rdquo; refers to the cmux desktop application for
        macOS. &ldquo;Service&rdquo; refers to the Site and Application
        collectively. The terms &ldquo;we,&rdquo; &ldquo;us,&rdquo; and
        &ldquo;our&rdquo; refer to the Company. &ldquo;You&rdquo; refers to
        you, as a user of our Service.
      </p>
      <p>
        By using our Service, you accept this Privacy Policy and our{" "}
        <Link href="/terms-of-service">Terms of Service</Link>, and you consent to
        our collection, storage, use and disclosure of your information as
        described here.
      </p>

      <h2>I. Information We Collect</h2>
      <p>
        We collect &ldquo;Non-Personal Information&rdquo; and &ldquo;Personal
        Information.&rdquo; Non-Personal Information includes information that
        cannot be used to personally identify you, such as anonymous usage data,
        platform types, and crash diagnostics. Personal Information includes
        your email address if you choose to contact us.
      </p>

      <h3>1. Information collected via Technology</h3>
      <p>
        The Application may collect the following information automatically:
      </p>
      <ul>
        <li>Crash reports and error diagnostics (via Sentry)</li>
        <li>Operating system version and application version</li>
        <li>Anonymous usage patterns</li>
      </ul>
      <p>
        The Application checks for updates via Sparkle, which may transmit your
        operating system version and application version to our update server.
      </p>
      <p>
        The Site uses PostHog for anonymous analytics, including page views and
        navigation patterns. PostHog stores a cookie to distinguish unique
        visitors. No personally identifiable information is collected through
        analytics. You can opt out by using a browser extension that blocks
        tracking scripts.
      </p>

      <h3>2. Information you provide directly</h3>
      <p>
        If you contact us via email or our contact page, we collect the
        information you provide such as your name and email address.
      </p>

      <h3>3. Children&rsquo;s Privacy</h3>
      <p>
        The Service is not directed to anyone under the age of 13. We do not
        knowingly collect information from anyone under 13. If you believe we
        have collected such information, please contact us at{" "}
        <a href="mailto:founders@manaflow.com">founders@manaflow.com</a>.
      </p>

      <h2>II. Third-Party Services</h2>
      <p>
        The Application integrates with the following third-party services:
      </p>
      <ul>
        <li>
          <strong>Sentry</strong> &mdash; error tracking and crash reporting.
          May collect error logs, stack traces, device information, and OS
          version.
        </li>
        <li>
          <strong>Sparkle</strong> &mdash; auto-update framework. Transmits
          application and OS version to check for updates.
        </li>
        <li>
          <strong>Ghostty / libghostty</strong> &mdash; terminal rendering
          engine. Runs entirely locally on your device.
        </li>
        <li>
          <strong>PostHog</strong> &mdash; website analytics. Collects anonymous
          page view data, navigation patterns, and browser metadata via a
          first-party proxy. No personally identifiable information is collected.
        </li>
        <li>
          <strong>Resend</strong> &mdash; transactional email delivery. Used to
          deliver feedback submissions from the Application. Your email address
          is transmitted to Resend only if you voluntarily submit feedback.
        </li>
      </ul>
      <p>
        Each of these services has its own privacy policy governing the
        collection and use of your data.
      </p>

      <h2>III. How We Use and Share Information</h2>
      <p>
        We do not sell, trade, rent or otherwise share your Personal Information
        with third parties for marketing purposes. We use crash reports and
        diagnostics solely to improve the Application. We may share information
        if we have a good-faith belief that disclosure is necessary to meet
        legal process or protect against harm.
      </p>

      <h2>IV. How We Protect Information</h2>
      <p>
        We implement security measures designed to protect your information from
        unauthorized access, including encryption and secure server software.
        However, no method of transmission or storage is 100% secure. By using
        our Service, you acknowledge and agree to assume these risks.
      </p>

      <h2>V. Your Rights</h2>
      <p>
        Depending on your location, you may have rights under applicable data
        protection laws (such as GDPR or CCPA), including:
      </p>
      <ul>
        <li>Right to access a copy of data we hold about you</li>
        <li>Right to request correction of inaccurate data</li>
        <li>Right to request deletion of your data</li>
        <li>Right to data portability</li>
        <li>Right to restrict or object to processing</li>
      </ul>
      <p>
        To exercise any of these rights, please contact us at{" "}
        <a href="mailto:founders@manaflow.com">founders@manaflow.com</a>.
      </p>

      <h2>VI. Links to Other Websites</h2>
      <p>
        The Service may provide links to third-party websites. We are not
        responsible for the privacy practices of those websites. This Privacy
        Policy applies solely to information collected by us.
      </p>

      <h2>VII. Changes to This Policy</h2>
      <p>
        We reserve the right to change this policy at any time. Significant
        changes will go into effect 30 days following notification. You should
        periodically check the Site for updates.
      </p>

      <h2>VIII. Contact Us</h2>
      <p>
        If you have any questions regarding this Privacy Policy, please contact
        us at{" "}
        <a href="mailto:founders@manaflow.com">founders@manaflow.com</a>.
      </p>

      <h2>IX. Data Retention</h2>
      <p>
        Crash reports and diagnostics are retained only as long as needed to
        diagnose and fix issues. You may request deletion of any data associated
        with you by contacting us at{" "}
        <a href="mailto:founders@manaflow.com">founders@manaflow.com</a>.
      </p>
    </>
  );
}
