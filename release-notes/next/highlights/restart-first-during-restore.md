title: The terminal you restart comes back first after a relaunch
category: fixed
pr: https://github.com/manaflow-ai/cmux/pull/40746

While cmux starts your agents again after a relaunch, a terminal you restart with Restart Shell Here starts at once. It no longer waits for the agents in your other workspaces.
