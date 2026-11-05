package main

import (
	_ "embed"
	"fmt"
	"log"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"syscall"
	"time"

	"fyne.io/systray"
	"golang.org/x/sys/windows"
	"golang.org/x/sys/windows/registry"
)

//go:embed icon.ico
var icon []byte

const runKey = `Software\Microsoft\Windows\CurrentVersion\Run`

// Parsec status: the session is no longer valid
const wsErrAuth = -3008

func logPath() string { return filepath.Join(configDir(), "laptopmouse.log") }

// built as a GUI app with no console, so the log goes to a file the tray menu opens
func setUpLog() {
	if f, err := os.OpenFile(logPath(), os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0o600); err == nil {
		log.SetOutput(f)
	}
}

func showMessage(text string) {
	t, _ := windows.UTF16PtrFromString(text)
	c, _ := windows.UTF16PtrFromString("LaptopMouse")
	windows.MessageBox(0, t, c, windows.MB_OK|windows.MB_ICONINFORMATION|windows.MB_SETFOREGROUND)
}

type app struct {
	mu      sync.Mutex
	opts    *options
	mouse   *session
	signing bool
}

func newApp(opts *options, s *session) *app {
	a := &app{opts: opts, mouse: s}
	// the iPad's cursor coming over opens the 2nd screen, once signed in
	s.onIn = func() {
		if a.signedIn() && !screen.isOpen() {
			go a.openScreen()
		}
	}
	s.onOut = screen.cursorAway
	screen.onState = func(status int32) {
		if status == wsErrAuth {
			log.Printf("[screen] Parsec signed this laptop out")
			screen.close()
			a.mu.Lock()
			a.opts.Session = ""
			saveOptions(*a.opts)
			a.mu.Unlock()
			go showMessage("Parsec signed this laptop out. Open the 2nd screen from the tray to sign in again.")
		}
	}
	return a
}

func (a *app) signedIn() bool {
	a.mu.Lock()
	defer a.mu.Unlock()
	return a.opts.Session != "" && a.opts.Peer != ""
}

// openScreen shows the 2nd screen, signing in to Parsec first if needed
func (a *app) openScreen() {
	if !a.signedIn() && !a.signIn() {
		return
	}
	a.mu.Lock()
	stored, peer, display := a.opts.Session, a.opts.Peer, a.opts.Display
	a.mu.Unlock()
	session, err := unprotectSecret(stored)
	if err != nil || session == "" {
		log.Printf("[screen] stored session unreadable: %v", err)
		if !a.signIn() {
			return
		}
		a.openScreen()
		return
	}
	w, h := a.mouse.m.screen()
	screen.open(session, peer, display, w, h)
}

func (a *app) signIn() bool {
	a.mu.Lock()
	if a.signing {
		a.mu.Unlock()
		return false
	}
	a.signing = true
	opts := *a.opts
	a.mu.Unlock()

	ok := signInToParsec(&opts)

	a.mu.Lock()
	a.signing = false
	if ok {
		*a.opts = opts
	}
	a.mu.Unlock()
	return ok
}

func (a *app) openRequested() { go a.openScreen() }

