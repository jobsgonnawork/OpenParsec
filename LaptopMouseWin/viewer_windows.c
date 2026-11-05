// See viewer.h. One thread runs the window, renders stream 1 and sends this laptop's mouse to the
// host; a second one polls Parsec events (cursor, host messages, status) and reconnects.

#define COBJMACROS
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <windowsx.h>
#include <d3d11.h>
#include <dxgi.h>
#include <stdio.h>

#include "parsec-dso.h"
#include "viewer.h"
#include "_cgo_export.h"

#define STREAM 1
#define WM_APP_CURSOR (WM_APP + 1)

static ParsecDSO *parsec;

static HWND window;
static volatile LONG running;   // window open
static volatile LONG streaming; // stream 1 rendered a frame
static volatile LONG connected;
static UINT width, height;      // client area, in physical pixels

static ID3D11Device *device;
static ID3D11DeviceContext *context;
static IDXGISwapChain *swapChain;
static ID3D11RenderTargetView *target;

// cursor from the host, swapped in on the window thread
static CRITICAL_SECTION cursorLock;
static HCURSOR pendingCursor, cursor;
static BOOL pendingHidden, hidden = TRUE;
static volatile BOOL away;

static void applyCursor(void)
{
	POINT p;
	GetCursorPos(&p);
	if (window && WindowFromPoint(p) == window)
		SetCursor(hidden || away || !cursor ? NULL : cursor);
}

static void vlog(const char *fmt, ...)
{
	char line[512];
	va_list args;
	va_start(args, fmt);
	vsnprintf(line, sizeof(line), fmt, args);
	va_end(args);
	goViewerLog(line);
}

static void parsecLog(ParsecLogLevel level, const char *msg, void *opaque)
{
	(void) opaque;
	vlog("sdk [%s] %s", level == LOG_DEBUG ? "D" : "I", msg);
}

int viewer_init(const char *dllPath)
{
	InitializeCriticalSection(&cursorLock);
	SetProcessDPIAware();

	// the same signalling server the iPad uses, the SDK's built-in default is gone
	char reserved[] = "{\"ssHost\":\"kessel-ws.parsec.app\"}";
	ParsecStatus r = ParsecInit(NULL, reserved, (char *) dllPath, &parsec);
	if (r != PARSEC_OK) {
		parsec = NULL;
		return r;
	}
	ParsecSetLogCallback(parsec, parsecLog, NULL);
	return 0;
}

/*** Direct3D ***/

static void releaseTarget(void)
{
	if (target) {
		ID3D11RenderTargetView_Release(target);
		target = NULL;
	}
}

static BOOL makeTarget(void)
{
	ID3D11Texture2D *back = NULL;
	if (FAILED(IDXGISwapChain_GetBuffer(swapChain, 0, &IID_ID3D11Texture2D, (void **) &back)))
		return FALSE;
	HRESULT hr = ID3D11Device_CreateRenderTargetView(device, (ID3D11Resource *) back, NULL, &target);
	ID3D11Texture2D_Release(back);
	return SUCCEEDED(hr);
}

static BOOL startD3D(void)
{
	DXGI_SWAP_CHAIN_DESC desc = {0};
	desc.BufferCount = 2;
	desc.BufferDesc.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
	desc.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT;
	desc.OutputWindow = window;
	desc.SampleDesc.Count = 1;
	desc.Windowed = TRUE;
	desc.SwapEffect = DXGI_SWAP_EFFECT_FLIP_DISCARD;

	D3D_FEATURE_LEVEL levels[] = {D3D_FEATURE_LEVEL_11_0};
	HRESULT hr = D3D11CreateDeviceAndSwapChain(NULL, D3D_DRIVER_TYPE_HARDWARE, NULL, 0, levels, 1,
		D3D11_SDK_VERSION, &desc, &swapChain, &device, NULL, &context);
	if (FAILED(hr)) {
		vlog("Direct3D 11 failed: 0x%08lx", hr);
		return FALSE;
	}
	return makeTarget();
}

static void stopD3D(void)
{
	releaseTarget();
	if (swapChain) IDXGISwapChain_Release(swapChain);
	if (context) ID3D11DeviceContext_Release(context);
	if (device) ID3D11Device_Release(device);
	swapChain = NULL;
	context = NULL;
	device = NULL;
}

