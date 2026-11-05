//go:build !windows

package main

import "log"

// elsewhere the receiver only runs for testing, so it stays a plain console program, without the
// 2nd screen

func setUpLog() {}

func showMessage(text string) { log.Print(text) }

type app struct{ opts *options }

func newApp(opts *options, s *session) *app { return &app{opts: opts} }

func (a *app) openRequested() { log.Print("asked to open the 2nd screen") }

func (a *app) run(addrs []string, fresh bool) {
	log.Printf("addresses %v, token %s", addrs, a.opts.Token)
	select {}
}
