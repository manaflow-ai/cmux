// wgprobe: a userspace WireGuard client (wireguard-go + gVisor netstack) for the
// mesh validation scripts. No root, no TUN, no Network Extension.
//
// Usage: wgprobe -conf <file.json>
// The conf holds {"priv","peerPub","endpoint","addrs":[...],"mtu","keepalive"}.
// Commands arrive as JSON lines on stdin; every answer is a JSON line on stdout
// carrying the command's "id". Times are wall-clock unix milliseconds so a
// script on the same host can line them up with its own API calls.
package main

import (
	"bufio"
	"context"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/netip"
	"os"
	"strconv"
	"strings"
	"sync"
	"time"

	"golang.org/x/net/icmp"
	"golang.org/x/net/ipv4"
	"gvisor.dev/gvisor/pkg/tcpip/adapters/gonet"
	"golang.zx2c4.com/wireguard/conn"
	"golang.zx2c4.com/wireguard/device"
	"golang.zx2c4.com/wireguard/tun/netstack"
)

type Conf struct {
	Priv      string   `json:"priv"`
	PeerPub   string   `json:"peerPub"`
	Endpoint  string   `json:"endpoint"`
	Addrs     []string `json:"addrs"`
	MTU       int      `json:"mtu"`
	Keepalive int      `json:"keepalive"`
	Routes    []string `json:"routes"`
}

type Cmd struct {
	ID         string `json:"id"`
	Op         string `json:"op"`
	Dst        string `json:"dst"`
	Count      int    `json:"count"`
	IntervalMs int    `json:"intervalMs"`
	TimeoutMs  int    `json:"timeoutMs"`
	Size       int    `json:"size"`
	Port       int    `json:"port"`
	Proto      string `json:"proto"`
	Want       string `json:"want"`
	PeriodMs   int    `json:"periodMs"`
	MaxMs      int    `json:"maxMs"`
	Stable     int    `json:"stable"`
	Seconds    int    `json:"seconds"`
	Dir        string `json:"dir"`
	Payload    string `json:"payload"`
	Keepalive  int    `json:"keepalive"`
}

var (
	out   = json.NewEncoder(os.Stdout)
	outMu sync.Mutex
	tnet  *netstack.Net
	dev   *device.Device
	conf  Conf
)

func now() int64 { return time.Now().UnixNano() / 1e6 }

func emit(m map[string]any) {
	outMu.Lock()
	defer outMu.Unlock()
	_ = out.Encode(m)
}

func b64hex(s string) string {
	b, err := base64.StdEncoding.DecodeString(s)
	if err != nil || len(b) != 32 {
		fmt.Fprintln(os.Stderr, "bad key")
		os.Exit(2)
	}
	return hex.EncodeToString(b)
}

