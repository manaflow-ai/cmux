title: An agent's cookie clear in a WebKit tab can be undone
category: fixed
docs: https://cmux.com/docs/browser-automation

When an agent clears cookies in a WebKit tab, only that tab's site is cleared, not every site in the profile. cmux keeps an encrypted backup on this Mac so the agent can put the cookies back.
