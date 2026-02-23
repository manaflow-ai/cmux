# Stack Auth macOS Example

A comprehensive macOS SwiftUI application for testing all Stack Auth SDK functions interactively.

## Prerequisites

- macOS 14.0+
- Swift 5.9+
- A running Stack Auth backend (default: `http://localhost:8102`)

## Running the Example

1. Start the Stack Auth backend:
   ```bash
   cd /path/to/stack-2
   pnpm run dev
   ```

2. Open and run the example:
   ```bash
   cd Examples/StackAuthMacOS
   swift run
   ```

   Or open in Xcode:
   ```bash
   open Package.swift
   ```

## Features

The example app provides a sidebar navigation with the following sections:

### Configuration
- **Settings**: Configure API base URL, project ID, and API keys
- **Logs**: View real-time logs of all SDK operations

### Client App Testing
- **Authentication**
  - Sign up with email/password
  - Sign in with credentials
  - Sign in with wrong password (error testing)
  - Sign out
  - Get current user
  - Get user (or throw)

- **User Management**
  - Set display name
  - Update client metadata
  - Update password
  - Get access/refresh tokens
  - Get auth headers
  - Get partial user from token

- **Teams**
  - Create team
  - List user's teams
  - Get team by ID
  - List team members

- **Contact Channels**
  - List contact channels

- **OAuth**
  - Generate OAuth URLs for Google, GitHub, Microsoft
  - Test PKCE code generation

- **Tokens**
  - Get access token (JWT format)
  - Get refresh token
  - Get auth headers
  - Test different token stores

### Server App Testing
- **Server Users**
  - Create user (basic and with all options)
  - List users with pagination
  - Get user by ID
  - Delete user

- **Server Teams**
  - Create team
  - List all teams
  - Add/remove users from teams
  - List team users
  - Delete team

- **Sessions**
  - Create session (impersonation)
  - Use session tokens with client app

## Default Configuration

The example is pre-configured for local development:
- Base URL: `http://localhost:8102`
- Project ID: `internal`
- Publishable Key: `this-publishable-client-key-is-for-local-development-only`
- Secret Key: `this-secret-server-key-is-for-local-development-only`

## SDK Functions Covered

| Category | Functions |
|----------|-----------|
| Auth | signUpWithCredential, signInWithCredential, signOut, getUser, getOAuthUrl |
| User | setDisplayName, update (metadata), updatePassword, getAccessToken, getRefreshToken, getAuthHeaders, getPartialUser |
| Teams | createTeam, listTeams, getTeam, listUsers (team members) |
| Contact | listContactChannels |
| Server Users | createUser, listUsers, getUser, delete, update (metadata, password) |
| Server Teams | createTeam, listTeams, getTeam, addUser, removeUser, listUsers, delete |
| Sessions | createSession |
| Errors | EmailPasswordMismatchError, UserNotSignedInError, PasswordConfirmationMismatchError |