func main() {
	path := ""
	for i, a := range os.Args {
		if a == "-conf" && i+1 < len(os.Args) {
			path = os.Args[i+1]
		}
	}
	raw, err := os.ReadFile(path)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(2)
	}
	if err := json.Unmarshal(raw, &conf); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(2)
	}
	if conf.MTU == 0 {
		conf.MTU = 1280
	}
	var addrs []netip.Addr
	for _, a := range conf.Addrs {
		p, err := netip.ParsePrefix(a)
		if err == nil {
			addrs = append(addrs, p.Addr())
		} else {
			addrs = append(addrs, netip.MustParseAddr(a))
		}
	}
	tun, n, err := netstack.CreateNetTUN(addrs, nil, conf.MTU)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(2)
	}
	tnet = n
	logger := &device.Logger{
		Verbosef: device.DiscardLogf,
		Errorf:   func(f string, a ...any) { fmt.Fprintf(os.Stderr, "wg: "+f+"\n", a...) },
	}
	dev = device.NewDevice(tun, conn.NewDefaultBind(), logger)
	// The endpoint is a hostname (tun-<id>.beta-vpn.freestyle.sh); UAPI needs an IP.
	host, port, err := net.SplitHostPort(conf.Endpoint)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(2)
	}
	t0 := time.Now()
	ips, err := net.LookupIP(host)
	if err != nil || len(ips) == 0 {
		fmt.Fprintln(os.Stderr, "resolve:", err)
		os.Exit(2)
	}
	var ep string
	for _, ip := range ips {
		if ip.To4() != nil {
			ep = net.JoinHostPort(ip.String(), port)
			break
		}
	}
	if ep == "" {
		ep = net.JoinHostPort(ips[0].String(), port)
	}
	resolveMs := float64(time.Since(t0).Microseconds()) / 1000
	resolved := []string{}
	for _, ip := range ips {
		resolved = append(resolved, ip.String())
	}
	routes := conf.Routes
	if len(routes) == 0 {
		routes = []string{"0.0.0.0/0", "::/0"}
	}
	var sb strings.Builder
	fmt.Fprintf(&sb, "private_key=%s\n", b64hex(conf.Priv))
	fmt.Fprintf(&sb, "public_key=%s\n", b64hex(conf.PeerPub))
	fmt.Fprintf(&sb, "endpoint=%s\n", ep)
	for _, r := range routes {
		fmt.Fprintf(&sb, "allowed_ip=%s\n", r)
	}
	if conf.Keepalive > 0 {
		fmt.Fprintf(&sb, "persistent_keepalive_interval=%d\n", conf.Keepalive)
	}
	if err := dev.IpcSet(sb.String()); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(2)
	}
	if err := dev.Up(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(2)
	}
	emit(map[string]any{"event": "up", "t": now(), "endpoint": ep, "resolved": resolved, "resolveMs": resolveMs})

	sc := bufio.NewScanner(os.Stdin)
	sc.Buffer(make([]byte, 1<<20), 1<<20)
	for sc.Scan() {
		var c Cmd
		if err := json.Unmarshal(sc.Bytes(), &c); err != nil {
			emit(map[string]any{"error": err.Error()})
			continue
		}
		if c.Op == "exit" {
			break
		}
		go run(c)
	}
	dev.Close()
}

func run(c Cmd) {
	defer func() {
		if r := recover(); r != nil {
			emit(map[string]any{"id": c.ID, "error": fmt.Sprint(r)})
		}
	}()
	switch c.Op {
	case "ping":
		doPing(c)
	case "tcp":
		ok, ms, err := tcpOnce(c.Dst, dur(c.TimeoutMs, 1000))
		emit(map[string]any{"id": c.ID, "ok": ok, "ms": ms, "err": errs(err), "t": now()})
	case "echo":
		doEcho(c)
	case "listen":
		doListen(c)
	case "watch":
		doWatch(c)
	case "stats":
		doStats(c)
	case "hold":
		doHold(c)
	case "tput":
		doTput(c)
	case "keepalive":
		_ = dev.IpcSet(fmt.Sprintf("public_key=%s\npersistent_keepalive_interval=%d\n", b64hex(conf.PeerPub), c.Keepalive))
		emit(map[string]any{"id": c.ID, "ok": true})
	default:
		emit(map[string]any{"id": c.ID, "error": "unknown op"})
	}
}

func dur(ms, def int) time.Duration {
	if ms <= 0 {
		ms = def
	}
	return time.Duration(ms) * time.Millisecond
}

func errs(err error) any {
	if err == nil {
		return nil
	}
	return err.Error()
}

func tcpOnce(dst string, timeout time.Duration) (bool, float64, error) {
	ap, err := netip.ParseAddrPort(dst)
	if err != nil {
		return false, 0, err
	}
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()
	t0 := time.Now()
	cn, err := tnet.DialContextTCPAddrPort(ctx, ap)
	ms := float64(time.Since(t0).Microseconds()) / 1000
	if err != nil {
		if ctx.Err() != nil {
			return false, ms, fmt.Errorf("timeout")
		}
		return false, ms, err
	}
	cn.Close()
	return true, ms, nil
}

