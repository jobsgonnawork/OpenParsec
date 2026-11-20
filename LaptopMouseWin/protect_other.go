//go:build !windows

package main

// only Windows keeps a Parsec session, so there is nothing to protect elsewhere

func protectSecret(plain string) (string, error)    { return plain, nil }
func unprotectSecret(stored string) (string, error) { return stored, nil }
