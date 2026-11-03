import ParsecSDK
import MetalKit
import UIKit
import os

let sdkLog = OSLog(subsystem: "com.aigch.OpenParsec", category: "sdk")
let appLog = OSLog(subsystem: "com.aigch.OpenParsec", category: "app")

final class ConnectionLog: ObservableObject {
	static let shared = ConnectionLog()

	private struct Entry {
		var time: String
		let text: String
		var count: Int
	}

	@Published private(set) var lines: [String] = []
	private var entries: [Entry] = []
	// [stream1...] and [external] lines kept apart so sdk chatter can't push them out before they are copied
	private(set) var probeLines: [String] = []
	private let lock = NSLock()
	private var pending: [(time: String, text: String)] = []
	private var flushScheduled = false
	private let clock: DateFormatter = {
		let f = DateFormatter()
		f.dateFormat = "HH:mm:ss.S"
		return f
	}()

	func add(_ text: String) {
		let time = clock.string(from: Date())
		lock.lock()
		pending.append((time, text))
		let schedule = !flushScheduled
		flushScheduled = true
		lock.unlock()
		if schedule {
			DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { self.flush() }
		}
	}

	private func flush() {
		lock.lock()
		let fresh = pending
		pending.removeAll()
		flushScheduled = false
		lock.unlock()
		for item in fresh {
			if item.text.hasPrefix("[stream1") || item.text.hasPrefix("[external]") {
				probeLines.append("\(item.time) \(item.text)")
			}
			if let last = entries.indices.last, entries[last].text == item.text {
				entries[last].count += 1
				entries[last].time = item.time
			} else {
				entries.append(Entry(time: item.time, text: item.text, count: 1))
			}
		}
		if entries.count > 200 {
			entries.removeFirst(entries.count - 200)
		}
		if probeLines.count > 1000 {
			probeLines.removeFirst(probeLines.count - 1000)
		}
		lines = entries.map { "\($0.time) \($0.text)\($0.count > 1 ? " x\($0.count)" : "")" }
	}

	// main thread only, like lines
	func probeReport() -> String {
		let recent = lines.suffix(60)
		return (probeLines + ["--- recent log ---"] + recent).joined(separator: "\n")
	}
}

func appNote(_ text: String) {
	os_log("%{public}@", log: appLog, text)
	ConnectionLog.shared.add(text)
}

enum RendererType: Int {
	case opengl
    case metal
}

enum DecoderPref: Int {
    case h264
    case h265
}

enum CursorMode: Int {
    case touchpad
    case direct
}

enum RightClickPosition: Int {
	case firstFinger
	case middle
	case secondFinger
}

enum MenuSwipeEdge: Int {
	case left
	case right
	case off
}

struct KeyBoardKeyEvent {
	var input: UIKey?
	var isPressBegin: Bool
}

// counts what the 2nd stream probe gets back; only touched from the probe thread,
// the frame callback runs inside ParsecClientPollFrame on that same thread
private final class Stream1ProbeStats {
	let startedAt = CACurrentMediaTime()
	var lastReportAt = CACurrentMediaTime()
	var frames = 0
	var totalFrames = 0
	var polls = 0
	var statusCounts: [Int32: Int] = [:]
	var lastFrame: ParsecFrame?

	func record(_ frame: ParsecFrame) {
		if totalFrames == 0 {
			let ms = Int((CACurrentMediaTime() - startedAt) * 1000)
			appNote("[stream1-probe] first frame after \(ms) ms, \(frame.width)x\(frame.height) full \(frame.fullWidth)x\(frame.fullHeight) format \(frame.format.rawValue) size \(frame.size)")
		}
		frames += 1
		totalFrames += 1
		lastFrame = frame
	}
}

private let stream1ProbeCallback: ParsecFrameCallback = { frame, _, opaque in
	guard let frame = frame, let opaque = opaque else { return }
	Unmanaged<Stream1ProbeStats>.fromOpaque(opaque).takeUnretainedValue().record(frame.pointee)
}

class ParsecSDKBridge: ParsecService {
	var hostWidth: Float = 1920

	var hostHeight: Float = 1080

	static let PARSEC_VER: UInt32 = UInt32((PARSEC_VER_MAJOR << 16) | PARSEC_VER_MINOR)

	private var _parsec: OpaquePointer!
	private var _audio: OpaquePointer!
	private let _audioPtr: UnsafeRawPointer

	private var isVirtualShiftOn = false

	public var clientWidth: Float = 1920
	public var clientHeight: Float = 1080
	private var hasFrame = false