static void resize(UINT w, UINT h)
{
	if (w == 0 || h == 0 || (w == width && h == height))
		return;
	width = w;
	height = h;
	if (swapChain) {
		releaseTarget();
		IDXGISwapChain_ResizeBuffers(swapChain, 0, w, h, DXGI_FORMAT_UNKNOWN, 0);
		makeTarget();
	}
	// mouse coordinates are sent in window pixels, the SDK maps them onto the stream
	if (connected)
		ParsecClientSetDimensions(parsec, STREAM, w, h, 1.0f);
}

// the SDK sets the viewport itself, letterboxed from ParsecClientSetDimensions
static bool preRender(void *opaque)
{
	(void) opaque;
	ID3D11DeviceContext_OMSetRenderTargets(context, 1, &target, NULL);
	return true;
}

static void render(void)
{
	float black[4] = {0, 0, 0, 1};
	ID3D11DeviceContext_OMSetRenderTargets(context, 1, &target, NULL);
	ID3D11DeviceContext_ClearRenderTargetView(context, target, black);
	if (connected) {
		ParsecStatus r = ParsecClientD3D11RenderFrame(parsec, STREAM, device, context,
			preRender, NULL, 16);
		if (r == PARSEC_OK && !streaming) {
			InterlockedExchange(&streaming, 1);
			vlog("stream 1 drawing");
		}
	} else {
		Sleep(16);
	}
	IDXGISwapChain_Present(swapChain, 0, 0);
}

/*** input from this laptop, which LaptopMouse also feeds with the iPad's mouse ***/

static void sendMessage(ParsecMessage *msg)
{
	if (connected)
		ParsecClientSendMessage(parsec, msg);
}

static void sendMotion(LPARAM lp)
{
	ParsecMessage msg = {0};
	msg.type = MESSAGE_MOUSE_MOTION;
	msg.mouseMotion.x = GET_X_LPARAM(lp);
	msg.mouseMotion.y = GET_Y_LPARAM(lp);
	msg.mouseMotion.stream = STREAM;
	sendMessage(&msg);
}

static void sendButton(ParsecMouseButton button, BOOL pressed)
{
	ParsecMessage msg = {0};
	msg.type = MESSAGE_MOUSE_BUTTON;
	msg.mouseButton.button = button;
	msg.mouseButton.pressed = pressed;
	sendMessage(&msg);
	if (pressed)
		SetCapture(window);
	else
		ReleaseCapture();
}

// Windows' wheel goes through as is, which matches how the official client scrolls a macOS host
static void sendWheel(int x, int y)
{
	ParsecMessage msg = {0};
	msg.type = MESSAGE_MOUSE_WHEEL;
	msg.mouseWheel.x = x;
	msg.mouseWheel.y = y;
	sendMessage(&msg);
}

static LRESULT CALLBACK windowProc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp)
{
	switch (msg) {
	case WM_MOUSEMOVE:
		if (away) {
			away = FALSE;
			applyCursor();
		}
		sendMotion(lp);
		return 0;
	case WM_LBUTTONDOWN: sendButton(MOUSE_L, TRUE); return 0;
	case WM_LBUTTONUP: sendButton(MOUSE_L, FALSE); return 0;
	case WM_RBUTTONDOWN: sendButton(MOUSE_R, TRUE); return 0;
	case WM_RBUTTONUP: sendButton(MOUSE_R, FALSE); return 0;
	case WM_MBUTTONDOWN: sendButton(MOUSE_MIDDLE, TRUE); return 0;
	case WM_MBUTTONUP: sendButton(MOUSE_MIDDLE, FALSE); return 0;
	case WM_XBUTTONDOWN:
	case WM_XBUTTONUP:
		sendButton(GET_XBUTTON_WPARAM(wp) == XBUTTON1 ? MOUSE_X1 : MOUSE_X2, msg == WM_XBUTTONDOWN);
		return TRUE;
	case WM_MOUSEWHEEL:
		sendWheel(0, GET_WHEEL_DELTA_WPARAM(wp));
		return 0;
	case WM_MOUSEHWHEEL:
		sendWheel(GET_WHEEL_DELTA_WPARAM(wp), 0);
		return 0;
	case WM_SETCURSOR:
		if (LOWORD(lp) == HTCLIENT) {
			SetCursor(hidden || away || !cursor ? NULL : cursor);
			return TRUE;
		}
		break;
	case WM_APP_CURSOR:
		EnterCriticalSection(&cursorLock);
		if (pendingCursor) {
			if (cursor)
				DestroyCursor(cursor);
			cursor = pendingCursor;
			pendingCursor = NULL;
		}
		hidden = pendingHidden;
		LeaveCriticalSection(&cursorLock);
		applyCursor();
		return 0;
	case WM_SIZE:
		resize(LOWORD(lp), HIWORD(lp));
		return 0;
	case WM_KEYDOWN:
		// keys stay on the iPad, except a way out of full screen
		if (wp == VK_ESCAPE && GetKeyState(VK_SHIFT) < 0)
			ShowWindow(hwnd, SW_MINIMIZE);
		return 0;
	case WM_CLOSE:
		DestroyWindow(hwnd);
		return 0;
	case WM_DESTROY:
		PostQuitMessage(0);
		return 0;
	}
	return DefWindowProcW(hwnd, msg, wp, lp);
}

