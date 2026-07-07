# cmux-mux Go Client

Stdlib-only Go client for the cmux-mux Unix-socket JSON-lines protocol.

## Build

```bash
cd mux/bindings/go
go build ./...
```

## Usage

```go
ctx := context.Background()
client, err := cmuxmux.NewClient(cmuxmux.Options{SocketPath: os.Getenv("CMUX_MUX_SOCKET")})
if err != nil {
    panic(err)
}
defer client.Close()
surface, err := client.NewWorkspace(ctx, cmuxmux.NewWorkspaceOptions{})
if err != nil {
    panic(err)
}
text := "echo hello\r"
_ = client.Send(ctx, surface.Surface, cmuxmux.SendOptions{Text: &text})
screen, _ := client.ReadScreen(ctx, surface.Surface)
fmt.Println(screen.Text)
```

## E2E

```bash
cd mux/bindings/go
CMUX_MUX_SOCKET=/path/to/session.sock go run ./cmd/e2e
```
