package authflow

import (
	"context"
	"fmt"
	"os/exec"
	"runtime"
	"time"

	"github.com/manaflow-ai/cmux/vault/internal/api"
	"github.com/manaflow-ai/cmux/vault/internal/authstore"
)

type Printer interface {
	Printf(format string, args ...any)
}

func Login(ctx context.Context, client *api.Client, out Printer) (authstore.Tokens, error) {
	start, err := client.StartAuth(ctx)
	if err != nil {
		return authstore.Tokens{}, err
	}

	out.Printf("Open this URL to approve cmux-vault:\n  %s\n\n", start.VerificationURL)
	out.Printf("Code: %s\n", start.UserCode)
	if runtime.GOOS == "darwin" {
		_ = exec.Command("open", start.VerificationURL).Start()
	}

	interval := time.Duration(start.IntervalSeconds) * time.Second
	if interval <= 0 {
		interval = 3 * time.Second
	}
	expiresIn := time.Duration(start.ExpiresInSeconds) * time.Second
	if expiresIn <= 0 {
		expiresIn = 15 * time.Minute
	}
	deadline := time.NewTimer(expiresIn)
	defer deadline.Stop()

	ticker := time.NewTicker(interval)
	defer ticker.Stop()

	for {
		select {
		case <-ctx.Done():
			return authstore.Tokens{}, ctx.Err()
		case <-deadline.C:
			return authstore.Tokens{}, fmt.Errorf("login expired before approval")
		case <-ticker.C:
			poll, err := client.PollAuth(ctx, start.DeviceCode)
			if err != nil {
				return authstore.Tokens{}, err
			}
			switch poll.Status {
			case "pending":
				continue
			case "approved":
				if poll.AccessToken == "" || poll.RefreshToken == "" {
					return authstore.Tokens{}, fmt.Errorf("server approved login without tokens")
				}
				return authstore.Tokens{AccessToken: poll.AccessToken, RefreshToken: poll.RefreshToken}, nil
			case "expired", "denied", "claimed", "unknown":
				return authstore.Tokens{}, fmt.Errorf("login %s", poll.Status)
			default:
				return authstore.Tokens{}, fmt.Errorf("unexpected login status %q", poll.Status)
			}
		}
	}
}
