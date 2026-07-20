// Command lodor-menu is the on-screen renderer for the OnionOS "Lodor Sync" App.
//
// WHY THIS EXISTS: OnionOS (RetroArch-based, SigmaStar SSD202D, 640x480) ships NO reusable
// interactive-menu primitive an App can call. Its MainUI list builder is a closed binary;
// every MinUI/NextUI tool (minui-list, minui-presenter, show2.elf) links libraries that are
// absent on OnionOS (they need /usr/trimui/lib + SDL). The only no-fork way to draw a real
// menu from an App is to write the framebuffer directly. This binary reuses the Lodor muOS
// lane's proven, CGO-free, stdlib-only ui package: the framebuffer backend reads the panel's
// REAL pixel format via ioctl (16- or 32-bpp, no assumption) and input comes from
// /dev/input/event*. No SDL, no cgo -> same build invariants as the engine.
//
// HOST RENDERING ONLY. It draws what the shell (launch.sh) tells it and reports the user's
// choice. ALL RomM logic stays in the engine; this binary never touches the network, config,
// token, or saves. Honesty (feedback_no_fake_ui_state) is the shell's job: it only asks this
// binary to show a step "done" once the engine actually returned success.
//
// Subcommands:
//
//	lodor-menu menu  --title T [--footer HINT] [--status LINE] -- ITEM1 ITEM2 ...
//	    Draws an interactive vertical list. On Confirm (A/Start): prints the selected
//	    0-based index to stdout and exits 0. On Back (B): exits 10. fb/input failure: exit 20.
//
//	lodor-menu show  --title T [--body "line1\nline2"] [--tone info|good|bad|warn]
//	                 [--wait | --timeout N]
//	    Draws ONE static screen. --wait blocks for any button (Back -> exit 10, else 0).
//	    --timeout N auto-dismisses after N seconds (exit 0). With neither, it draws and
//	    exits 0 immediately, leaving the image on the framebuffer (used for a "Working..."
//	    screen that stays up exactly while the shell runs a blocking engine call).
package main

import (
	"fmt"
	"os"
	"strconv"
	"strings"
	"time"

	"lodor/onionmenu/ui"
)

const (
	exitConfirm = 0
	exitBack    = 10
	exitRender  = 20
)

func main() {
	if len(os.Args) < 2 {
		fmt.Fprintln(os.Stderr, "usage: lodor-menu {menu|show} [flags]")
		os.Exit(exitRender)
	}
	switch os.Args[1] {
	case "menu":
		runMenu(os.Args[2:])
	case "show":
		runShow(os.Args[2:])
	default:
		fmt.Fprintf(os.Stderr, "lodor-menu: unknown subcommand %q\n", os.Args[1])
		os.Exit(exitRender)
	}
}

// onionTheme tunes the shared theme for the 640x480 SSD202D panel (slightly smaller title
// than the muOS 720x480 default so long entries fit).
func onionTheme() ui.Theme {
	t := ui.DefaultTheme()
	t.TitleScale = 3
	t.BodyScale = 2
	t.SmallScale = 1
	return t
}

// flags holds the recognized flags; everything after a literal "--" (or any bare arg) is a
// positional menu item.
type flags struct {
	title, footer, status, body, tone string
	wait                                    bool
	timeout                                 int
	items                                   []string
}

func parseFlags(args []string) flags {
	f := flags{tone: "info", timeout: -1}
	i := 0
	next := func() string {
		i++
		if i < len(args) {
			return args[i]
		}
		return ""
	}
	for i < len(args) {
		switch a := args[i]; a {
		case "--title":
			f.title = next()
		case "--footer":
			f.footer = next()
		case "--status":
			f.status = next()
		case "--body":
			f.body = next()
		case "--tone":
			f.tone = next()
		case "--wait":
			f.wait = true
		case "--timeout":
			if n, err := strconv.Atoi(next()); err == nil {
				f.timeout = n
			}
		case "--":
			f.items = append(f.items, args[i+1:]...)
			return f
		default:
			f.items = append(f.items, a)
		}
		i++
	}
	return f
}

func toneColor(t ui.Theme, tone string) ui.Color {
	switch tone {
	case "good":
		return t.Good
	case "bad":
		return t.Bad
	case "warn":
		return 0xfbbf24
	default:
		return t.Text
	}
}

