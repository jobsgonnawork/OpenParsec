package main

import (
	_ "embed"
	"fmt"
	"log"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"

	"fyne.io/systray"
	"golang.org/x/sys/windows"
	"golang.org/x/sys/windows/registry"
)

//go:embed icon.ico
var icon []byte

const runKey = `Software\Microsoft\Windows\CurrentVersion\Run`

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
	windows.MessageBox(0, t, c, windows.MB_OK|windows.MB_ICONINFORMATION)
}

func runUI(opts options, addrs []string, fresh bool) {
	if fresh {
		// first run: start with Windows from now on, and say what to type on the iPad
		setStartWithWindows(true)
		go showMessage(fmt.Sprintf("LaptopMouse is running next to the clock and starts with Windows.\n\n"+
			"In OpenParsec, Settings → 2nd Screen on a Laptop:\n\nAddress: %s\nPort: %d\nToken: %s",
			firstOr(addrs, "this laptop's address"), opts.Port, opts.Token))
	}

	systray.Run(func() {
		systray.SetIcon(icon)
		systray.SetTooltip("LaptopMouse, port " + fmt.Sprint(opts.Port))

		info := systray.AddMenuItem(fmt.Sprintf("Listening on port %d", opts.Port), "")
		info.Disable()
		for _, a := range addrs {
			item := systray.AddMenuItem("Address "+a, "")
			item.Disable()
		}
		token := systray.AddMenuItem("Token "+opts.Token+" (click to copy)", "")
		systray.AddSeparator()
		autostart := systray.AddMenuItemCheckbox("Start with Windows", "", startsWithWindows())
		openLog := systray.AddMenuItem("Open log", "")
		openSettings := systray.AddMenuItem("Edit settings", "Change the token, speed or wheel; restart after")
		quit := systray.AddMenuItem("Quit", "")

		go func() {
			for {
				select {
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
					systray.Quit()
				}
			}
		}()
	}, nil)
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
	k.SetStringValue("LaptopMouse", `"`+exe+`"`)
}
