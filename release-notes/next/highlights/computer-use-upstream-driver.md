title: Try the new Computer Use driver
category: security
docs: https://cmux.com/docs/computer-use

Settings > Computer Use Driver has a new choice, Upstream. It runs a separate Computer Use helper built on the upstream Cua Driver, and macOS asks for its permissions separately. Only cmux's own agent sessions of your user can reach that helper; other users on the same Mac and other programs are refused. Legacy stays the default.
