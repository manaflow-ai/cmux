pub(crate) const DEMO_MARKDOWN_CONTENT: &str = r#"# Authentication System Design

I'll help you build a secure authentication system. Here's my plan:

## Overview

This implementation will use **JWT tokens** for stateless authentication with `bcrypt` for password hashing.

### Key Components

- **Token Service**: Handles JWT creation and validation
- **Password Hasher**: Secure bcrypt-based hashing
- **Middleware**: Request authentication layer

## Implementation

Here's the core token generation code:

```rust
use jsonwebtoken::{encode, decode, Header, Validation, EncodingKey, DecodingKey};
use serde::{Deserialize, Serialize};

#[derive(Debug, Serialize, Deserialize)]
struct Claims {
    sub: String,
    exp: usize,
    iat: usize,
}

fn generate_token(user_id: &str, secret: &[u8]) -> Result<String, Error> {
    let claims = Claims {
        sub: user_id.to_owned(),
        exp: (chrono::Utc::now() + chrono::Duration::hours(24)).timestamp() as usize,
        iat: chrono::Utc::now().timestamp() as usize,
    };

    encode(&Header::default(), &claims, &EncodingKey::from_secret(secret))
}
```

### Password Hashing

```python
import bcrypt

def hash_password(password: str) -> bytes:
    salt = bcrypt.gensalt(rounds=12)
    return bcrypt.hashpw(password.encode(), salt)

def verify_password(password: str, hashed: bytes) -> bool:
    return bcrypt.checkpw(password.encode(), hashed)
```

## Configuration

Add these to your `config.toml`:

```toml
[auth]
jwt_secret = "your-secret-key-here"
token_expiry_hours = 24
bcrypt_rounds = 12
```

## API Endpoints

The following endpoints will be created:

• `POST /auth/register` - Create new user account
• `POST /auth/login` - Authenticate and receive token
• `POST /auth/logout` - Invalidate current token
• `GET /auth/me` - Get current user info

### Example Request

```json
{
  "username": "johndoe",
  "password": "secure_password_123",
  "email": "john@example.com"
}
```

## Security Notes

1. Always use HTTPS in production
2. Store secrets in environment variables
3. Implement rate limiting on auth endpoints
4. Use secure cookie settings for token storage

Let me start implementing this now."#;

pub(crate) const DEMO_CODE_EXAMPLES: &str = r#"## Rate Limiting Implementation

I'll add rate limiting using a token bucket algorithm. Here are examples in multiple languages:

### TypeScript Implementation

```typescript
interface RateLimiter {
  tokens: number;
  lastRefill: number;
  maxTokens: number;
  refillRate: number;
}

function createRateLimiter(maxTokens: number, refillRate: number): RateLimiter {
  return {
    tokens: maxTokens,
    lastRefill: Date.now(),
    maxTokens,
    refillRate,
  };
}

function tryConsume(limiter: RateLimiter): boolean {
  const now = Date.now();
  const elapsed = (now - limiter.lastRefill) / 1000;
  limiter.tokens = Math.min(limiter.maxTokens, limiter.tokens + elapsed * limiter.refillRate);
  limiter.lastRefill = now;

  if (limiter.tokens >= 1) {
    limiter.tokens -= 1;
    return true;
  }
  return false;
}
```

### Go Implementation

```go
package ratelimit

import (
    "sync"
    "time"
)

type Limiter struct {
    mu         sync.Mutex
    tokens     float64
    maxTokens  float64
    refillRate float64
    lastRefill time.Time
}

func NewLimiter(maxTokens, refillRate float64) *Limiter {
    return &Limiter{
        tokens:     maxTokens,
        maxTokens:  maxTokens,
        refillRate: refillRate,
        lastRefill: time.Now(),
    }
}

func (l *Limiter) Allow() bool {
    l.mu.Lock()
    defer l.mu.Unlock()

    now := time.Now()
    elapsed := now.Sub(l.lastRefill).Seconds()
    l.tokens = min(l.maxTokens, l.tokens+elapsed*l.refillRate)
    l.lastRefill = now

    if l.tokens >= 1 {
        l.tokens--
        return true
    }
    return false
}
```

### SQL Schema

```sql
CREATE TABLE rate_limits (
    id SERIAL PRIMARY KEY,
    client_id VARCHAR(255) NOT NULL,
    tokens DECIMAL(10, 2) NOT NULL,
    last_refill TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    UNIQUE(client_id)
);

CREATE INDEX idx_rate_limits_client ON rate_limits(client_id);
```

### Shell Script for Testing

```bash
#!/bin/bash
# Test rate limiting endpoint

for i in {1..20}; do
    response=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:8080/api/test)
    echo "Request $i: HTTP $response"
    sleep 0.1
done
```

### YAML Configuration

```yaml
rate_limiting:
  enabled: true
  default_limits:
    requests_per_minute: 60
    burst_size: 10
  endpoints:
    /auth/login:
      requests_per_minute: 5
      burst_size: 2
    /api/heavy:
      requests_per_minute: 10
      burst_size: 3
```

The rate limiter is now ready to use with your authentication system!"#;
