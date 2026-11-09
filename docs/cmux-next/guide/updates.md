# Install, update, and nightly

How cmux-next updates and how to check your build.

## Updates

- nightly-next: the app checks the update feed and shows a Restart to Update card. Restart relaunches at once. Your terminals, agents, and chats come back.
- cmux NEXT DEV: run the update script again.

Quitting keeps sessions by default. Agents keep running in the acpmux daemon while the app restarts.

## Check your build

```bash
cmux version
```

## Server restarts

When the app and the background server are on different versions, Settings > Server shows Restart Recommended. cmux never restarts the server on its own. You choose when.
