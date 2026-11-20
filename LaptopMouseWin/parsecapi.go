package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"time"
)

// The Parsec web API, the same calls OpenParsec makes on the iPad (LoginView.swift, MainView.swift)
var parsecAPI = "https://kessel-api.parsec.app"

var errNeedTFA = errors.New("two-factor code needed")

var apiClient = &http.Client{Timeout: 20 * time.Second}

type parsecHost struct {
	PeerID string `json:"peer_id"`
	Name   string `json:"name"`
	Online bool   `json:"online"`
}

func apiRequest(method, path, session string, body any) (*http.Response, []byte, error) {
	var reader io.Reader
	if body != nil {
		data, err := json.Marshal(body)
		if err != nil {
			return nil, nil, err
		}
		reader = bytes.NewReader(data)
	}
	req, err := http.NewRequest(method, parsecAPI+path, reader)
	if err != nil {
		return nil, nil, err
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("User-Agent", "parsec/150-93b Windows/11 libmatoya/4.0")
	if session != "" {
		req.Header.Set("Authorization", "Bearer "+session)
	}
	resp, err := apiClient.Do(req)
	if err != nil {
		return nil, nil, err
	}
	defer resp.Body.Close()
	data, err := io.ReadAll(resp.Body)
	return resp, data, err
}

// signIn returns a session id, or errNeedTFA when the account asks for a two-factor code
func signIn(email, password, tfa string) (string, error) {
	resp, data, err := apiRequest("POST", "/v1/auth", "", map[string]string{
		"email": email, "password": password, "tfa": tfa,
	})
	if err != nil {
		return "", err
	}
	if resp.StatusCode == http.StatusCreated {
		var info struct {
			SessionID string `json:"session_id"`
		}
		if err := json.Unmarshal(data, &info); err != nil || info.SessionID == "" {
			return "", fmt.Errorf("unexpected answer from Parsec")
		}
		return info.SessionID, nil
	}
	var failure struct {
		Error       string `json:"error"`
		TFARequired bool   `json:"tfa_required"`
	}
	json.Unmarshal(data, &failure)
	if failure.TFARequired {
		return "", errNeedTFA
	}
	if failure.Error != "" {
		return "", errors.New(failure.Error)
	}
	return "", fmt.Errorf("sign in failed (HTTP %d)", resp.StatusCode)
}

func listHosts(session string) ([]parsecHost, error) {
	resp, data, err := apiRequest("GET", "/v2/hosts?mode=desktop&public=false", session, nil)
	if err != nil {
		return nil, err
	}
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("listing computers failed (HTTP %d)", resp.StatusCode)
	}
	var list struct {
		Data []parsecHost `json:"data"`
	}
	if err := json.Unmarshal(data, &list); err != nil {
		return nil, err
	}
	return list.Data, nil
}
