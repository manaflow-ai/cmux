package main

import (
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"strings"

	tea "github.com/charmbracelet/bubbletea"

	"github.com/manaflow-ai/cmux/tools/cmux-home/go/internal/home"
)

func main() {
	if err := run(os.Args[1:], os.Stdout, os.Stderr, os.Stdin); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

func run(args []string, stdout io.Writer, stderr io.Writer, stdin io.Reader) error {
	var data string
	var once bool

	flags := flag.NewFlagSet("cmux-home", flag.ContinueOnError)
	flags.SetOutput(stderr)
	flags.StringVar(&data, "data", "", "state JSON path, inline JSON, or - for stdin")
	flags.BoolVar(&once, "once", false, "print a deterministic summary and exit")
	flags.Usage = func() {
		fmt.Fprintln(flags.Output(), "Usage: cmux-home [--data <json>] [--once]")
		fmt.Fprintln(flags.Output())
		fmt.Fprintln(flags.Output(), "A Go/Charm Bubble Tea prototype for the cmux home screen.")
		flags.PrintDefaults()
	}

	if err := flags.Parse(args); err != nil {
		if errors.Is(err, flag.ErrHelp) {
			return nil
		}
		return err
	}

	state, _, err := loadState(data, stdin)
	if err != nil {
		return err
	}

	if once {
		_, err := io.WriteString(stdout, home.Summary(state))
		return err
	}

	program := tea.NewProgram(home.NewModel(state), tea.WithAltScreen())
	_, err = program.Run()
	return err
}

func loadState(data string, stdin io.Reader) (home.HomeState, string, error) {
	trimmed := strings.TrimSpace(data)
	switch {
	case trimmed == "":
		return home.LoadState("")
	case trimmed == "-":
		bytes, err := io.ReadAll(stdin)
		if err != nil {
			return home.HomeState{}, "stdin", err
		}
		state, err := home.ParseState(bytes)
		return state, "stdin", err
	case strings.HasPrefix(trimmed, "{"), strings.HasPrefix(trimmed, "["):
		state, err := home.ParseState([]byte(trimmed))
		return state, "inline", err
	default:
		return home.LoadState(trimmed)
	}
}
