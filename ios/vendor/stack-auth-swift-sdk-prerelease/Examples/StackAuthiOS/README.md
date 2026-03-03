# Stack Auth iOS Example

An interactive iOS application for testing all Stack Auth Swift SDK functions.

## Prerequisites

- Xcode 15.0 or later
- iOS 17.0+ Simulator or device
- Running Stack Auth backend (default: `http://localhost:8102`)

## Running the Example

### Option 1: Xcode

1. Open the project in Xcode:
   ```bash
   open StackAuthiOS.xcodeproj
   ```

2. Select an iOS Simulator (e.g., "iPhone 15 Pro" or any available device) as the destination

3. Press ⌘R to build and run

### Option 2: Command Line

```bash
# Build (replace device name with an available simulator on your system)
xcodebuild -scheme StackAuthiOS -destination 'platform=iOS Simulator,name=iPhone 15 Pro' build

# Build and run (opens simulator)
xcodebuild -scheme StackAuthiOS -destination 'platform=iOS Simulator,name=iPhone 15 Pro' run
```

## Features

The app uses a tab-based interface optimized for mobile:

- **Settings**: Configure API endpoint, project ID, and keys
- **Auth**: Sign up, sign in, sign out, get current user
- **User**: Update display name, metadata, view tokens
- **Teams**: Create, list, and manage teams
- **Logs**: View all SDK calls with full details (tap for more, long-press to copy)

Additional functions are accessible via navigation links in Settings:
- Contact Channels
- OAuth URL generation
- Token operations
- Server Users (admin)
- Server Teams (admin)
- Sessions (impersonation)

## SDK Functions Covered

### Client App
- `signUpWithCredential(email:password:)`
- `signInWithCredential(email:password:)`
- `signOut()`
- `getUser()` / `getUser(or:)`
- `getAccessToken()` / `getRefreshToken()`
- `getAuthHeaders()`
- `getOAuthUrl(provider:)`

### Current User
- `setDisplayName(_:)`
- `update(clientMetadata:)`
- `listTeams()` / `getTeam(id:)`
- `createTeam(displayName:)`
- `listContactChannels()`

### Server App
- `createUser(email:password:...)`
- `listUsers(limit:)`
- `getUser(id:)`
- `createTeam(displayName:)`
- `listTeams()`
- `createSession(userId:)`

## Logging

The Logs tab shows all SDK activity in real-time:
- **Green checkmark**: Successful calls with full response data
- **Red X**: Errors with details
- **Blue info**: In-progress calls

Tap any log entry to see full details. Long-press to copy to clipboard.

## Network Configuration

For iOS Simulator to connect to your local backend:

1. The default `localhost:8102` should work in the simulator
2. For a real device, use your computer's local IP address instead

## Troubleshooting

### "Could not connect to server"
- Ensure your Stack Auth backend is running
- Check the Base URL in Settings tab
- For real devices, use your computer's IP instead of localhost

### Build errors
- Make sure you have Xcode 15+ installed
- Try cleaning: Product → Clean Build Folder (⇧⌘K)