func dialTO(ap netip.AddrPort, timeout time.Duration) (*gonet.TCPConn, error) {
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()
	return tnet.DialContextTCPAddrPort(ctx, ap)
}

// pingOnce sends one ICMP echo of the given payload size and waits for the reply.
func pingOnce(dst netip.Addr, seq, size int, timeout time.Duration) (float64, error) {
	pc, err := tnet.DialPingAddr(netip.Addr{}, dst)
	if err != nil {
		return 0, err
	}
	defer pc.Close()
	body := make([]byte, size)
	msg := icmp.Message{Type: ipv4.ICMPTypeEcho, Code: 0, Body: &icmp.Echo{ID: 1234, Seq: seq, Data: body}}
	if dst.Is6() {
		return 0, fmt.Errorf("ipv6 ping not implemented")
	}
	b, _ := msg.Marshal(nil)
	_ = pc.SetReadDeadline(time.Now().Add(timeout))
	t0 := time.Now()
	if _, err := pc.Write(b); err != nil {
		return 0, err
	}
	buf := make([]byte, 65536)
	for {
		n, err := pc.Read(buf)
		if err != nil {
			return 0, err
		}
		rm, err := icmp.ParseMessage(1, buf[:n])
		if err != nil {
			continue
		}
		if rm.Type == ipv4.ICMPTypeEchoReply {
			if e, ok := rm.Body.(*icmp.Echo); ok && e.Seq == seq {
				return float64(time.Since(t0).Microseconds()) / 1000, nil
			}
		}
	}
}

func doPing(c Cmd) {
	dst := netip.MustParseAddr(c.Dst)
	count := c.Count
	if count <= 0 {
		count = 1
	}
	recv := 0
	var rtts []float64
	for i := 0; i < count; i++ {
		rtt, err := pingOnce(dst, i+1, c.Size, dur(c.TimeoutMs, 1000))
		if err == nil {
			recv++
			rtts = append(rtts, rtt)
		}
		if c.IntervalMs > 0 && i+1 < count {
			time.Sleep(time.Duration(c.IntervalMs) * time.Millisecond)
		}
	}
	emit(map[string]any{"id": c.ID, "sent": count, "recv": recv, "rtts": rtts, "size": c.Size, "t": now()})
}

func doEcho(c Cmd) {
	ap := netip.MustParseAddrPort(c.Dst)
	t0 := time.Now()
	cn, err := dialTO(ap, dur(c.TimeoutMs, 5000))
	if err != nil {
		emit(map[string]any{"id": c.ID, "ok": false, "err": err.Error()})
		return
	}
	defer cn.Close()
	_ = cn.SetDeadline(time.Now().Add(dur(c.TimeoutMs, 3000)))
	fmt.Fprintf(cn, "%s\n", c.Payload)
	line, err := bufio.NewReader(cn).ReadString('\n')
	emit(map[string]any{"id": c.ID, "ok": err == nil, "reply": strings.TrimSpace(line), "err": errs(err), "ms": float64(time.Since(t0).Microseconds()) / 1000, "t": now()})
}

func doListen(c Cmd) {
	ln, err := tnet.ListenTCPAddrPort(netip.AddrPortFrom(netip.Addr{}, uint16(c.Port)))
	if err != nil {
		// gVisor wants a concrete address family; listen on each configured address.
		for _, a := range conf.Addrs {
			p, _ := netip.ParsePrefix(a)
			addr := p.Addr()
			if !p.IsValid() {
				addr = netip.MustParseAddr(a)
			}
			l, e := tnet.ListenTCPAddrPort(netip.AddrPortFrom(addr, uint16(c.Port)))
			if e != nil {
				emit(map[string]any{"id": c.ID, "error": e.Error()})
				continue
			}
			go serve(c, l)
		}
		emit(map[string]any{"id": c.ID, "ok": true})
		return
	}
	emit(map[string]any{"id": c.ID, "ok": true})
	serve(c, ln)
}

