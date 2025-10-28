# Nested Environment Variables

cmux now supports hierarchical resolution of environment variables through nested `.env` files in your workspace. This allows you to define environment-specific configurations at different levels of your directory structure, with child directories overriding parent directories.

## Overview

The nested environment variable system provides:

- **Hierarchical Resolution**: Variables defined in child directories override those in parent directories
- **Multiple File Support**: Load from `.env`, `.env.local`, `.env.development`, and `.env.development.local`
- **Automatic Discovery**: The system automatically finds and loads all `.env` files in the directory hierarchy
- **Performance Caching**: Parsed results are cached with automatic invalidation on file changes
- **Global Baseline**: Environment-level configurations serve as the global baseline

## How It Works

### Resolution Order

When resolving environment variables for a specific directory, the system:

1. Starts with **global environment variables** from the environment configuration (if any)
2. Walks up the directory tree from workspace root to the target directory
3. For each directory, loads `.env` files in priority order:
   - `.env` (lowest priority)
   - `.env.local`
   - `.env.development`
   - `.env.development.local` (highest priority)
4. Variables in files closer to the target directory override those in parent directories

### Example Hierarchy

```
/root/workspace/
├── .env                    # BASE_URL=https://api.example.com
│                          # API_KEY=global-key
├── apps/
│   ├── .env               # BASE_URL=https://apps.example.com
│   │                      # APPS_VAR=apps-value
│   ├── www/
│   │   ├── .env           # BASE_URL=https://www.example.com
│   │   │                  # WWW_VAR=www-value
│   │   └── package.json
│   └── server/
│       ├── .env           # BASE_URL=https://server.example.com
│       │                  # SERVER_VAR=server-value
│       └── package.json
└── packages/
    └── shared/
        ├── .env           # SHARED_VAR=shared-value
        └── package.json
```

**When resolving for `/root/workspace/apps/www`:**

```
{
  "API_KEY": "global-key",           // From /root/workspace/.env
  "BASE_URL": "https://www.example.com",  // From /root/workspace/apps/www/.env (overrides parents)
  "APPS_VAR": "apps-value",          // From /root/workspace/apps/.env
  "WWW_VAR": "www-value"             // From /root/workspace/apps/www/.env
}
```

**When resolving for `/root/workspace/apps/server`:**

```
{
  "API_KEY": "global-key",           // From /root/workspace/.env
  "BASE_URL": "https://server.example.com", // From /root/workspace/apps/server/.env
  "APPS_VAR": "apps-value",          // From /root/workspace/apps/.env
  "SERVER_VAR": "server-value"       // From /root/workspace/apps/server/.env
}
```

## Usage

### Setting Up Environment Variables

1. **Global Configuration** (Optional):
   - Set environment-level variables in the cmux UI under Environments
   - These serve as the baseline for all workspaces

2. **Workspace Root Variables**:
   ```bash
   # /root/workspace/.env
   API_KEY=my-global-key
   DATABASE_URL=postgres://localhost:5432/db
   LOG_LEVEL=info
   ```

3. **Directory-Specific Overrides**:
   ```bash
   # /root/workspace/apps/frontend/.env
   API_KEY=frontend-specific-key  # Overrides root
   BASE_URL=https://frontend.example.com

   # /root/workspace/apps/backend/.env
   API_KEY=backend-specific-key   # Overrides root
   BASE_URL=https://backend.example.com
   DATABASE_URL=postgres://localhost:5432/backend-db  # Overrides root
   ```

### Environment Variable Priority

From lowest to highest priority:

1. **Global Environment** (from cmux Environment configuration)
2. **Workspace Root** (`.env` files in `/root/workspace`)
3. **Parent Directories** (`.env` files in parent dirs)
4. **Current Directory** (`.env` files in target directory)
5. **File Type Priority** (within same directory):
   - `.env` (lowest)
   - `.env.local`
   - `.env.development`
   - `.env.development.local` (highest)
6. **CMUX System Variables** (always highest priority):
   - `CMUX_PROMPT`
   - `CMUX_TASK_RUN_ID`
   - `CMUX_TASK_RUN_JWT`
   - `PROMPT`

### File Naming Conventions

The system recognizes these `.env` file variants (in priority order):

- **`.env`**: Base environment variables (committed to git)
- **`.env.local`**: Local overrides (add to .gitignore)
- **`.env.development`**: Development-specific variables
- **`.env.development.local`**: Local development overrides (add to .gitignore)

## Use Cases

### Monorepo with Multiple Services