	public var netProtocol: Int32 = 1
	public var mediaContainer: Int32 = 0
	public var pngCursor: Bool = false
	private let generationLock = NSLock()
	private var currentGeneration = 0
	private var pollGeneration: Int {
		get {
			generationLock.lock()
			defer { generationLock.unlock() }
			return currentGeneration
		}
		set {
			generationLock.lock()
			currentGeneration = newValue
			generationLock.unlock()
		}
	}
	// 0 while the 2nd stream probe is off, otherwise the token of the running probe loop
	private var currentProbeToken = 0
	private var probeToken: Int {
		get {
			generationLock.lock()
			defer { generationLock.unlock() }
			return currentProbeToken
		}
		set {
			generationLock.lock()
			currentProbeToken = newValue
			generationLock.unlock()
		}
	}
	private var probeCounter = 0
	// true while the external display renderer polls stream 1, the probe loop must not take its frames
	private var currentStream1Drawn = false
	var stream1Drawn: Bool {
		get {
			generationLock.lock()
			defer { generationLock.unlock() }
			return currentStream1Drawn
		}
		set {
			generationLock.lock()
			currentStream1Drawn = newValue
			generationLock.unlock()
		}
	}
	private var lastCursorStream: UInt8 = 0
	private var clientScale: Float = 1
	var didSetResolution = false
	private var didReleaseOnConnect = false
	private var capsLock = false

	public var mouseInfo = MouseInfo()

	init() {
		os_log("%{public}@", log: sdkLog, "Parsec SDK Version: " + String(ParsecSDKBridge.PARSEC_VER))
		let runtimeVer = ParsecVersion()
		os_log("%{public}@", log: sdkLog, "Parsec SDK binary: \(runtimeVer >> 16).\(runtimeVer & 0xFFFF)")

		ParsecSetLogCallback(
			{ (level, msg, _) in
				let line = "[\(level == LOG_DEBUG ? "D" : "I")] \(String(cString: msg!))"
				os_log("%{public}@", log: sdkLog, type: level == LOG_DEBUG ? .info : .default, line)
				ConnectionLog.shared.add("sdk \(line)")
				if line.contains("signal_") && line.contains("] = -") {
					let at = Date()
					DispatchQueue.main.async { CParsec.setupError = (line, at) }
				}
			}, nil)

		audio_init(&_audio)

		self._audioPtr = UnsafeRawPointer(_audio)

		do {
			let reservedCfg = ["ssHost": "kessel-ws.parsec.app"]
			let json = JSONEncoder()
			var jsonData = try json.encode(reservedCfg)
			jsonData.append(0)
			jsonData.withUnsafeBytes { (jsonStrBPtr: UnsafeRawBufferPointer) in
				guard let jsonStrPtr = jsonStrBPtr.baseAddress else {
					return
				}
				ParsecInit(ParsecSDKBridge.PARSEC_VER, nil, jsonStrPtr, &_parsec)
			}

		} catch {
			print("error: \(error)")
		}

	}

	deinit {
		ParsecDestroy(_parsec)
		audio_destroy(&_audio)
	}

	func connect(_ peerID: String) -> ParsecStatus {

		var parsecClientCfg = ParsecClientConfig()
		parsecClientCfg.video.0.decoderIndex = 1
        // Use saved resolution from SettingsHandler
		parsecClientCfg.video.0.resolutionX = Int32(SettingsHandler.resolution.width)
		parsecClientCfg.video.0.resolutionY = Int32(SettingsHandler.resolution.height)
		parsecClientCfg.video.0.decoderH265 = SettingsHandler.decoder == .h265

		parsecClientCfg.video.1.decoderIndex = 1
		parsecClientCfg.video.1.resolutionX = Int32(SettingsHandler.resolution.width)
		parsecClientCfg.video.1.resolutionY = Int32(SettingsHandler.resolution.height)
		parsecClientCfg.video.1.decoderH265 = SettingsHandler.decoder == .h265

		parsecClientCfg.mediaContainer = 0
		parsecClientCfg.protocol = 1
		// parsecClientCfg.secret = ""
		parsecClientCfg.pngCursor = false

		self.startBackgroundTask()
		didReleaseOnConnect = false

		let status = ParsecClientConnect(_parsec, &parsecClientCfg, NetworkHandler.clinfo?.session_id, peerID)

		if status == PARSEC_OK || status == PARSEC_CONNECTING {
			ParsecBackgroundManager.shared.connectionDidStart()
		}

		return status
	}