func serve(c Cmd, ln net.Listener) {
	for {
		cn, err := ln.Accept()
		if err != nil {
			return
		}
		emit(map[string]any{"id": c.ID, "event": "accept", "remote": cn.RemoteAddr().String(), "t": now()})
		go func(cn net.Conn) {
			defer cn.Close()
			_ = cn.SetDeadline(time.Now().Add(10 * time.Second))
			line, err := bufio.NewReader(cn).ReadString('\n')
			if err == nil {
				fmt.Fprintf(cn, "pong %s\n", strings.TrimSpace(line))
			}
		}(cn)
	}
}

// watch launches one attempt every periodMs. Every attempt completes within its
// timeout by its own timer, whatever the dial does. Once at least `stable`
// completed attempts in a row (by start order, ending at the newest completed
// one) have the wanted outcome, it reports the start time of the first attempt
// of that run ("first") and the completion time of the earliest successful
// attempt ("firstOkEnd").
func doWatch(c Cmd) {
	period := dur(c.PeriodMs, 20)
	attemptTO := dur(c.TimeoutMs, 500)
	maxD := dur(c.MaxMs, 30000)
	stable := c.Stable
	if stable <= 0 {
		stable = 3
	}
	wantOpen := c.Want != "closed"
	type att struct {
		start, end int64
		done, ok   bool
	}
	var mu sync.Mutex
	var atts []*att
	emit(map[string]any{"id": c.ID, "event": "armed", "t": now()})
	deadline := time.Now().Add(maxD)
	tick := time.NewTicker(period)
	defer tick.Stop()
	trace := func() []string {
		var out []string
		from := len(atts) - 30
		if from < 0 {
			from = 0
		}
		for _, x := range atts[from:] {
			st := "."
			if x.done {
				st = "x"
				if x.ok {
					st = "o"
				}
			}
			out = append(out, fmt.Sprintf("%d%s%d", x.start%100000, st, x.end-x.start))
		}
		return out
	}
	for {
		a := &att{start: now()}
		mu.Lock()
		atts = append(atts, a)
		mu.Unlock()
		go func() {
			res := make(chan bool, 1)
			go func() {
				if c.Proto == "icmp" {
					_, err := pingOnce(netip.MustParseAddr(c.Dst), int(a.start%60000), 0, attemptTO)
					res <- err == nil
				} else {
					ok, _, _ := tcpOnce(c.Dst, attemptTO)
					res <- ok
				}
			}()
			var ok bool
			select {
			case ok = <-res:
			case <-time.After(attemptTO + 20*time.Millisecond):
				ok = false
			}
			mu.Lock()
			a.ok, a.done, a.end = ok, true, now()
			mu.Unlock()
		}()
		mu.Lock()
		n := 0
		for n < len(atts) && atts[n].done {
			n++
		}
		run := 0
		var first int64
		for i := n - 1; i >= 0; i-- {
			if atts[i].ok == wantOpen {
				run++
				first = atts[i].start
			} else {
				break
			}
		}
		var firstOkEnd int64
		for _, x := range atts {
			if x.done && x.ok && (firstOkEnd == 0 || x.end < firstOkEnd) {
				firstOkEnd = x.end
			}
		}
		total := len(atts)
		if run >= stable {
			tr := trace()
			mu.Unlock()
			emit(map[string]any{"id": c.ID, "event": "done", "first": first, "firstOkEnd": firstOkEnd, "attempts": total, "t": now(), "trace": tr})
			return
		}
		if time.Now().After(deadline) {
			tr := trace()
			mu.Unlock()
			emit(map[string]any{"id": c.ID, "event": "timeout", "attempts": total, "t": now(), "trace": tr})
			return
		}
		mu.Unlock()
		<-tick.C
	}
}