func (a *app) run(addrs []string, fresh bool) {
	opts := a.opts
	if fresh {
		// first run: start with Windows from now on, and say what to type on the iPad
		setStartWithWindows(true)
		go showMessage(fmt.Sprintf("LaptopMouse is running next to the clock and starts with Windows.\n\n"+
			"In OpenParsec, Settings → 2nd Screen on a Laptop:\n\nAddress: %s\nPort: %d\nToken: %s",
			firstOr(addrs, "this laptop's address"), opts.Port, opts.Token))
	} else if startsWithWindows() {
		// keep the entry pointing at this copy, started in the tray
		setStartWithWindows(true)
	}
	if !opts.Autostart {
		go a.openScreen()
	}

	systray.Run(func() {
		systray.SetIcon(icon)
		systray.SetTooltip("LaptopMouse")

		state := systray.AddMenuItem("2nd screen: off", "")
		state.Disable()
		open := systray.AddMenuItem("Open 2nd screen", "")
		closeScreen := systray.AddMenuItem("Close 2nd screen", "")
		displayMenu := systray.AddMenuItem("Display to show", "Listed once the 2nd screen connects")
		a.watchDisplays(displayMenu)
		account := systray.AddMenuItem("Sign in or change computer…", "")
		systray.AddSeparator()
		info := systray.AddMenuItem(fmt.Sprintf("Listening on port %d", opts.Port), "")
		info.Disable()
		for _, addr := range addrs {
			item := systray.AddMenuItem("Address "+addr, "")
			item.Disable()
		}
		token := systray.AddMenuItem("Token "+opts.Token+" (click to copy)", "")
		systray.AddSeparator()
		autostart := systray.AddMenuItemCheckbox("Start with Windows", "", startsWithWindows())
		openLog := systray.AddMenuItem("Open log", "")
		openSettings := systray.AddMenuItem("Edit settings", "Change the token, speed or wheel; restart after")
		quit := systray.AddMenuItem("Quit", "")

		go func() {
			for range time.Tick(time.Second) {
				a.mu.Lock()
				name := a.opts.PeerName
				a.mu.Unlock()
				switch screenState() {
				case 0:
					state.SetTitle("2nd screen: off")
				case 1:
					state.SetTitle("2nd screen: connecting to " + name)
				default:
					state.SetTitle("2nd screen: showing " + name)
				}
			}
		}()

		go func() {
			for {
				select {
				case <-open.ClickedCh:
					go a.openScreen()
				case <-closeScreen.ClickedCh:
					screen.close()
				case <-account.ClickedCh:
					go func() {
						screen.close()
						if a.signIn() {
							a.openScreen()
						}
					}()
				case <-token.ClickedCh:
					run("clip", opts.Token)
				case <-autostart.ClickedCh:
					on := !autostart.Checked()
					setStartWithWindows(on)
					if on {
						autostart.Check()
					} else {
						autostart.Uncheck()
					}
				case <-openLog.ClickedCh:
					run("notepad", "", logPath())
				case <-openSettings.ClickedCh:
					run("notepad", "", configPath())
				case <-quit.ClickedCh:
					screen.close()
					systray.Quit()
				}
			}
		}()
	}, nil)
}

// watchDisplays lists the host's displays under menu once known, so one can be picked for the 2nd
// screen; the pick is saved and applied straight away
func (a *app) watchDisplays(menu *systray.MenuItem) {
	var mu sync.Mutex
	items := map[string]*systray.MenuItem{}
	screen.onDisplays = func() {
		mu.Lock()
		defer mu.Unlock()
		displays, shown, ipad := screen.cfg.state()
		names := map[string]int{}
		for _, d := range displays {
			names[d.Name]++
		}
		for _, d := range displays {
			title := d.Name
			if names[d.Name] > 1 || title == "" {
				title += " (" + d.ID + ")"
			}
			if d.ID == ipad {
				title += " - on the iPad"
			}
			item := items[d.ID]
			if item == nil {
				item = menu.AddSubMenuItemCheckbox(title, "", false)
				items[d.ID] = item
				id := d.ID
				go func() {
					for range item.ClickedCh {
						a.chooseDisplay(id)
					}
				}()
			} else {
				item.SetTitle(title)
			}
			if d.ID == shown {
				item.Check()
			} else {
				item.Uncheck()
			}
		}
	}
}

func (a *app) chooseDisplay(id string) {
	a.mu.Lock()
	a.opts.Display = id
	saveOptions(*a.opts)
	a.mu.Unlock()
	log.Printf("[screen] showing display %s", id)
	screen.show(id)
	screen.onDisplays()
}

func screenState() int {
	if !screen.isOpen() {
		return 0
	}
	if screen.isShowing() {
		return 2
	}
	return 1
}

func firstOr(list []string, fallback string) string {
	if len(list) == 0 {
		return fallback
	}
	return strings.TrimSuffix(list[0], " (Tailscale)")
}

// runs a helper without flashing a console window
func run(name, stdin string, args ...string) {
	cmd := exec.Command(name, args...)
	cmd.SysProcAttr = &syscall.SysProcAttr{HideWindow: true, CreationFlags: windows.CREATE_NO_WINDOW}
	if stdin != "" {
		cmd.Stdin = strings.NewReader(stdin)
	}
	if err := cmd.Start(); err != nil {
		log.Printf("%s: %v", name, err)
		return
	}
	go cmd.Wait()
}

func startsWithWindows() bool {
	k, err := registry.OpenKey(registry.CURRENT_USER, runKey, registry.QUERY_VALUE)
	if err != nil {
		return false
	}
	defer k.Close()
	_, _, err = k.GetStringValue("LaptopMouse")
	return err == nil
}

// per user, so it needs no admin rights
func setStartWithWindows(on bool) {
	k, err := registry.OpenKey(registry.CURRENT_USER, runKey, registry.SET_VALUE)
	if err != nil {
		log.Printf("start with Windows: %v", err)
		return
	}
	defer k.Close()
	if !on {
		k.DeleteValue("LaptopMouse")
		return
	}
	exe, err := os.Executable()
	if err != nil {
		log.Printf("start with Windows: %v", err)
		return
	}
	k.SetStringValue("LaptopMouse", `"`+exe+`" -autostart`)
}
