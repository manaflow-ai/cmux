# Privacy policy draft: opt-in hang reports (NOT PUBLISHED)

Status: draft for Lawrence's legal review, 2026-10-23. Nothing here is live. The published
policy is `web/app/[locale]/(legal)/privacy-policy/content/<locale>.json` (20 locales, "Last
updated: September 1, 2026"); this draft names each English change and where it goes. After
approval: edit `en.json`, translate the same paragraphs into the other 19 files, and bump
`lastUpdated` in all 20.

What it describes: plans/cmux-next/hang-reports-DESIGN.md (sections 1, 3, 5).

## Change 1: Section I.1, "Information collected through technology"

Add one bullet after "Operating-system version and application version.":

> Hang reports from the macOS Application's Nightly builds, only if you turn them on.

Add one paragraph to `afterBullets`, after the Sparkle paragraph:

> Nightly builds of the macOS Application can send hang reports, which help us find and fix
> moments when the Application stops responding or draws slowly. Hang reports are off until you
> turn them on, and each Mac sends them only after you confirm on that Mac (a settings file
> copied from another Mac does not turn them on by itself). If you turned off anonymous usage
> data, the Application does not ask you about hang reports. Release builds never send them,
> and data collected before you confirmed is not sent. A report is sent at most a few times a day and
> contains: call stacks of the Application's and macOS's own code (the code library name, its
> build identifier, and a numeric position in it; code from any other developer appears only as
> "other"), how long hangs and slow frames lasted, statistics macOS collects about the
> Application's responsiveness, launch time and animation smoothness, the Application and macOS
> version numbers, your Mac's processor family, number of cores and rounded memory size, rounded
> counts of open windows, workspaces, panes and tabs, the date, and a random identifier created on
> your Mac that changes every 30 days and is not linked to your account. Hang reports never
> include file names or paths, web addresses, page titles, terminal text, window or workspace
> names, your user name, your Mac's name, network addresses, environment variables, email
> addresses, credentials, clipboard contents, chat content, or anything you type. The
> Application checks every report for such data before it is sent and does not send a report
> that appears to contain any. Settings > View Hang Report shows the exact report last sent. Our
> application does not store the IP address a report comes from; our hosting provider processes
> it to deliver the request and to limit how often reports can be sent. You can turn hang reports off
> at any time in Settings, which also deletes reports waiting to be sent and the random
> identifier.

## Change 2: Section III, "How We Use and Share Information"

Append to the paragraph:

> We use hang reports only to find and fix performance problems in the Application. We do not
> combine them with account, analytics or crash-report data, and we do not share them with third
> parties.

## Change 3: Section IX, "Data Retention"

Insert after the first sentence ("Crash reports and diagnostics are kept only as long as
needed ..."):

> Hang reports are deleted 90 days after we receive them.

## Change 4: Section II, "Third-Party Services"

No change: hang reports go to cmux's own server (`cmux.com`, hosted on Vercel, stored in our
PlanetScale database), not to Sentry or PostHog. If counsel considers hosting providers
third-party services for this policy, add: "Vercel and PlanetScale: hosting and database
services that store hang reports for cmux."

## Questions for counsel (Lawrence)

- Is the opt-in notice in the app (a sidebar card with Send Hang Reports and Not Now, plus the
  Settings switch text) enough consent, given the data is designed to be non-personal?
- Do we need the "Vercel and PlanetScale" line in Section II?
- Should the policy name the 90-day retention or keep the general "as long as needed" wording?