	func disconnect() {

		pollGeneration += 1
		endStream1Probe(reason: "disconnect")
		// must go before the disconnect, after it the release never reaches the host
		sendReleaseMessage()
		ParsecClientDisconnect(_parsec)
		audio_clear(&_audio)

		ParsecBackgroundManager.shared.connectionDidEnd()
	}

	func reconnect(_ peerID: String) -> ParsecStatus {
		sendReleaseMessage()
		pollGeneration += 1
		endStream1Probe(reason: "reconnect")
		didSetResolution = false
		ParsecClientDisconnect(_parsec)
		audio_clear(&_audio)
		ParsecBackgroundManager.shared.connectionDidEnd()
		let status = connect(peerID)
		if status != PARSEC_OK && status != PARSEC_CONNECTING {
			ParsecBackgroundManager.shared.connectionDidEnd()
		}
		return status
	}

	func sendReleaseMessage() {
		var msg = ParsecMessage()
		msg.type = MESSAGE_RELEASE
		ParsecClientSendMessage(_parsec, &msg)
		isVirtualShiftOn = false
		DispatchQueue.main.async {
			NotificationCenter.default.post(name: NSNotification.Name("ParsecInputReleased"), object: nil)
		}
	}

	@discardableResult
	func pause(video: Bool = true, audio: Bool = true) -> ParsecStatus {
		let status = ParsecClientPause(_parsec, video, audio)
		if audio {
			audio_hold(true, _audioPtr)
		}
		return status
	}

	@discardableResult
	func resume() -> ParsecStatus {
		audio_hold(false, _audioPtr)
		return ParsecClientPause(_parsec, false, false)
	}

	func getStatus() -> ParsecStatus {

		return ParsecClientGetStatus(_parsec, nil)
	}

	func getStatusEx(_ pcs: inout ParsecClientStatus) -> ParsecStatus {
		let ans = ParsecClientGetStatus(_parsec, &pcs)
		if pcs.decoder.0.width > 0 && pcs.decoder.0.height > 0 {
			self.hostHeight = Float(pcs.decoder.0.height)
			self.hostWidth = Float(pcs.decoder.0.width)
		}

		// the teardown release may not have made it out, this one goes over a socket we know is live
		if ans == PARSEC_OK && !didReleaseOnConnect {
			didReleaseOnConnect = true
			sendReleaseMessage()
		}

		return ans
	}

	func setFrame(_ width: CGFloat, _ height: CGFloat, _ scale: CGFloat) {

		ParsecClientSetDimensions(_parsec, UInt8(DEFAULT_STREAM), UInt32(width), UInt32(height), Float(scale))
		clientScale = Float(scale)
		if probeToken != 0 && !stream1Drawn {
			ParsecClientSetDimensions(_parsec, 1, UInt32(width), UInt32(height), Float(scale))
		}

		let oldSize = CGSize(width: CGFloat(clientWidth), height: CGFloat(clientHeight))
		clientWidth = Float(width)
		clientHeight = Float(height)
		guard hasFrame, oldSize.width > 0, oldSize.height > 0 else {
			hasFrame = true
			mouseInfo.mouseX = Int32(width / 2)
			mouseInfo.mouseY = Int32(height / 2)
			return
		}
		let moved = carryCursor(CGPoint(x: CGFloat(mouseInfo.mouseX), y: CGFloat(mouseInfo.mouseY)), from: oldSize, to: CGSize(width: width, height: height))
		mouseInfo.mouseX = Int32(moved.x.rounded())
		mouseInfo.mouseY = Int32(moved.y.rounded())
	}

	private func carryCursor(_ point: CGPoint, from old: CGSize, to new: CGSize) -> CGPoint {
		let host = CGSize(width: CGFloat(hostWidth), height: CGFloat(hostHeight))
		guard host.width > 0, host.height > 0 else {
			return CGPoint(x: point.x * new.width / old.width, y: point.y * new.height / old.height)
		}
		let oldScale = min(old.width / host.width, old.height / host.height)
		let newScale = min(new.width / host.width, new.height / host.height)
		let hostX = (point.x - (old.width - host.width * oldScale) / 2) / oldScale
		let hostY = (point.y - (old.height - host.height * oldScale) / 2) / oldScale
		let x = hostX * newScale + (new.width - host.width * newScale) / 2
		let y = hostY * newScale + (new.height - host.height * newScale) / 2
		return CGPoint(x: min(max(x, 0), new.width), y: min(max(y, 0), new.height))
	}

	// timeout in ms, 16 == 60 FPS, 8 == 120 FPS, etc.
	func renderGLFrame(timeout: UInt32 = 16) {

		ParsecClientGLRenderFrame(_parsec, UInt8(DEFAULT_STREAM), nil, nil, timeout)
	}

