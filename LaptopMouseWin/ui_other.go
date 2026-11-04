//go:build !windows

package main

import "log"

// elsewhere the receiver only runs for testing, so it stays a plain console program

func setUpLog() {}

func showMessage(text string) { log.Print(text) }

func runUI(opts options, addrs []string, fresh bool) {
	log.Printf("addresses %v, token %s", addrs, opts.Token)
	select {}
}
