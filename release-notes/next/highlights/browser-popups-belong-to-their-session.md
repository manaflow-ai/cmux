title: A popup belongs to the agent session whose page opened it
category: fixed

On the shared headless browser, a popup that an agent's page opened was nobody's until the agent first used it. Another session's address rule could then stop it, for example a remote session stopping a local session's popup that loaded through the local session's proxy. A popup now belongs to the sessions that drive its opener before its first request, so only their rules apply to it.