	func glDestroy() {
		ParsecClientGLDestroy(_parsec, UInt8(DEFAULT_STREAM))
	}

	func pollFrame(stream: UInt8, timeout: UInt32, callback: ParsecFrameCallback, opaque: UnsafeRawPointer) -> ParsecStatus {
		ParsecClientPollFrame(_parsec, stream, callback, timeout, opaque)
	}

	// stream 0 goes through setFrame, which also tracks the client size for touch and cursor mapping
	func setStreamDimensions(stream: UInt8, _ width: CGFloat, _ height: CGFloat, _ scale: CGFloat) {
		ParsecClientSetDimensions(_parsec, stream, UInt32(width), UInt32(height), Float(scale))
	}

	@discardableResult
	func pollAudio(timeout: UInt32 = 16) -> ParsecStatus { // timeout in ms, 16 == 60 FPS, 8 == 120 FPS, etc.
		return ParsecClientPollAudio(_parsec, audio_cb, timeout, _audioPtr)
	}

	var mousePositionRelative = false

	@discardableResult
	func pollEvent(timeout: UInt32 = 16, sawCursor: inout Bool) -> Bool { // timeout in ms, 16 == 60 FPS, 8 == 120 FPS, etc.
		var e: ParsecClientEvent!
		var _event = ParsecClientEvent()
		var pollSuccess = false
		withUnsafeMutablePointer(to: &_event, {(_eventPtr) in
			pollSuccess = ParsecClientPollEvents(_parsec, timeout, _eventPtr)
			e = _eventPtr.pointee
		})
		if !pollSuccess {
			return ParsecClientGetStatus(_parsec, nil) != PARSEC_OK
		}
		if e.type == CLIENT_EVENT_CURSOR {
			handleCursorEvent(event: e.cursor, sawCursor: &sawCursor)
		} else if e.type == CLIENT_EVENT_USER_DATA {
			handleUserDataEvent(event: e.userData)
		} else if e.type == CLIENT_EVENT_STREAM {
			os_log("%{public}@", log: sdkLog, "[stream] s=\(e.stream.stream) status=\(e.stream.status.rawValue)")
			if probeToken != 0 || e.stream.stream != UInt8(DEFAULT_STREAM) {
				appNote("[stream1-probe] stream event s=\(e.stream.stream) status=\(e.stream.status.rawValue)")
			}
		} else if e.type == CLIENT_EVENT_BLOCKED {
			DispatchQueue.main.async { DataManager.model.isBlocked = true }
		} else if e.type == CLIENT_EVENT_UNBLOCKED {
			DispatchQueue.main.async { DataManager.model.isBlocked = false }
		}
		return false
	}

	func handleUserDataEvent(event: ParsecClientUserDataEvent) {

		let pointer = ParsecGetBuffer(_parsec, event.key)
		if pointer == nil {
			return
		}
		switch event.id {
		case 11:
			do {
				let decoder = JSONDecoder()
				let config = try decoder.decode(ParsecUserDataVideoConfig.self, from: Data(bytesNoCopy: pointer!, count: strlen(pointer!), deallocator: .none))
				let videoConfig = config.video.first
				if probeToken != 0 {
					let echo = config.video.enumerated().map { "v\($0.offset) \($0.element.resolutionX)x\($0.element.resolutionY) out=\($0.element.output) br=\($0.element.encoderMaxBitrate) full=\($0.element.fullFPS)" }
					appNote("[stream1-probe] host video config: \(echo.joined(separator: " | "))")
				}
				DispatchQueue.main.async {
					if let cfg = videoConfig {
						DataManager.model.resolutionX = cfg.resolutionX
						DataManager.model.resolutionY = cfg.resolutionY
						DataManager.model.bitrate = cfg.encoderMaxBitrate
						DataManager.model.constantFps = cfg.fullFPS
					}
					if !self.didSetResolution {
						self.didSetResolution = true
						if DataManager.model.hostDefaultBitrate == 0 {
							DataManager.model.hostDefaultBitrate = DataManager.model.bitrate
						}
						DataManager.model.resolutionX = SettingsHandler.resolution.width
						DataManager.model.resolutionY = SettingsHandler.resolution.height
						DataManager.model.constantFps = SettingsHandler.constantFps
						if SettingsHandler.bitrate > 0 {
							DataManager.model.bitrate = SettingsHandler.bitrate
						}
						self.updateHostVideoConfig()
					}
				}

			} catch {
				print("error while parsing user data: \(error.localizedDescription)")
			}
		case 12:
			do {
				let decoder = JSONDecoder()
				let config = try decoder.decode(Array<ParsecDisplayConfig>.self, from: Data(bytesNoCopy: pointer!, count: strlen(pointer!), deallocator: .none))
				DispatchQueue.main.async {
					DataManager.model.displayConfigs = config
				}
			} catch {
				print("error while parsing user data: \(error.localizedDescription)")
			}
		default:
			break
		}

		ParsecFree(pointer)

	}

