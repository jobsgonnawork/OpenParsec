package main

import (
	"bufio"
	"errors"
	"fmt"
	"os"
	"strconv"
	"strings"

	"golang.org/x/sys/windows"
	"golang.org/x/term"
)

var (
	kernel32         = windows.NewLazySystemDLL("kernel32.dll")
	procAllocConsole = kernel32.NewProc("AllocConsole")
	procFreeConsole  = kernel32.NewProc("FreeConsole")
)

// signInToParsec asks for the Parsec account and the computer to show, once, in a console window
// (this is a GUI app, so it opens one), and saves the session. It returns false if cancelled.
func signInToParsec(opts *options) bool {
	procAllocConsole.Call()
	defer procFreeConsole.Call()
	in, err := os.OpenFile("CONIN$", os.O_RDWR, 0)
	if err != nil {
		return false
	}
	defer in.Close()
	out, err := os.OpenFile("CONOUT$", os.O_RDWR, 0)
	if err != nil {
		return false
	}
	defer out.Close()
	read := bufio.NewReader(in)
	ask := func(prompt string) string {
		fmt.Fprint(out, prompt)
		line, _ := read.ReadString('\n')
		return strings.TrimSpace(line)
	}

	fmt.Fprintln(out, "LaptopMouse: sign in to Parsec to show the 2nd screen here.")
	fmt.Fprintln(out, "Your password goes only to Parsec. Leave the email empty to cancel.")
	fmt.Fprintln(out)

	var session string
	for session == "" {
		email := ask("Email: ")
		if email == "" {
			return false
		}
		fmt.Fprint(out, "Password: ")
		pw, err := term.ReadPassword(int(in.Fd()))
		fmt.Fprintln(out)
		if err != nil {
			return false
		}
		session, err = signIn(email, string(pw), "")
		if errors.Is(err, errNeedTFA) {
			session, err = signIn(email, string(pw), ask("Two-factor code: "))
		}
		if err != nil {
			fmt.Fprintf(out, "%v. Try again.\n\n", err)
			session = ""
		}
	}

	hosts, err := listHosts(session)
	if err != nil || len(hosts) == 0 {
		fmt.Fprintf(out, "Couldn't list your computers: %v\n", errOr(err, "none found"))
		ask("Press Enter to close.")
		return false
	}
	fmt.Fprintln(out, "\nWhich computer?")
	for i, h := range hosts {
		state := ""
		if !h.Online {
			state = " (offline)"
		}
		fmt.Fprintf(out, "  %d. %s%s\n", i+1, h.Name, state)
	}
	pick := 1
	if len(hosts) > 1 {
		for {
			n, err := strconv.Atoi(ask("Number: "))
			if err == nil && n >= 1 && n <= len(hosts) {
				pick = n
				break
			}
		}
	}

	protected, err := protectSecret(session)
	if err != nil {
		fmt.Fprintf(out, "Couldn't store the session: %v\n", err)
		ask("Press Enter to close.")
		return false
	}
	opts.Session = protected
	opts.Peer = hosts[pick-1].PeerID
	opts.PeerName = hosts[pick-1].Name
	if err := saveOptions(*opts); err != nil {
		fmt.Fprintf(out, "Couldn't save the settings: %v\n", err)
		ask("Press Enter to close.")
		return false
	}
	return true
}

func errOr(err error, fallback string) string {
	if err != nil {
		return err.Error()
	}
	return fallback
}