func doStats(c Cmd) {
	s, err := dev.IpcGet()
	if err != nil {
		emit(map[string]any{"id": c.ID, "error": err.Error()})
		return
	}
	m := map[string]any{"id": c.ID, "t": now()}
	for _, line := range strings.Split(s, "\n") {
		k, v, ok := strings.Cut(line, "=")
		if !ok {
			continue
		}
		switch k {
		case "last_handshake_time_sec", "last_handshake_time_nsec", "rx_bytes", "tx_bytes":
			n, _ := strconv.ParseInt(v, 10, 64)
			m[k] = n
		}
	}
	emit(m)
}

// tput talks to the validation sink on the VM: "DOWN <s>\n" makes it send
// for s seconds; "UP\n" makes it read until EOF and answer "<bytes>\n".
func doTput(c Cmd) {
	ap := netip.MustParseAddrPort(c.Dst)
	cn, err := dialTO(ap, dur(c.TimeoutMs, 5000))
	if err != nil {
		emit(map[string]any{"id": c.ID, "error": err.Error()})
		return
	}
	defer cn.Close()
	secs := c.Seconds
	if secs <= 0 {
		secs = 10
	}
	if c.Dir == "down" {
		fmt.Fprintf(cn, "DOWN %d\n", secs)
		t0 := time.Now()
		n, _ := io.Copy(io.Discard, cn)
		el := time.Since(t0).Seconds()
		emit(map[string]any{"id": c.ID, "dir": "down", "bytes": n, "seconds": el, "mbps": float64(n) * 8 / el / 1e6})
		return
	}
	fmt.Fprintf(cn, "UP\n")
	buf := make([]byte, 64*1024)
	t0 := time.Now()
	var sent int64
	for time.Since(t0) < time.Duration(secs)*time.Second {
		w, err := cn.Write(buf)
		sent += int64(w)
		if err != nil {
			break
		}
	}
	_ = cn.CloseWrite()
	line, _ := bufio.NewReader(cn).ReadString('\n')
	el := time.Since(t0).Seconds()
	got, _ := strconv.ParseInt(strings.TrimSpace(line), 10, 64)
	emit(map[string]any{"id": c.ID, "dir": "up", "bytes": got, "sent": sent, "seconds": el, "mbps": float64(got) * 8 / el / 1e6})
}

var holds sync.Map // id -> *holdConn

type holdConn struct {
	cn *gonet.TCPConn
	rd *bufio.Reader
}

// hold: with Payload "open", dial Dst and keep the connection (name = Proto);
// with "send", write a line on the named connection and wait for the reply.
func doHold(c Cmd) {
	if c.Payload == "open" {
		cn, err := dialTO(netip.MustParseAddrPort(c.Dst), dur(c.TimeoutMs, 5000))
		if err != nil {
			emit(map[string]any{"id": c.ID, "ok": false, "err": err.Error()})
			return
		}
		h := &holdConn{cn: cn, rd: bufio.NewReader(cn)}
		holds.Store(c.Proto, h)
		_ = cn.SetDeadline(time.Now().Add(5 * time.Second))
		fmt.Fprintf(cn, "open\n")
		line, err := h.rd.ReadString('\n')
		_ = cn.SetDeadline(time.Time{})
		emit(map[string]any{"id": c.ID, "ok": err == nil, "reply": strings.TrimSpace(line), "t": now()})
		return
	}
	v, ok := holds.Load(c.Proto)
	if !ok {
		emit(map[string]any{"id": c.ID, "ok": false, "err": "no such hold"})
		return
	}
	h := v.(*holdConn)
	t0 := time.Now()
	_ = h.cn.SetDeadline(time.Now().Add(dur(c.TimeoutMs, 10000)))
	_, werr := fmt.Fprintf(h.cn, "again\n")
	line, err := h.rd.ReadString('\n')
	if err == nil {
		err = werr
	}
	emit(map[string]any{"id": c.ID, "ok": err == nil, "reply": strings.TrimSpace(line), "err": errs(err), "ms": float64(time.Since(t0).Microseconds()) / 1000, "t": now()})
}