// openCanvas returns a canvas sized to the panel plus flush + close funcs. If the
// framebuffer cannot be opened it is a hard render failure (exit 20) -- we never pretend a
// screen appeared.
func openCanvas() (*ui.Canvas, func(), func()) {
	dev := os.Getenv("LODOR_FB")
	if dev == "" {
		dev = "/dev/fb0"
	}
	fb, err := ui.OpenFramebuffer(dev)
	if err != nil {
		fmt.Fprintf(os.Stderr, "lodor-menu: cannot open framebuffer %s: %v\n", dev, err)
		os.Exit(exitRender)
	}
	w, h := fb.Xres(), fb.Yres()
	if w < 1 || h < 1 {
		w, h = 640, 480
	}
	c := ui.NewCanvas(w, h)
	return c, func() { fb.Flush(c) }, func() { fb.Close() }
}

func bodyLines(body string) []string {
	body = strings.ReplaceAll(body, "\\n", "\n")
	return strings.Split(body, "\n")
}

// glyphLine is the pixel height of one line of text at the given scale (font is 8px tall).
func glyphLine(scale int) int { return 8 * scale }

func drawScreen(c *ui.Canvas, t ui.Theme, title, footer, status string, m *ui.Menu, body string, bodyCol ui.Color) {
	if footer == "" {
		if m != nil {
			footer = "Up/Down: move   A: select   B: back"
		} else {
			footer = "A / B: continue"
		}
	}
	x, y, w, hgt := t.Frame(c, title, footer)
	if status != "" {
		c.DrawText(x, y, status, t.Dim, t.SmallScale)
		shift := glyphLine(t.SmallScale) + 14
		y += shift
		hgt -= shift
	}
	if m != nil {
		m.Draw(c, t, x, y, w, hgt)
	}
	if body != "" {
		yy := y
		for _, ln := range bodyLines(body) {
			if ln == "" {
				yy += glyphLine(t.BodyScale) / 2
				continue
			}
			yy = t.DrawTextWrappedAt(c, x, yy, w, ln, bodyCol, t.BodyScale) + 6
		}
	}
}

func runMenu(args []string) {
	f := parseFlags(args)
	if len(f.items) == 0 {
		fmt.Fprintln(os.Stderr, "lodor-menu menu: no items")
		os.Exit(exitRender)
	}
	t := onionTheme()
	m := &ui.Menu{Items: f.items}
	c, flush, closeFb := openCanvas()
	defer closeFb()

	draw := func() { drawScreen(c, t, f.title, f.footer, f.status, m, "", t.Text); flush() }
	draw()

	src, err := ui.NewEvdevSource()
	if err != nil {
		fmt.Fprintf(os.Stderr, "lodor-menu menu: no input device: %v\n", err)
		os.Exit(exitRender)
	}
	defer src.Close()

	for b := range src.Buttons() {
		switch b {
		case ui.BtnUp, ui.BtnDown:
			m.Handle(b)
			draw()
		case ui.BtnConfirm, ui.BtnStart:
			fmt.Println(m.Selected())
			os.Exit(exitConfirm)
		case ui.BtnBack:
			os.Exit(exitBack)
		}
	}
	os.Exit(exitRender) // input channel closed unexpectedly
}

func runShow(args []string) {
	f := parseFlags(args)
	t := onionTheme()
	c, flush, closeFb := openCanvas()
	defer closeFb()
	drawScreen(c, t, f.title, f.footer, "", nil, f.body, toneColor(t, f.tone))
	flush()
	switch {
	case f.wait:
		src, err := ui.NewEvdevSource()
		if err != nil {
			// Cannot wait for input, but the screen IS drawn -> hold briefly so it is
			// readable, then return (honest: never claim a button was pressed).
			time.Sleep(4 * time.Second)
			os.Exit(exitConfirm)
		}
		defer src.Close()
		for b := range src.Buttons() {
			switch b {
			case ui.BtnConfirm, ui.BtnStart, ui.BtnSelect:
				os.Exit(exitConfirm)
			case ui.BtnBack:
				os.Exit(exitBack)
			}
		}
		os.Exit(exitConfirm)
	case f.timeout >= 0:
		time.Sleep(time.Duration(f.timeout) * time.Second)
		os.Exit(exitConfirm)
	default:
		// Draw and return immediately, leaving the image on the framebuffer.
		os.Exit(exitConfirm)
	}
}