	func handleCursorEvent(event: ParsecClientCursorEvent, sawCursor: inout Bool) {
		if event.cursor.stream != lastCursorStream {
			appNote("[stream1-probe] cursor.stream \(lastCursorStream) -> \(event.cursor.stream)")
			lastCursorStream = event.cursor.stream
		}
		let prevHidden = mouseInfo.cursorHidden
		mouseInfo.cursorHidden = event.cursor.hidden
		mouseInfo.mousePositionRelative = event.cursor.relative

		if event.cursor.imageUpdate || !sawCursor {
			sawCursor = true
			let imgKey = event.key
			let pointer = ParsecGetBuffer(_parsec, imgKey)
			if pointer == nil {
				return
			}
			let size = event.cursor.size
			let width = event.cursor.width
			let height = event.cursor.height
			guard width > 0, height > 0, Int(size) >= Int(width) * Int(height) * 4 else {
				ParsecFree(pointer)
				return
			}
			mouseInfo.cursorWidth = Int(width)
			mouseInfo.cursorHeight = Int(height)

			if prevHidden && !event.cursor.hidden {
				mouseInfo.mouseX = Int32(event.cursor.positionX)
				mouseInfo.mouseY = Int32(event.cursor.positionY)
			}

			mouseInfo.cursorHotX = Int(event.cursor.hotX)
			mouseInfo.cursorHotY = Int(event.cursor.hotY)

			let elmentLength: Int = 4
			let render: CGColorRenderingIntent = CGColorRenderingIntent.defaultIntent
			let rgbColorSpace = CGColorSpaceCreateDeviceRGB()
			let bitmapInfo: CGBitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue)
			if let providerRef = CGDataProvider(data: NSData(bytes: pointer, length: Int(size))),
				let cgimage = CGImage(width: Int(width), height: Int(height), bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: Int(width) * elmentLength, space: rgbColorSpace, bitmapInfo: bitmapInfo, provider: providerRef, decode: nil, shouldInterpolate: true, intent: render) {
				mouseInfo.cursorImg = cgimage
			}
			ParsecFree(pointer)
		}
	}

	func setMuted(_ muted: Bool) {
		audio_mute(muted, _audioPtr)
	}

	func applyConfig() {

		var parsecClientCfg = ParsecClientConfig()

		parsecClientCfg.video.0.decoderIndex = 1
		parsecClientCfg.video.0.resolutionX = 0
		parsecClientCfg.video.0.resolutionY = 0
		parsecClientCfg.video.0.decoderH265 = SettingsHandler.decoder == .h265

		parsecClientCfg.video.1.decoderIndex = 1
		parsecClientCfg.video.1.resolutionX = 0
		parsecClientCfg.video.1.resolutionY = 0
		parsecClientCfg.video.1.decoderH265 = SettingsHandler.decoder == .h265

		parsecClientCfg.mediaContainer = mediaContainer
		parsecClientCfg.protocol = netProtocol
		// parsecClientCfg.secret = ""
		parsecClientCfg.pngCursor = pngCursor

		ParsecClientSetConfig(_parsec, &parsecClientCfg)
	}

	func sendMouseMessage(_ button: ParsecMouseButton, _ x: Int32, _ y: Int32, _ pressed: Bool) {
		// Send the mouse position
		sendMousePosition(x, y)

		// Send the mouse button state
		var buttonMessage = ParsecMessage()
		buttonMessage.type = MESSAGE_MOUSE_BUTTON
		buttonMessage.mouseButton.button = button
		buttonMessage.mouseButton.pressed = pressed
		ParsecClientSendMessage(_parsec, &buttonMessage)
	}

	func sendMouseClickMessage(_ button: ParsecMouseButton, _ pressed: Bool) {
		var buttonMessage = ParsecMessage()
		buttonMessage.type = MESSAGE_MOUSE_BUTTON
		buttonMessage.mouseButton.button = button
		buttonMessage.mouseButton.pressed = pressed
		ParsecClientSendMessage(_parsec, &buttonMessage)
	}

	func sendMouseDelta(_ dx: Int32, _ dy: Int32) {
		if mouseInfo.mousePositionRelative {
			sendMouseRelativeMove(dx, dy)
		} else {
			sendMousePosition(mouseInfo.mouseX + dx, mouseInfo.mouseY + dy)
		}

	}
	static func clamp<T>(_ value: T, minValue: T, maxValue: T) -> T where T: Comparable {
		return min(max(value, minValue), maxValue)
	}

	func sendMousePosition(_ x: Int32, _ y: Int32) {
		mouseInfo.mouseX = ParsecSDKBridge.clamp(x, minValue: 0, maxValue: Int32(self.clientWidth))
		mouseInfo.mouseY = ParsecSDKBridge.clamp(y, minValue: 0, maxValue: Int32(self.clientHeight))
		var motionMessage = ParsecMessage()
		motionMessage.type = MESSAGE_MOUSE_MOTION
		motionMessage.mouseMotion.x = x
		motionMessage.mouseMotion.y = y
		ParsecClientSendMessage(_parsec, &motionMessage)
	}

	func sendMouseRelativeMove(_ dx: Int32, _ dy: Int32) {
		var motionMessage = ParsecMessage()
		motionMessage.type = MESSAGE_MOUSE_MOTION
		motionMessage.mouseMotion.x = dx
		motionMessage.mouseMotion.y = dy
		motionMessage.mouseMotion.relative = true
		ParsecClientSendMessage(_parsec, &motionMessage)
	}

	func getKeyCodeByText(text: String) -> (ParsecKeycode?, Bool) {
		var keyCode: ParsecKeycode?
		var useShift = false
		if text.count == 1 {
			let char = Character(text)
			if char.isLetter || char.isNumber {
				keyCode = KeyCodeTranslators.parsecKeyCodeTranslator(text.uppercased())
				if char.isUppercase {
					useShift = true
				}
			} else if char.isNewline {
				keyCode = ParsecKeycode(40)
			} else if char.isWhitespace {
				keyCode = ParsecKeycode(44)
			} else {
				let (keycodeRaw, keyMod) = KeyCodeTranslators.getParsecKeycode(for: text)
				if keycodeRaw != -1 {
					keyCode = ParsecKeycode(UInt32(keycodeRaw))
					if keyMod {
						useShift = true
					}
				}
			}
		} else {
			keyCode = KeyCodeTranslators.parsecKeyCodeTranslator(text)
		}

		return (keyCode, useShift)
	}

	func sendVirtualKeyboardInput(text: String) {
		let (keyCode, useShift) = getKeyCodeByText(text: text)

		guard let keyCode else {
			return
		}
		var keyboardMessagePress = ParsecMessage()
		keyboardMessagePress.type = MESSAGE_KEYBOARD
		let sendShift = !isVirtualShiftOn && useShift
		if sendShift {
			keyboardMessagePress.keyboard = ParsecKeyboardMessage(code: KEY_LSHIFT, mod: MOD_NONE, pressed: true, __pad: (0, 0, 0))
			ParsecClientSendMessage(_parsec, &keyboardMessagePress)
		}
		keyboardMessagePress.keyboard = ParsecKeyboardMessage(code: keyCode, mod: MOD_NONE, pressed: true, __pad: (0, 0, 0))
		ParsecClientSendMessage(_parsec, &keyboardMessagePress)

		// add release delay in case some games ignore instant key release
		DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
			var release = ParsecMessage()
			release.type = MESSAGE_KEYBOARD
			release.keyboard = ParsecKeyboardMessage(code: keyCode, mod: MOD_NONE, pressed: false, __pad: (0, 0, 0))
			ParsecClientSendMessage(self._parsec, &release)
			if sendShift {
				release.keyboard = ParsecKeyboardMessage(code: KEY_LSHIFT, mod: MOD_NONE, pressed: false, __pad: (0, 0, 0))
				ParsecClientSendMessage(self._parsec, &release)
			}
		}
	}

	func sendVirtualKeyboardInput(text: String, isOn: Bool) {
		let (keyCode, _) = getKeyCodeByText(text: text)

		guard let keyCode else {
			return
		}

		if keyCode.rawValue == 225 {
			isVirtualShiftOn = isOn
		}

		var keyboardMessagePress = ParsecMessage()
		keyboardMessagePress.type = MESSAGE_KEYBOARD
		keyboardMessagePress.keyboard.pressed = isOn
		keyboardMessagePress.keyboard.code = keyCode
		ParsecClientSendMessage(_parsec, &keyboardMessagePress)

	}

	func sendKeyboardMessage(event: KeyBoardKeyEvent) {
		if event.input == nil {
			return
		}

		var keyboardMessagePress = ParsecMessage()
		keyboardMessagePress.type = MESSAGE_KEYBOARD
		keyboardMessagePress.keyboard.code = ParsecKeycode(UInt32(KeyCodeTranslators.uiKeyCodeToInt(key: event.input?.keyCode ?? UIKeyboardHIDUsage.keyboardErrorUndefined)))
		keyboardMessagePress.keyboard.pressed = event.isPressBegin
		capsLock = event.input?.modifierFlags.contains(.alphaShift) == true
		keyboardMessagePress.keyboard.mod = capsLock ? MOD_CAPS : MOD_NONE
		ParsecClientSendMessage(_parsec, &keyboardMessagePress)
	}

	func sendKeyboardMessage(keyCode: UInt32, pressed: Bool)
	{
		var keyboardMessagePress = ParsecMessage()
		keyboardMessagePress.type = MESSAGE_KEYBOARD
		keyboardMessagePress.keyboard.code = ParsecKeycode(keyCode)
		keyboardMessagePress.keyboard.pressed = pressed
		keyboardMessagePress.keyboard.mod = capsLock ? MOD_CAPS : MOD_NONE
		ParsecClientSendMessage(_parsec, &keyboardMessagePress)
	}
	
	func sendGameControllerButtonMessage(controllerId: UInt32, _ button:ParsecGamepadButton, pressed: Bool)
	{
		var pmsg = ParsecMessage()
		pmsg.type = MESSAGE_GAMEPAD_BUTTON
		pmsg.gamepadButton.id = controllerId
		pmsg.gamepadButton.button = button
		pmsg.gamepadButton.pressed = pressed
		ParsecClientSendMessage(_parsec, &pmsg)
	}

	/*static func sendGameControllerTriggerButtonMessage(controllerId: UInt32, _ button:ParsecGamepadAxis, pressed: Bool)
	{
	    var pmsg = ParsecMessage()
		pmsg.type = MESSAGE_GAMEPAD_AXIS
		pmsg.gamepadAxis.id = controllerId
		pmsg.gamepadAxis.button = button
		pmsg.gamepadAxis.pressed = pressed
		ParsecClientSendMessage(_parsec, &pmsg)
	}*/

	func sendGameControllerAxisMessage(controllerId: UInt32, _ button: ParsecGamepadAxis, _ value: Int16) {
	    var pmsg = ParsecMessage()
		pmsg.type = MESSAGE_GAMEPAD_AXIS
		pmsg.gamepadAxis.id = controllerId
		pmsg.gamepadAxis.axis = button
		pmsg.gamepadAxis.value = value
		ParsecClientSendMessage(_parsec, &pmsg)
	}

	func sendGameControllerUnplugMessage(controllerId: UInt32) {
	    var pmsg = ParsecMessage()
		pmsg.type = MESSAGE_GAMEPAD_UNPLUG
		pmsg.gamepadUnplug.id = controllerId
		ParsecClientSendMessage(_parsec, &pmsg)
	}

	func sendWheelMsg(x: Int32, y: Int32) {
		var pmsg = ParsecMessage()
		pmsg.type = MESSAGE_MOUSE_WHEEL
		pmsg.mouseWheel.x = x
		pmsg.mouseWheel.y = y
		ParsecClientSendMessage(_parsec, &pmsg)
	}

	func startBackgroundTask() {

		pollGeneration += 1
		let generation = pollGeneration

		let audio = DispatchWorkItem { [weak self] in
			while let self = self, self.pollGeneration == generation {
				if self.pollAudio() == PARSEC_NOT_RUNNING {
					usleep(50_000)
				}
			}
		}

		let event = DispatchWorkItem { [weak self] in
			var sawCursor = false
			while let self = self, self.pollGeneration == generation {
				if self.pollEvent(sawCursor: &sawCursor) {
					usleep(50_000)
				}
			}
		}

		DispatchQueue.global().async(execute: audio)
		DispatchQueue.global().async(execute: event)
	}

	// ask the host for a second display on video stream 1; the external display draws it,
	// without one the probe loop below only counts frames and logs them
	func startStream1(output: String) {
		if probeToken != 0 {
			endStream1Probe(reason: "restart")
		}
		probeCounter += 1
		let token = probeCounter
		let generation = pollGeneration
		probeToken = token

		let enabled = ParsecClientEnableStream(_parsec, 1, true)
		var dims = "set by the external display"
		if !stream1Drawn {
			let st = ParsecClientSetDimensions(_parsec, 1, UInt32(clientWidth), UInt32(clientHeight), clientScale)
			dims = "\(st.rawValue) \(Int(clientWidth))x\(Int(clientHeight))@\(clientScale)"
		}
		appNote("[stream1-probe] start output=\(output) enable=\(enabled.rawValue) dims=\(dims)")
		DataManager.model.stream1Output = output
		updateHostVideoConfig()

		let poll = DispatchWorkItem { [weak self] in
			let stats = Stream1ProbeStats()
			let opaque = Unmanaged.passUnretained(stats).toOpaque()
			while let self = self, self.pollGeneration == generation, self.probeToken == token {
				if self.stream1Drawn {
					usleep(50_000)
					continue
				}
				let status = ParsecClientPollFrame(self._parsec, 1, stream1ProbeCallback, 16, opaque)
				stats.polls += 1
				stats.statusCounts[status.rawValue, default: 0] += 1
				let now = CACurrentMediaTime()
				if now - stats.lastReportAt >= 2 {
					self.reportStream1Probe(stats, elapsed: now - stats.lastReportAt)
					stats.frames = 0
					stats.polls = 0
					stats.statusCounts.removeAll()
					stats.lastReportAt = now
				}
				if status == PARSEC_NOT_RUNNING {
					usleep(50_000)
				}
			}
			appNote("[stream1-probe] poll loop ended, \(stats.totalFrames) frames in total")
		}
		DispatchQueue.global().async(execute: poll)
	}

	func stopStream1() {
		guard probeToken != 0 else { return }
		endStream1Probe(reason: "stopped")
		updateHostVideoConfig()
	}

	private func endStream1Probe(reason: String) {
		guard probeToken != 0 else { return }
		probeToken = 0
		let disabled = ParsecClientEnableStream(_parsec, 1, false)
		appNote("[stream1-probe] end (\(reason)) disable=\(disabled.rawValue)")
		if Thread.isMainThread {
			DataManager.model.stream1Output = nil
		} else {
			DispatchQueue.main.async { DataManager.model.stream1Output = nil }
		}
	}

	private func reportStream1Probe(_ stats: Stream1ProbeStats, elapsed: CFTimeInterval) {
		let fps = Double(stats.frames) / elapsed
		let statuses = stats.statusCounts.sorted { $0.key < $1.key }.map { "\($0.key):\($0.value)" }.joined(separator: " ")
		var size = "no frame yet"
		if let f = stats.lastFrame {
			size = "\(f.width)x\(f.height) full \(f.fullWidth)x\(f.fullHeight) fmt \(f.format.rawValue)"
		}
		var pcs = ParsecClientStatus()
		let st = ParsecClientGetStatus(_parsec, &pcs)
		let dec = pcs.decoder.1
		let m = pcs.`self`.metrics.1
		appNote(String(format: "[stream1-probe] %.1f fps, %@, polls %ld [%@], status %d, dec1 %dx%d h265=%@, net %.0f ms, dec %.1f ms, %.1f Mbps, queued %d",
			fps, size, stats.polls, statuses, st.rawValue, dec.width, dec.height, dec.h265 ? "1" : "0", m.networkLatency, m.decodeLatency, m.bitrate, m.queuedFrames))
	}

	func sendUserData(type: ParsecUserDataType, message: Data) {
        var nullTerminatedMessage = message
        nullTerminatedMessage.append(0)
		nullTerminatedMessage.withUnsafeBytes { ptr in
			let ptr2 = ptr.baseAddress?.assumingMemoryBound(to: CChar.self)
			ParsecClientSendUserData(_parsec, type.rawValue, ptr2)
		}
	}

	func updateHostVideoConfig() {
		var videoConfig = ParsecUserDataVideoConfig()
		videoConfig.video[0].resolutionX = DataManager.model.resolutionX
		videoConfig.video[0].resolutionY = DataManager.model.resolutionY
		videoConfig.video[0].encoderMaxBitrate = DataManager.model.bitrate
		videoConfig.video[0].fullFPS = DataManager.model.constantFps
		videoConfig.video[0].output = DataManager.model.output
		if let output = DataManager.model.stream1Output {
			videoConfig.video[1].resolutionX = DataManager.model.resolutionX
			videoConfig.video[1].resolutionY = DataManager.model.resolutionY
			videoConfig.video[1].encoderMaxBitrate = DataManager.model.bitrate
			videoConfig.video[1].fullFPS = DataManager.model.constantFps
			videoConfig.video[1].output = output
		}
		let encoder = JSONEncoder()
		let data = try! encoder.encode(videoConfig)
		CParsec.sendUserData(type: .setVideoConfig, message: data)
	}
}