static BOOL openWindow(void)
{
	HINSTANCE instance = GetModuleHandleW(NULL);
	WNDCLASSEXW wc = {0};
	wc.cbSize = sizeof(wc);
	wc.lpfnWndProc = windowProc;
	wc.hInstance = instance;
	wc.hIcon = LoadIconW(instance, MAKEINTRESOURCEW(1));
	wc.lpszClassName = L"OpenParsecScreen2";
	RegisterClassExW(&wc);

	// full screen on the monitor the laptop's cursor is on, normally its only one
	POINT p;
	GetCursorPos(&p);
	MONITORINFO mi = {sizeof(mi)};
	GetMonitorInfoW(MonitorFromPoint(p, MONITOR_DEFAULTTOPRIMARY), &mi);
	RECT r = mi.rcMonitor;

	window = CreateWindowExW(WS_EX_APPWINDOW, wc.lpszClassName, L"2nd Screen", WS_POPUP | WS_VISIBLE,
		r.left, r.top, r.right - r.left, r.bottom - r.top, NULL, NULL, instance, NULL);
	if (!window)
		return FALSE;
	width = r.right - r.left;
	height = r.bottom - r.top;
	SetForegroundWindow(window);
	return TRUE;
}

/*** Parsec connection ***/

static char session[512], peer[128];

static void startConnect(void)
{
	ParsecClientConfig cfg = PARSEC_CLIENT_DEFAULTS;
	// 0 leaves the host's resolution alone, the iPad owns stream 0
	cfg.video[0].resolutionX = 0;
	cfg.video[0].resolutionY = 0;
	cfg.video[1].resolutionX = width;
	cfg.video[1].resolutionY = height;
	cfg.mediaContainer = 0;
	cfg.protocol = 1;
	cfg.pngCursor = false;

	ParsecStatus r = ParsecClientConnect(parsec, &cfg, session, peer);
	vlog("connecting, %d", r);
}

static void onConnected(void)
{
	InterlockedExchange(&connected, 1);
	ParsecStatus on = ParsecClientEnableStream(parsec, STREAM, true);
	// stream 0 is the iPad's screen, nothing to show here
	ParsecStatus off = ParsecClientEnableStream(parsec, DEFAULT_STREAM, false);
	ParsecClientSetDimensions(parsec, STREAM, width, height, 1.0f);
	vlog("connected, stream 1 on %d, stream 0 off %d, %ux%u", on, off, width, height);
	// ask for the host's video config and display list, Go answers with stream 1's config
	ParsecClientSendUserData(parsec, 9, "");
	ParsecClientSendUserData(parsec, 10, "");
}

void viewer_send_user_data(uint32_t id, const char *msg)
{
	if (connected)
		ParsecClientSendUserData(parsec, id, msg);
}

