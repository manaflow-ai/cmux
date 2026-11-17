import type { PrivacyPolicySection } from "./content";

// DRAFT, legal review needed. The cmux Cloud section of the privacy policy. It is English on every locale until
// legal review is done; translate it into every locale of web/i18n/routing.ts before this text is final.
// The retention numbers must match the product: recordings 7 days (RECORDING_DAYS in the cmux Cloud meetings
// service), calendar cache 4 days after the event starts (2 x the 48-hour read window), memory history 30 days.

const limitedUseStatement =
  "cmux's use and transfer to any other app of information received from Google APIs will adhere to the [Google API Services User Data Policy](https://developers.google.com/terms/api-services-user-data-policy), including the Limited Use requirements.";

export const cmuxCloudPrivacySection: PrivacyPolicySection = {
  heading: "X. cmux Cloud",
  paragraphs: [
    "This section applies to cmux Cloud, the hosted cmux service at [cmux.cloud](https://cmux.cloud). cmux Cloud includes its web app, command-line tools, Slack app, meeting notetaker, and the AI agents that run in cloud machines for you. In this Privacy Policy, the Service includes cmux Cloud. If this section and another section of this policy differ, this section applies to cmux Cloud.",
    "Teams use cmux Cloud. Your team's administrators decide which tools to connect, which conversations cmux can read, and which people can use it. If your organization gave you access to cmux Cloud, your organization's own policies may also apply to your data.",
  ],
  subsections: [
    {
      heading: "1. Information we collect in cmux Cloud",
      bullets: [
        "Account and sign-in data: your name, email address, profile image, sign-in provider identifiers, team membership, and role.",
        "Slack data: when your team installs the cmux Slack app, we receive the messages, threads, reactions, and files in direct messages with the app and in conversations where the app is a member, and the profile details that Slack gives the app about workspace members, such as names, display names, email addresses, and time zones.",
        "Files and voice messages: files that you share with cmux in Slack or upload to cmux Cloud, including audio and video files. We turn speech in audio and video files into text transcripts.",
        "Meeting data: when a notetaker joins a meeting for you, we process the meeting link, title, platform, and time, the names that participants show in the meeting, the audio and video recording, the transcript of what was said and who said it, and the notes and action items written from the transcript.",
        "Google Calendar data: if you connect Google Calendar, we read events in your primary calendar as described in \"Google user data\" below.",
        "Data from connected tools: when you or your team connect a tool such as GitHub or Linear, we store the access credentials and process the data that agents read from or write to that tool, such as repositories, code, issues, pull requests, and comments.",
        "Agent work: your prompts and conversations, instructions, the actions agents take and their results, code, files, command output, and web pages in cloud machines, and the screenshots and artifacts agents make.",
        "Memory: facts and notes that agents save about your team, projects, and preferences so that later work can use them.",
        "Usage, cost, and billing data: the AI models used, token counts, machine time, costs, credits, spend limits, invoices, and payment status. Our payment processor handles card details; we do not store full card numbers.",
        "Technical and security data: IP addresses, browser and device information, logs, and an audit log of actions, approvals, and policy decisions.",
      ],
    },
    {
      heading: "2. How we use cmux Cloud data",
      paragraphs: ["We use cmux Cloud data to:"],
      bullets: [
        "Provide the features that you and your team use: answer messages, run agents, join the meetings you choose, write and deliver meeting notes, and act in the tools you connect.",
        "Measure usage, charge credits, send invoices, and enforce the spend limits that people on your team set.",
        "Keep cmux Cloud secure, prevent abuse and fraud, find and fix errors, and keep an audit log.",
        "Give support when you ask for it.",
        "Comply with the law.",
      ],
      afterBullets: [
        "We do not sell cmux Cloud data. We do not use it for advertising. We do not use your content, Slack data, meeting data, or Google user data to train generalized AI models, and our agreements with the AI model providers that we choose do not let them train their models on it. When your team uses its own AI model provider keys or endpoints, that provider's terms apply.",
        "Our staff do not read your content, except when you ask us for help and give permission, when it is necessary for security (for example, to investigate abuse), when the law requires it, or when the data is aggregated and de-identified for internal operations.",
      ],
    },
    {
      heading: "3. AI model providers and other service providers",
      paragraphs: [
        "We use service providers to operate cmux Cloud. They process data only for us, to provide their service, under contracts that limit how they use it. The categories are:",
      ],
      bullets: [
        "AI model providers, which process prompts, content, and tool results to produce model answers, and which turn speech into text.",
        "A meeting recording service, which joins meetings as the notetaker, records them, and makes the transcript.",
        "Cloud hosting, database, and storage providers.",
        "Cloud machine providers, which run the machines where agents work.",
        "A sign-in service.",
        "A payment processor.",
        "Email delivery, error monitoring, and product analytics providers.",
      ],
      afterBullets: [
        "The tools that you connect, such as Slack, Google, GitHub, and Linear, receive the data that agents send to them when they act for you. Their own privacy policies apply to that data.",
        "For a list of our service providers, contact [founders@cmux.com](mailto:founders@cmux.com).",
      ],
    },
    {
      heading: "4. Meeting notetaker and notice to participants",
      paragraphs: [
        "The notetaker joins a meeting only when a person on your team sends it to a meeting link, or when the meeting matches a rule that the person turned on for their connected calendar. After you connect a calendar, no meeting is joined until you turn on a rule.",
        "On Google Meet, Zoom, and Microsoft Teams, the notetaker posts and pins a notice in the meeting chat when it joins. The notice says who the notes are for, where the notes go, and how long the recording is kept. Nobody can turn this notice off. On platforms where the notetaker cannot post in the chat, its name says that it is a notetaker. Any participant can ask the host to remove the notetaker, and the host can remove it from the meeting.",
        "Notes and the transcript go to the team members the notetaker was sent for. For a notetaker sent from a cmux conversation, they also go to that conversation, which can be a Slack channel that other team members can read. A team member who was in the meeting can later post the notes in a channel of the team's Slack workspace. Invitees from outside the team do not get notes from cmux. The team member who sends the notetaker must get the consent that the law requires from the other participants before the notetaker records (see our [Terms of Service](https://cmux.com/terms-of-service)).",
        "If you were in a meeting with a cmux notetaker and you are not a cmux Cloud user, you can ask for deletion of your data at [founders@cmux.com](mailto:founders@cmux.com). We may send your request to the team that used the notetaker.",
      ],
    },
    {
      heading: "5. Google user data",
      paragraphs: [
        "If you connect Google Calendar, cmux Cloud asks Google, where the app is shown with the name \"cmux\", for read-only access to your calendar events (the calendar.events.readonly scope) and for your email address, which we use to confirm that the Google account is yours. We cannot change or delete your calendar events.",
        "What we read: we read your primary calendar's name and time zone, and, for events from 1 hour ago to 48 hours ahead, the event identifier, status, type, title, start and end times, recurrence, video meeting links, location, description, the organizer's email address, and the attendees' email addresses, responses, and whether an attendee is a room. We read the location and description only to find the video meeting link. We read the organizer's and attendees' email addresses only to decide whether a meeting is internal (everyone has your email domain) or external.",
        "What we store: your Google account email address and calendar time zone, and, for each event with a Google Meet, Zoom, Microsoft Teams, or Webex link, the event identifier, title, start and end times, the meeting link, the platform, whether you organize the event, your response, whether the meeting is internal, the recurrence identifier, and your join or skip choices for that meeting or its series. We do not store the description, the location, or the organizer's or attendees' email addresses. We store your Google access credential encrypted in our secrets vault. It is never shown to you, written to logs, or given to an AI model.",
        "How we use it: only to provide features that you can see and control. We use it to decide which meetings the notetaker joins for you under your rules, to schedule the notetaker, to show you your upcoming meetings and what the notetaker will do, and to put the meeting title on your notes.",
        "Who receives it: we give the meeting link and start time to our meeting recording service so that the notetaker can join. Our AI model providers process event titles and times when cmux lists your meetings or writes your notes. We send the event title to Slack when we post your notes there, and it goes to the team members who receive or are shown those notes. We do not transfer Google user data to anyone else, except when necessary to comply with the law, or as part of a merger, acquisition, or sale of assets with your prior consent.",
        limitedUseStatement,
      ],
      bullets: [
        "We use Google user data only to provide or improve user-facing features that are visible in cmux Cloud.",
        "We do not use Google user data for advertising, including retargeting and personalized or interest-based advertising.",
        "We do not transfer or sell Google user data to third parties such as advertising platforms, data brokers, or information resellers.",
        "We do not use or transfer Google user data to determine credit-worthiness or for lending purposes.",
        "We do not use Google user data to develop, improve, or train generalized AI or machine-learning models.",
        "Our staff do not read Google user data unless you give permission for specific data, it is necessary for security (for example, to investigate abuse), it is necessary to comply with the law, or the data is aggregated and anonymized for internal operations.",
      ],
      afterBullets: [
        "Retention: while your calendar is connected, we delete events that are no longer in your calendar at the next read of your calendar (normally within about 10 minutes), and we delete stored events no later than 4 days after they start. When a notetaker joined an event, the title, time, and link stay with that meeting's record and notes until they are deleted. Event titles that cmux showed in a conversation stay with that conversation.",
        "Disconnect: ask cmux to disconnect your calendar. We then revoke our access at Google, delete your Google credential, and delete your stored calendar data. You can also remove cmux's access on your [Google Account permissions page](https://myaccount.google.com/permissions); cmux then stops reading your calendar, and the data it stored stays until you ask cmux to disconnect your calendar or ask us to delete it. The audit log keeps a record that you connected and disconnected the calendar, with the Google account email address.",
      ],
    },
    {
      heading: "6. Retention and deletion",
      bullets: [
        "Meeting recordings: the meeting recording service keeps the audio and video recording and its transcript for 7 days after the meeting and then deletes them. We do not keep a copy of meeting audio or video.",
        "Meeting transcripts and notes: kept in the cmux conversation that received them until you or your team delete them, or until your team's account is deleted.",
        "Files, including audio and video files from Slack: kept as files of the conversation until you or your team delete them, the Slack message that carried them is deleted, or your team's account is deleted. Their transcripts are kept with the conversation.",
        "Google Calendar data: as described in \"Google user data\" above.",
        "Memory: kept until you, your team, or an agent removes it. Earlier versions of a memory file are deleted about 30 days after they are replaced. When you tell cmux to forget something, cmux keeps a record of what it was told to forget so that it does not save it again.",
        "Slack data, agent conversations, and agent work: kept while your team's account is active, until you or your team delete them.",
        "Usage, cost, and billing records: kept as long as tax, accounting, and legal duties require.",
        "Security logs and audit logs: kept as long as necessary for security and to comply with the law.",
      ],
      afterBullets: [
        "When a team asks us to delete its account, we delete its cmux Cloud data within 30 days, except records that we must keep to comply with the law or to resolve disputes. Copies in backups are deleted when the backups expire. To ask for deletion or for a copy of your data, contact [founders@cmux.com](mailto:founders@cmux.com).",
      ],
    },
    {
      heading: "7. Your controls",
      bullets: [
        "Disconnect Google Calendar, or remove cmux's access in your Google Account.",
        "Turn your calendar rules off, or tell cmux to skip one meeting or a series of meetings.",
        "Tell cmux to remove the notetaker from a meeting, or remove it as the meeting host.",
        "Remove the cmux app from your Slack workspace, or remove it from a channel.",
        "Disconnect GitHub, Linear, and other connected tools.",
        "Tell cmux to forget a memory, and delete conversations and files.",
        "Your team's admins can set spend limits for the team, a person, a channel, an agent, an environment, or a project, and you can set a lower limit for your own work.",
        "Ask for access to, a copy of, correction of, or deletion of your data at [founders@cmux.com](mailto:founders@cmux.com).",
      ],
    },
    {
      heading: "8. Security",
      paragraphs: [
        "We encrypt cmux Cloud data in transit. We keep access credentials for connected tools, including Google and Slack credentials, encrypted in a secrets vault. Only the services that need a credential can use it, and we do not give credentials to AI models. Agents work in isolated cloud machines. Text from outside your team, such as meeting transcripts and web pages, is treated as untrusted and cannot start work by itself. We keep an audit log of actions and policy decisions. No method of storage or transmission is completely secure.",
      ],
    },
    {
      heading: "9. Children",
      paragraphs: [
        "cmux Cloud is not for anyone under 18, and we do not knowingly collect personal information from children under 13. Teams must not send the notetaker to meetings with children unless the law allows it and the required consent was given. If you believe that we collected information from a child, contact [founders@cmux.com](mailto:founders@cmux.com).",
      ],
    },
    {
      heading: "10. International transfers",
      paragraphs: [
        "We are in the United States. We and our service providers process and store cmux Cloud data in the United States and in other countries. When we transfer personal information from the European Economic Area, the United Kingdom, or Switzerland, we use safeguards that the law allows, such as the European Commission's Standard Contractual Clauses.",
      ],
    },
    {
      heading: "11. Contact",
      paragraphs: [
        "For questions about cmux Cloud and your data, contact [founders@cmux.com](mailto:founders@cmux.com).",
      ],
    },
  ],
};
