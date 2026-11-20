package main

import (
	"crypto/rand"
	"encoding/json"
	"flag"
	"os"
	"path/filepath"
)

// options live in a config file, so after the first run the receiver starts with a double click
type options struct {
	Token string  `json:"token"`
	Port  int     `json:"port"`
	Speed float64 `json:"speed"`
	Wheel float64 `json:"wheel"`

	// the 2nd screen: the Parsec session (encrypted for this Windows user), the host, and the
	// host display to show, "" for the first one the iPad isn't on
	Session  string `json:"session,omitempty"`
	Peer     string `json:"peer,omitempty"`
	PeerName string `json:"peerName,omitempty"`
	Display  string `json:"display,omitempty"`

	// started by Windows at sign in, so stay in the tray instead of opening the 2nd screen
	Autostart bool `json:"-"`
}

func configDir() string {
	dir, err := os.UserConfigDir()
	if err != nil {
		dir = "."
	}
	return filepath.Join(dir, "LaptopMouse")
}

func configPath() string { return filepath.Join(configDir(), "config.json") }

// loadOptions reads the config file, applies any flags on top and saves the result. fresh is true
// when the token was just made up, so the user still has to enter it on the iPad.
func loadOptions(args []string) (o options, fresh bool, err error) {
	o = options{Port: 26510, Speed: 1, Wheel: 1}
	if data, readErr := os.ReadFile(configPath()); readErr == nil {
		json.Unmarshal(data, &o)
	}

	fs := flag.NewFlagSet("LaptopMouse", flag.ContinueOnError)
	token := fs.String("token", "", "shared token, the same as in OpenParsec's settings (saved for next time)")
	port := fs.Int("port", 0, "UDP port to listen on (default 26510)")
	speed := fs.Float64("speed", 0, "multiplier for the iPad's moves (default 1)")
	wheel := fs.Float64("wheel", 0, "multiplier for the iPad's wheel, which already sends Windows units (default 1)")
	autostart := fs.Bool("autostart", false, "started with Windows")
	if err = fs.Parse(args); err != nil {
		return
	}
	if *token != "" {
		o.Token = *token
	}
	if *port != 0 {
		o.Port = *port
	}
	if *speed != 0 {
		o.Speed = *speed
	}
	if *wheel != 0 {
		o.Wheel = *wheel
	}
	o.Autostart = *autostart
	if len(o.Token) > 255 {
		o.Token = o.Token[:255]
	}
	if o.Token == "" {
		o.Token = newToken()
		fresh = true
	}

	err = saveOptions(o)
	return
}

func saveOptions(o options) error {
	if err := os.MkdirAll(configDir(), 0o700); err != nil {
		return err
	}
	data, _ := json.MarshalIndent(o, "", "  ")
	return os.WriteFile(configPath(), data, 0o600)
}

// short and easy to type on the iPad, without look-alike characters
func newToken() string {
	const letters = "abcdefghjkmnpqrstuvwxyz23456789"
	b := make([]byte, 8)
	rand.Read(b)
	for i := range b {
		b[i] = letters[int(b[i])%len(letters)]
	}
	return string(b)
}
