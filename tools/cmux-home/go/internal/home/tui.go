package home

import (
	"fmt"
	"strings"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
)

type Model struct {
	state    HomeState
	groups   []StatusGroup
	selected int
	input    string
	width    int
	height   int
}

type styles struct {
	header   lipgloss.Style
	muted    lipgloss.Style
	section  lipgloss.Style
	selected lipgloss.Style
	panel    lipgloss.Style
	prompt   lipgloss.Style
}

func NewModel(state HomeState) Model {
	state.Normalize()
	return Model{
		state:  state,
		groups: GroupSessions(state.Sessions),
		width:  100,
		height: 30,
	}
}

func (m Model) Init() tea.Cmd {
	return nil
}

func (m Model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.WindowSizeMsg:
		m.width = msg.Width
		m.height = msg.Height
	case tea.KeyMsg:
		if msg.String() == "q" {
			return m, tea.Quit
		}
		switch msg.Type {
		case tea.KeyCtrlC, tea.KeyEsc:
			return m, tea.Quit
		case tea.KeyUp:
			if m.selected > 0 {
				m.selected--
			}
		case tea.KeyDown:
			if m.selected < len(m.flatSessions())-1 {
				m.selected++
			}
		case tea.KeyBackspace:
			if len(m.input) > 0 {
				m.input = m.input[:len(m.input)-1]
			}
		case tea.KeyRunes:
			m.input += msg.String()
		default:
			if msg.String() == "q" {
				return m, tea.Quit
			}
		}
	}
	return m, nil
}

func (m Model) View() string {
	s := defaultStyles()
	header := s.header.Render("cmux home")
	counts := s.muted.Render(adapterCountLine(m.state.Sessions))

	left := m.renderGroups(s)
	right := m.renderDetails(s)
	body := lipgloss.JoinHorizontal(lipgloss.Top, left, right)

	prompt := s.prompt.Render("task> " + m.input)
	help := s.muted.Render("read-only prototype - up/down select - q quits")

	return lipgloss.JoinVertical(
		lipgloss.Left,
		header,
		counts,
		"",
		body,
		"",
		prompt,
		help,
	)
}

func (m Model) renderGroups(s styles) string {
	var b strings.Builder
	flatIndex := 0
	for _, group := range m.groups {
		fmt.Fprintf(&b, "%s (%d)\n", s.section.Render(group.Status), len(group.Sessions))
		for _, session := range group.Sessions {
			prefix := "  "
			lineStyle := lipgloss.NewStyle()
			if flatIndex == m.selected {
				prefix = "> "
				lineStyle = s.selected
			}
			line := fmt.Sprintf("%s[%s] %s", prefix, session.Adapter, session.Title)
			b.WriteString(lineStyle.Render(truncate(line, 42)))
			b.WriteString("\n")
			flatIndex++
		}
		b.WriteString("\n")
	}
	return s.panel.Width(46).Render(strings.TrimRight(b.String(), "\n"))
}

func (m Model) renderDetails(s styles) string {
	session, ok := m.selectedSession()
	if !ok {
		return s.panel.Width(48).Render(s.muted.Render("No sessions yet."))
	}

	var b strings.Builder
	fmt.Fprintf(&b, "%s\n", s.section.Render(session.Title))
	fmt.Fprintf(&b, "adapter: %s\n", session.Adapter)
	fmt.Fprintf(&b, "status: %s\n", session.Status)
	if cwd := session.WorkingDir(); cwd != "" {
		fmt.Fprintf(&b, "cwd: %s\n", cwd)
	}
	if session.Branch != "" {
		fmt.Fprintf(&b, "branch: %s\n", session.Branch)
	}
	fmt.Fprintf(&b, "session: %s\n", session.ResumeSessionID())
	if adapter, ok := AdapterFor(session.Adapter); ok {
		fmt.Fprintf(&b, "resume: %s\n", adapter.ResumeCommand(session))
		b.WriteString("\nknown gaps:\n")
		for _, gap := range adapter.FeatureGaps {
			fmt.Fprintf(&b, "- %s\n", gap)
		}
	}
	if preview := session.PreviewText(); preview != "" {
		fmt.Fprintf(&b, "\npreview:\n%s\n", preview)
	}
	return s.panel.Width(58).Render(b.String())
}

func (m Model) selectedSession() (Session, bool) {
	sessions := m.flatSessions()
	if len(sessions) == 0 {
		return Session{}, false
	}
	index := m.selected
	if index < 0 {
		index = 0
	}
	if index >= len(sessions) {
		index = len(sessions) - 1
	}
	return sessions[index], true
}

func (m Model) flatSessions() []Session {
	total := 0
	for _, group := range m.groups {
		total += len(group.Sessions)
	}
	sessions := make([]Session, 0, total)
	for _, group := range m.groups {
		sessions = append(sessions, group.Sessions...)
	}
	return sessions
}

func defaultStyles() styles {
	return styles{
		header: lipgloss.NewStyle().
			Bold(true).
			Foreground(lipgloss.Color("15")).
			Background(lipgloss.Color("62")).
			Padding(0, 1),
		muted: lipgloss.NewStyle().
			Foreground(lipgloss.Color("244")),
		section: lipgloss.NewStyle().
			Bold(true).
			Foreground(lipgloss.Color("86")),
		selected: lipgloss.NewStyle().
			Foreground(lipgloss.Color("15")).
			Background(lipgloss.Color("238")),
		panel: lipgloss.NewStyle().
			Padding(1, 2).
			Border(lipgloss.NormalBorder()).
			BorderForeground(lipgloss.Color("238")),
		prompt: lipgloss.NewStyle().
			Foreground(lipgloss.Color("15")).
			Background(lipgloss.Color("236")).
			Padding(0, 1),
	}
}

func adapterCountLine(sessions []Session) string {
	parts := make([]string, 0)
	for _, count := range AdapterCounts(sessions) {
		parts = append(parts, fmt.Sprintf("%s %d", count.Adapter, count.Count))
	}
	return strings.Join(parts, "  ")
}

func truncate(value string, max int) string {
	if max <= 0 || len(value) <= max {
		return value
	}
	if max <= 3 {
		return value[:max]
	}
	return value[:max-3] + "..."
}
