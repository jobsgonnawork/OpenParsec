# CursorOverlayMac

Menu bar helper for a macOS Parsec host. It draws a copy of the cursor so that other devices can see it.

## Why

Parsec doesn't send the cursor inside the video. Each client draws it locally, and a client only draws it for the guest who is moving it. So when OpenParsec on the iPad moves the cursor onto a display that another device is watching (for example a PC using **Add Screens**, with **2nd Screen → On Another Device** turned on in OpenParsec), the PC never shows it.

This helper draws the current system cursor in a borderless, click-through window above everything. Parsec captures that window into the video, so every client watching that display sees the cursor.

## Build and run

On the host Mac:

```bash
cd CursorOverlayMac
swift build -c release
.build/release/CursorOverlay
```

A cursor icon appears in the menu bar:

- **Draw Cursor** turns drawing on and off.
- **Draw on** chooses which displays get the drawn cursor. The menu bar display is off by default, because it is normally the one the iPad shows and the iPad already draws the cursor there. Your choice is remembered.
- **Quit** closes the helper.

Notes:

- The drawn cursor follows the real one with the stream's latency.
- On a display where you also use the watching device's own mouse, you will see two cursors: Parsec's local cursor and the drawn copy. Turn that display off in **Draw on** if this bothers you.
