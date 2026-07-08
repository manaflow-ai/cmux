import type { Metadata } from "next";
import { Link } from "../../../../i18n/navigation";

export const metadata: Metadata = {
  title: "Privacy Policy | cmux",
  description: "Privacy policy for cmux",
  alternates: { canonical: "https://cmux.com/privacy-policy" },
};

export default function PrivacyPolicyPage() {
  return (
    <>
      <h1>Privacy Policy</h1>
      <p>Last updated: July 8, 2026</p>

      <p>
        Manaflow (the &ldquo;Company&rdquo;) is committed to maintaining robust
        privacy protections for its users. This Privacy Policy is designed to
        help you understand how we collect, use and safeguard the information you
        provide to us.
      </p>
      <p>
        For purposes of this policy, &ldquo;Site&rdquo; refers to the
        Company&rsquo;s website at <a href="https://cmux.com">cmux.com</a>.
        &ldquo;Application&rdquo; refers to the cmux applications for macOS and
        iOS. &ldquo;Service&rdquo; refers to the Site and Application
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
        The macOS Application may collect the following information
        automatically:
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
        The iOS Application may collect the following information:
      </p>
      <ul>
        <li>
          Account information from sign-in, such as your email address, display
          name when present, Stack user id, and selected team.
        </li>
        <li>
          App-generated identifiers, such as an install client id and device id,
          used for pairing, device registry, multi-device sync, and product
          analytics grouping.
        </li>
        <li>
          Product analytics events, such as app launch, foreground and
          background, sign-in result, pairing result, workspace open, push opt-in
          status, feature usage, counts, and terminal input byte counts.
        </li>
        <li>
          Feedback you submit, including your reply-to email, message, app
          version, build number, bundle identifier, build channel, operating
          system version, hardware model, and locale.
        </li>
      </ul>
      <p>
        iOS product analytics are sent through the cmux web analytics proxy to
        PostHog. They do not include terminal text, prompts, pasted content,
        images, files, hostnames, IP addresses, auth tokens, or pairing tickets.
        You can turn off iOS product analytics in the iOS app under Settings,
        Privacy, Share Product Analytics.
      </p>
      <p>
        iOS terminal content, pasted content, images, and files are sent to your
        paired Mac for the terminal workflow. Manaflow does not collect or retain
        that content unless you explicitly include it in a feedback submission.
      </p>
      <p>
        The Site uses PostHog for analytics, including page views and navigation
        patterns. PostHog stores a cookie to distinguish unique visitors. This
        analytics is anonymous and collects no personally identifiable
        information, with one exception: if you join a platform waitlist, the
        email address you submit is recorded in PostHog so we can notify you when
        that platform is available. If you submit the Enterprise contact form,
        we record the company and contact details you provide in PostHog and
        send them to our internal Slack workspace and founders email inbox so we
        can respond. You can opt out of Site analytics by using a browser
        extension that blocks tracking scripts.
      </p>

      <h3>2. Information you provide directly</h3>
      <p>
        If you contact us via email, our contact page, or the Enterprise contact
        form, feedback form, or in-app feedback flow, we collect the information
        you provide such as your name, email address, company, role, phone
        number, country, deployment needs, comments, and feedback message. If you
        join a platform waitlist, we collect the email address you submit so we
        can email you when that platform launches, and we send a notification of
        the signup (including that email address) to our internal Slack
        workspace.
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
          <strong>Sentry</strong>: macOS error tracking and crash reporting. May
          collect error logs, stack traces, device information, and OS version.
        </li>
        <li>
          <strong>Sparkle</strong>: macOS auto-update framework. Transmits
          application and OS version to check for updates.
        </li>
        <li>
          <strong>Ghostty / libghostty</strong>: terminal rendering engine. Runs
          locally on your device.
        </li>
        <li>
          <strong>Stack Auth</strong>: authentication provider for the iOS app
          and cmux account sign-in. Provides account identifiers, email address,
          display name when present, and team membership needed for sign-in and
          pairing.
        </li>
        <li>
          <strong>PostHog</strong>: website analytics and iOS product analytics.
          Website analytics collect page view data, navigation patterns, and
          browser metadata via a first-party proxy. iOS product analytics collect
          product events and identifiers described above, unless you opt out in
          iOS Settings. If you join a platform waitlist, the email address you
          submit is also recorded in PostHog so we can notify you.
        </li>
        <li>
          <strong>Resend</strong>: transactional email delivery. Used to deliver
          feedback submissions from the Application. Your email address is
          transmitted to Resend only if you voluntarily submit feedback.
        </li>
        <li>
          <strong>Apple speech recognition and dictation frameworks</strong>: on
          iOS, used only when you choose to dictate text into the message box.
        </li>
        <li>
          <strong>Slack</strong>: internal team notifications. If you join a
          platform waitlist, the email address and platforms you submit are sent
          to our private Slack workspace so the team is notified of the signup.
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
        diagnostics solely to improve the Application. We use iOS product
        analytics to improve reliability, onboarding, pairing, notifications,
        and terminal workflows. We may share information if we have a good-faith
        belief that disclosure is necessary to meet legal process or protect
        against harm.
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
        You may opt out of iOS product analytics at any time in the iOS app under
        Settings, Privacy, Share Product Analytics. Turning this off stops future
        analytics events and identity calls from being sent.
      </p>
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
        Crash reports, diagnostics, iOS product analytics, and feedback records
        are retained only as long as needed to diagnose issues, improve the
        Service, respond to feedback, and meet legal obligations. You may request
        deletion of any data associated with you by contacting us at{" "}
        <a href="mailto:founders@manaflow.com">founders@manaflow.com</a>.
      </p>
    </>
  );
}
