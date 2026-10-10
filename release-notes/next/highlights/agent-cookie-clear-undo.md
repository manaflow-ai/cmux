title: An agent's cookie clear in a WebKit tab can be undone
category: fixed

When an agent cleared cookies in a WebKit tab, cmux deleted the cookies of every site in that browser profile, so you were signed out everywhere. Now a clear removes only the cookies of the tab's own site. cmux first saves the removed cookies in an encrypted backup on this Mac, and the agent gets an id that puts them back. A backup is deleted when it is restored or when every cookie in it has expired.