static void onCursor(ParsecClientCursorEvent *e)
{
	HCURSOR made = NULL;
	if (e->cursor.imageUpdate && e->cursor.width > 0 && e->cursor.height > 0) {
		uint8_t *rgba = ParsecGetBuffer(parsec, e->key);
		if (rgba) {
			int w = e->cursor.width, h = e->cursor.height;
			BITMAPV5HEADER bi = {0};
			bi.bV5Size = sizeof(bi);
			bi.bV5Width = w;
			bi.bV5Height = -h;
			bi.bV5Planes = 1;
			bi.bV5BitCount = 32;
			bi.bV5Compression = BI_BITFIELDS;
			bi.bV5RedMask = 0x00FF0000;
			bi.bV5GreenMask = 0x0000FF00;
			bi.bV5BlueMask = 0x000000FF;
			bi.bV5AlphaMask = 0xFF000000;
			uint8_t *bits = NULL;
			HDC dc = GetDC(NULL);
			HBITMAP color = CreateDIBSection(dc, (BITMAPINFO *) &bi, DIB_RGB_COLORS, (void **) &bits, NULL, 0);
			ReleaseDC(NULL, dc);
			if (color && bits) {
				for (int i = 0; i < w * h; i++) {
					bits[i * 4 + 0] = rgba[i * 4 + 2];
					bits[i * 4 + 1] = rgba[i * 4 + 1];
					bits[i * 4 + 2] = rgba[i * 4 + 0];
					bits[i * 4 + 3] = rgba[i * 4 + 3];
				}
				HBITMAP mask = CreateBitmap(w, h, 1, 1, NULL);
				ICONINFO ii = {FALSE, e->cursor.hotX, e->cursor.hotY, mask, color};
				made = CreateIconIndirect(&ii);
				DeleteObject(mask);
			}
			if (color)
				DeleteObject(color);
			ParsecFree(parsec, rgba);
		}
	}

	EnterCriticalSection(&cursorLock);
	if (made) {
		if (pendingCursor)
			DestroyCursor(pendingCursor);
		pendingCursor = made;
	}
	// the host only reports the cursor to whoever moves it; on stream 0 it is on the iPad
	pendingHidden = e->cursor.hidden || e->cursor.stream != STREAM;
	LeaveCriticalSection(&cursorLock);
	PostMessage(window, WM_APP_CURSOR, 0, 0);
}

static DWORD WINAPI eventLoop(LPVOID arg)
{
	(void) arg;
	ULONGLONG retryAt = 0, nextStatus = 0;
	ParsecStatus last = PARSEC_NOT_RUNNING;

	startConnect();
	while (running) {
		ParsecClientEvent e;
		if (ParsecClientPollEvents(parsec, 100, &e)) {
			switch (e.type) {
			case CLIENT_EVENT_CURSOR:
				onCursor(&e.cursor);
				break;
			case CLIENT_EVENT_USER_DATA: {
				char *data = ParsecGetBuffer(parsec, e.userData.key);
				if (data) {
					goViewerUserData(e.userData.id, data);
					ParsecFree(parsec, data);
				}
				break;
			}
			case CLIENT_EVENT_STREAM:
				vlog("stream %u status %d", e.stream.stream, e.stream.status);
				break;
			default:
				break;
			}
		}

		ULONGLONG now = GetTickCount64();
		if (now < nextStatus)
			continue;
		nextStatus = now + 500;

		if (retryAt) {
			if (now >= retryAt) {
				retryAt = 0;
				startConnect();
			}
			continue;
		}
		ParsecStatus s = ParsecClientGetStatus(parsec, NULL);
		if (s != last) {
			vlog("status %d", s);
			goViewerStatus(s);
			last = s;
		}
		if (s == PARSEC_OK && !connected) {
			onConnected();
		} else if (s != PARSEC_OK && s != PARSEC_CONNECTING) {
			InterlockedExchange(&connected, 0);
			InterlockedExchange(&streaming, 0);
			ParsecClientDisconnect(parsec);
			retryAt = now + 3000;
		}
	}

	InterlockedExchange(&connected, 0);
	InterlockedExchange(&streaming, 0);
	ParsecClientDisconnect(parsec);
	return 0;
}

void viewer_run(const char *sessionID, const char *peerID)
{
	if (!parsec || running)
		return;
	snprintf(session, sizeof(session), "%s", sessionID);
	snprintf(peer, sizeof(peer), "%s", peerID);

	if (!openWindow())
		return;
	if (!startD3D()) {
		DestroyWindow(window);
		return;
	}
	InterlockedExchange(&running, 1);
	HANDLE events = CreateThread(NULL, 0, eventLoop, NULL, 0, NULL);

	for (;;) {
		MSG msg;
		BOOL quit = FALSE;
		while (PeekMessageW(&msg, NULL, 0, 0, PM_REMOVE)) {
			if (msg.message == WM_QUIT)
				quit = TRUE;
			TranslateMessage(&msg);
			DispatchMessageW(&msg);
		}
		if (quit)
			break;
		if (IsIconic(window))
			Sleep(50);
		else
			render();
	}

	InterlockedExchange(&running, 0);
	WaitForSingleObject(events, INFINITE);
	CloseHandle(events);
	stopD3D();
	window = NULL;
	vlog("window closed");
}

void viewer_close(void)
{
	if (window)
		PostMessage(window, WM_CLOSE, 0, 0);
}

int viewer_state(void)
{
	if (!running)
		return 0;
	return streaming ? 2 : 1;
}

void viewer_cursor_away(void)
{
	if (!window)
		return;
	away = TRUE;
	PostMessage(window, WM_APP_CURSOR, 0, 0);
}
