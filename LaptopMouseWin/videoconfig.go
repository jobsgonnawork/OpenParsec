package main

import (
	"encoding/json"
	"log"
	"sync"
	"time"
)

// Host messages, as in OpenParsec's ParsecUserData.swift: 9 and 10 ask for the video config (answered
// with 11) and the display list (answered with 12), and 11 sets the video config.
const (
	userDataGetVideoConfig = 9
	userDataGetDisplays    = 10
	userDataSetVideoConfig = 11
	userDataDisplays       = 12
)

type hostDisplay struct {
	Name        string `json:"name"`
	AdapterName string `json:"adapterName"`
	ID          string `json:"id"`
}

// videoConfigState points stream 1 at the host's 2nd display, sized for this laptop. Everything
// else in the host's config is sent back as it came, so the iPad's stream 0 stays as it is.
type videoConfigState struct {
	mu       sync.Mutex
	display  string // display id from the settings, or "" for the first one stream 0 isn't on
	width    int
	height   int
	displays []hostDisplay
	config   map[string]any
	sent     int
	lastSent time.Time
}

func (s *videoConfigState) reset(display string, width, height int) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.display, s.width, s.height = display, width, height
	s.displays, s.config, s.sent, s.lastSent = nil, nil, 0, time.Time{}
}

// handle takes a host message and returns the video config to send, if stream 1 needs one
func (s *videoConfigState) handle(id uint32, msg string) (string, bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	switch id {
	case userDataDisplays:
		var displays []hostDisplay
		if err := json.Unmarshal([]byte(msg), &displays); err != nil {
			log.Printf("[screen] display list: %v", err)
			return "", false
		}
		s.displays = displays
		log.Printf("[screen] host displays: %+v", displays)
	case userDataSetVideoConfig:
		var config map[string]any
		if err := json.Unmarshal([]byte(msg), &config); err != nil {
			log.Printf("[screen] video config: %v", err)
			return "", false
		}
		s.config = config
		log.Printf("[screen] host video config: %s", msg)
	default:
		return "", false
	}
	return s.reply(time.Now())
}

func (s *videoConfigState) reply(now time.Time) (string, bool) {
	if s.config == nil || s.displays == nil {
		return "", false
	}
	video, _ := s.config["video"].([]any)
	if len(video) < 2 {
		return "", false
	}
	v0, ok0 := video[0].(map[string]any)
	v1, ok1 := video[1].(map[string]any)
	if !ok0 || !ok1 {
		return "", false
	}

	output := s.pickDisplay(str(v0["output"]))
	if output == "" {
		log.Printf("[screen] no 2nd display on the host")
		return "", false
	}
	want := map[string]any{
		"output":            output,
		"resolutionX":       s.width,
		"resolutionY":       s.height,
		"encoderMaxBitrate": v0["encoderMaxBitrate"],
		"encoderFPS":        v0["encoderFPS"],
		"fullFPS":           v0["fullFPS"],
	}
	if matches(v1, want) {
		return "", false
	}
	// the host echoes the config back, so give up rather than loop if it keeps refusing
	if s.sent >= 5 || now.Sub(s.lastSent) < 2*time.Second {
		return "", false
	}
	for k, v := range want {
		v1[k] = v
	}
	data, err := json.Marshal(s.config)
	if err != nil {
		return "", false
	}
	s.sent++
	s.lastSent = now
	return string(data), true
}

func (s *videoConfigState) pickDisplay(stream0 string) string {
	if s.display != "" {
		return s.display
	}
	for _, d := range s.displays {
		if d.ID != stream0 {
			return d.ID
		}
	}
	return ""
}

func matches(have, want map[string]any) bool {
	for k, v := range want {
		if !sameValue(have[k], v) {
			return false
		}
	}
	return true
}

// JSON numbers decode as float64, so compare through it
func sameValue(a, b any) bool {
	fa, aNum := number(a)
	fb, bNum := number(b)
	if aNum && bNum {
		return fa == fb
	}
	return a == b
}

func number(v any) (float64, bool) {
	switch n := v.(type) {
	case float64:
		return n, true
	case int:
		return float64(n), true
	}
	return 0, false
}

func str(v any) string {
	s, _ := v.(string)
	return s
}