```
workspace/
├── .env                      # Shared credentials
├── services/
│   ├── api/
│   │   └── .env             # API-specific config
│   ├── worker/
│   │   └── .env             # Worker-specific config
│   └── web/
│       └── .env             # Web-specific config
```

### Environment-Specific Configurations

```
workspace/
├── .env                      # Production defaults
├── .env.development          # Development overrides
└── packages/
    └── backend/
        ├── .env              # Backend defaults
        └── .env.development  # Backend dev overrides
```

### Team Member Overrides

```
workspace/
├── .env                      # Team shared config
└── .env.local               # Your personal overrides (gitignored)
```

## API Reference

### Server-Side (apps/server)

```typescript
import { EnvResolver } from "./utils/envResolver";

// Create resolver with global variables
const resolver = new EnvResolver("/root/workspace", {
  GLOBAL_VAR: "value"
});

// Resolve for specific directory
const envVars = resolver.resolve("/root/workspace/apps/www");

// Get source information for debugging
const sourceMap = resolver.getVariableSourceMap("/root/workspace/apps/www");
console.log(sourceMap);
// {
//   "API_KEY": { value: "secret", source: "/root/workspace/.env" },
//   "BASE_URL": { value: "http://www.example.com", source: "/root/workspace/apps/www/.env" }
// }

// Discover all .env files
const allFiles = resolver.discoverAllEnvFiles();

// Clear cache when files change
resolver.clearCache();

// Invalidate specific path
resolver.invalidatePath("/root/workspace/apps/www");
```

### Worker-Side (apps/worker)

The worker automatically initializes the EnvResolver when creating a terminal. Environment variables are resolved for the terminal's working directory.

```typescript
import {
  initializeEnvResolver,
  resolveEnvForPath,
  clearEnvCache
} from "./envResolver";

// Initialize (done automatically in createTerminal)
initializeEnvResolver("/root/workspace", globalEnvVars);

// Resolve for current directory
const envVars = resolveEnvForPath(process.cwd());

// Clear cache if needed
clearEnvCache();
```

## Best Practices

1. **Commit `.env` with defaults**: Check in `.env` files with safe default values or placeholders
2. **Use `.env.local` for secrets**: Add `.env.local` to `.gitignore` for sensitive values
3. **Document required variables**: Add a `.env.example` showing all required variables
4. **Keep hierarchy simple**: Avoid deep nesting of environment overrides
5. **Use descriptive names**: Make variable names self-documenting

## Migration Guide

### From Global-Only Environment Variables

**Before:**
```bash
# All variables defined in cmux Environment configuration
API_KEY=global-key
FRONTEND_URL=https://frontend.example.com
BACKEND_URL=https://backend.example.com
```

**After:**
```bash
# Global (in cmux Environment configuration)
API_KEY=global-key

# /root/workspace/apps/frontend/.env
BASE_URL=https://frontend.example.com

# /root/workspace/apps/backend/.env
BASE_URL=https://backend.example.com
```

### Testing Your Configuration

1. Create `.env` files at different levels
2. Use the variable source map to debug:
   ```typescript
   const sourceMap = resolver.getVariableSourceMap("/path/to/dir");
   console.log(JSON.stringify(sourceMap, null, 2));
   ```
3. Check logs for resolution messages:
   ```
   [EnvResolver] Loaded 5 variables from /root/workspace/.env
   [EnvResolver] Loaded 3 variables from /root/workspace/apps/.env
   [EnvResolver] Resolved 8 total variables for /root/workspace/apps
   ```

## Troubleshooting

### Variable Not Being Loaded

1. Check file exists: `ls -la /path/to/.env`
2. Check file permissions: `chmod 644 /path/to/.env`
3. Verify syntax: No spaces around `=`, one variable per line
4. Check logs for parse errors

### Variable Has Wrong Value

1. Use `getVariableSourceMap()` to see which file is providing the value
2. Check for typos in variable names (case-sensitive)
3. Verify file priority order
4. Ensure `.env` files are in the correct directories

### Performance Issues

1. Clear cache if files change frequently: `resolver.clearCache()`
2. Reduce number of `.env` files if possible
3. Use `.env.local` variants sparingly

## Security Considerations

- **Never commit secrets** to `.env` files in git
- Use `.env.local` for sensitive values and add to `.gitignore`
- Consider using encrypted secrets management for production
- Avoid logging environment variable values
- Use the cmux Environment configuration for team-shared secrets

## Future Enhancements

Potential future improvements:

- File watching for automatic cache invalidation
- Schema validation for required variables
- Variable interpolation (e.g., `BASE_URL=${PROTOCOL}://${HOST}`)
- Encrypted .env file support
- UI for managing nested .env files
- `.env` file diff viewer in task runs
