title: The terminal you restart comes back first after a relaunch
category: fixed
pr: https://github.com/manaflow-ai/cmux/pull/40746

While cmux starts your agents again after a relaunch, the terminal you see and a terminal you restart with Restart Shell Here start at once. They no longer wait for the agents in your other workspaces.
