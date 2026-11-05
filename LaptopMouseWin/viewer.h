// The 2nd screen viewer: a borderless full screen window that shows only stream 1 of a Parsec host,
// written in C because it sits on the Parsec SDK and Direct3D 11. Go drives it through these calls.
#pragma once

#include <stdint.h>

// loads parsec.dll from dllPath; returns 0, or a ParsecStatus / loader error
int viewer_init(const char *dllPath);

// opens the window and keeps a connection to peerID open, reconnecting when it drops, until
// viewer_close; blocks, and must run on a thread of its own
void viewer_run(const char *sessionID, const char *peerID);
void viewer_close(void);

// 1 while the window is open, 2 once stream 1 is drawing
int viewer_state(void);

// a host message (JSON, null terminated) such as the video config, see ParsecUserData.swift
void viewer_send_user_data(uint32_t id, const char *msg);

// the iPad took the cursor back, so hide this one until the laptop's own mouse moves
void viewer_cursor_away(void);
