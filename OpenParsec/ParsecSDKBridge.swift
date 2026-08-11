import ParsecSDK
import MetalKit
import UIKit
import AVFoundation
import Network

enum RendererType: Int
{
	case opengl
    case metal
}

enum DecoderPref: Int
{
    case h264
    case h265
}

enum CursorMode: Int
{
    case touchpad
    case direct
}

enum RightClickPosition: Int
{
	case firstFinger
	case middle
	case secondFinger
}

struct KeyBoardKeyEvent {
	var input: UIKey?
	var isPressBegin: Bool
}

private extension Data {
	mutating func appendUInt16LE(_ value: UInt16) {
		var le = value.littleEndian
		append(UnsafeBufferPointer(start: &le, count: 1))
	}

	mutating func appendUInt32LE(_ value: UInt32) {
		var le = value.littleEndian
		append(UnsafeBufferPointer(start: &le, count: 1))
	}

	mutating func appendUInt64LE(_ value: UInt64) {
		var le = value.littleEndian
		append(UnsafeBufferPointer(start: &le, count: 1))
	}

	mutating func appendInt16LE(_ value: Int16) {
		var le = value.littleEndian
		append(UnsafeBufferPointer(start: &le, count: 1))
	}
}

final class SidecarUDPSender {
	private let queue = DispatchQueue(label: "openparsec.sidecar.udp")
	private var connection: NWConnection?
	private var currentHost: String = ""
	private var currentPort: Int = 0
	private var enabled: Bool = false
	private var token: String = ""
	private(set) var sentPackets: UInt64 = 0
	private(set) var sendErrors: UInt64 = 0

	func updateConfig(enabled: Bool, host: String, port: Int, token: String) {
		queue.async {
			self.enabled = enabled
			self.token = token
			if self.currentHost != host || self.currentPort != port {
				self.connection?.cancel()
				self.connection = nil
				self.currentHost = host
				self.currentPort = port
			}
		}
	}

	func reset() {
		queue.async {
			self.connection?.cancel()
			self.connection = nil
		}
	}

	func sendPcm16Mono(samples: [Int16], sampleRate: UInt32, sequence: UInt32, timestampNs: UInt64) {
		queue.async {
			guard self.enabled else {
				return
			}
			guard !self.currentHost.isEmpty, !self.token.isEmpty, self.currentPort > 0, self.currentPort <= 65535 else {
				return
			}
			guard !samples.isEmpty else {
				return
			}
			self.ensureConnection()
			guard let connection = self.connection else {
				self.sendErrors += 1
				return
			}

			var payload = Data(capacity: samples.count * MemoryLayout<Int16>.size)
			for sample in samples {
				payload.appendInt16LE(sample)
			}

			let tokenData = self.token.data(using: .utf8) ?? Data()
			var packet = Data(capacity: 32 + tokenData.count + payload.count)
			packet.append(contentsOf: [0x4f, 0x50, 0x4d, 0x31]) // OPM1
			packet.append(1) // version
			packet.append(0) // flags
			packet.appendUInt32LE(sequence)
			packet.appendUInt64LE(timestampNs)
			packet.appendUInt32LE(sampleRate)
			packet.append(1) // channels (mono)
			packet.append(0) // reserved
			packet.appendUInt16LE(UInt16(min(samples.count, Int(UInt16.max))))
			packet.appendUInt16LE(UInt16(min(tokenData.count, Int(UInt16.max))))
			packet.appendUInt32LE(UInt32(min(payload.count, Int(UInt32.max))))
			packet.append(tokenData)
			packet.append(payload)

			connection.send(content: packet, completion: .contentProcessed { error in
				if error == nil {
					self.sentPackets += 1
				} else {
					self.sendErrors += 1
				}
			})
		}
	}

	private func ensureConnection() {
		guard connection == nil else {
			return
		}
		guard let port = NWEndpoint.Port(rawValue: UInt16(currentPort)) else {
			return
		}
		let params = NWParameters.udp
		let newConnection = NWConnection(host: NWEndpoint.Host(currentHost), port: port, using: params)
		newConnection.stateUpdateHandler = { _ in }
		newConnection.start(queue: queue)
		connection = newConnection
	}
}

final class MicrophoneManager {
	private let supportEvaluator: () -> Bool
	private let session = AVAudioSession.sharedInstance()
	private let queue = DispatchQueue(label: "openparsec.microphone.queue")
	private var engine: AVAudioEngine?
	private var frameHandler: ((AVAudioPCMBuffer, AVAudioTime) -> Void)?
	private var observersRegistered = false
	private var observerTokens: [NSObjectProtocol] = []
	private var shouldResumeAfterInterruption = false
	private(set) var totalFramesCaptured: UInt64 = 0
	private(set) var lastError: String?
	private(set) var isEnabled: Bool = false
	private(set) var isMuted: Bool = true

	init(supportEvaluator: @escaping () -> Bool = { false }, frameHandler: ((AVAudioPCMBuffer, AVAudioTime) -> Void)? = nil) {
		self.supportEvaluator = supportEvaluator
		self.frameHandler = frameHandler
	}

	deinit {
		for token in observerTokens {
			NotificationCenter.default.removeObserver(token)
		}
		observerTokens.removeAll()
	}

	var isSupported: Bool {
		supportEvaluator()
	}

	func setMuted(_ muted: Bool) {
		isMuted = muted
	}

	func setFrameHandler(_ handler: ((AVAudioPCMBuffer, AVAudioTime) -> Void)?) {
		queue.async {
			self.frameHandler = handler
		}
	}

	func setEnabled(_ enabled: Bool, completion: ((Bool) -> Void)? = nil) {
		guard supportEvaluator() else {
			isEnabled = false
			lastError = "sidecar_unconfigured"
			completion?(false)
			return
		}

		requestPermissionIfNeeded { [weak self] granted in
			guard let self = self else {
				completion?(false)
				return
			}

			if !enabled {
				self.queue.async {
					self.stopCapture()
					self.isEnabled = false
					self.isMuted = true
					self.restorePlaybackSession()
					DispatchQueue.main.async {
						completion?(true)
					}
				}
				return
			}

			guard granted else {
				self.queue.async {
					self.isEnabled = false
					self.isMuted = true
					self.lastError = "permission_denied"
					DispatchQueue.main.async {
						completion?(false)
					}
				}
				return
			}

			self.queue.async {
				let ok = self.startCapture()
				self.isEnabled = ok
				if !ok {
					self.isMuted = true
				}
				DispatchQueue.main.async {
					completion?(ok)
				}
			}
		}
	}

	private func requestPermissionIfNeeded(completion: @escaping (Bool) -> Void) {
		switch AVAudioSession.sharedInstance().recordPermission {
		case .granted:
			completion(true)
		case .denied:
			completion(false)
		case .undetermined:
			AVAudioSession.sharedInstance().requestRecordPermission { granted in
				DispatchQueue.main.async {
					completion(granted)
				}
			}
		@unknown default:
			completion(false)
		}
	}

	private func startCapture() -> Bool {
		registerObserversIfNeeded()
		do {
			try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetooth, .defaultToSpeaker])
			try session.setPreferredSampleRate(48_000)
			try session.setPreferredIOBufferDuration(0.02)
			try session.setActive(true)
		} catch {
			lastError = "audio_session_config_failed: \(error.localizedDescription)"
			return false
		}

		let audioEngine = AVAudioEngine()
		let input = audioEngine.inputNode
		let format = input.inputFormat(forBus: 0)
		input.removeTap(onBus: 0)
		input.installTap(onBus: 0, bufferSize: 960, format: format) { [weak self] buffer, when in
			guard let self = self else {
				return
			}
			self.queue.async {
				guard self.isEnabled else {
					return
				}
				self.totalFramesCaptured += UInt64(buffer.frameLength)
				if self.isMuted {
					return
				}
				self.frameHandler?(buffer, when)
			}
		}

		audioEngine.prepare()
		do {
			try audioEngine.start()
			engine = audioEngine
			lastError = nil
			return true
		} catch {
			input.removeTap(onBus: 0)
			engine = nil
			lastError = "capture_start_failed: \(error.localizedDescription)"
			return false
		}
	}

	private func stopCapture() {
		engine?.inputNode.removeTap(onBus: 0)
		engine?.stop()
		engine = nil
	}

	private func restorePlaybackSession() {
		do {
			try session.setCategory(.playback, mode: .default)
			try session.setActive(true)
		} catch {
			lastError = "restore_playback_failed: \(error.localizedDescription)"
		}
	}

	private func registerObserversIfNeeded() {
		guard !observersRegistered else {
			return
		}
		observersRegistered = true
		let interruptionToken = NotificationCenter.default.addObserver(
			forName: AVAudioSession.interruptionNotification,
			object: nil,
			queue: nil
		) { [weak self] note in
			self?.handleInterruption(note)
		}
		let routeToken = NotificationCenter.default.addObserver(
			forName: AVAudioSession.routeChangeNotification,
			object: nil,
			queue: nil
		) { [weak self] note in
			self?.handleRouteChange(note)
		}
		observerTokens.append(interruptionToken)
		observerTokens.append(routeToken)
	}

	private func handleInterruption(_ notification: Notification) {
		guard
			let userInfo = notification.userInfo,
			let rawType = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
			let type = AVAudioSession.InterruptionType(rawValue: rawType)
		else {
			return
		}

		queue.async {
			switch type {
			case .began:
				self.shouldResumeAfterInterruption = self.isEnabled
				self.stopCapture()
			case .ended:
				guard self.shouldResumeAfterInterruption else {
					return
				}
				self.shouldResumeAfterInterruption = false
				_ = self.startCapture()
			@unknown default:
				break
			}
		}
	}

	private func handleRouteChange(_ notification: Notification) {
		guard
			let userInfo = notification.userInfo,
			let rawReason = userInfo[AVAudioSessionRouteChangeReasonKey] as? UInt,
			let reason = AVAudioSession.RouteChangeReason(rawValue: rawReason)
		else {
			return
		}

		if reason == .newDeviceAvailable || reason == .oldDeviceUnavailable || reason == .routeConfigurationChange {
			queue.async {
				guard self.isEnabled else {
					return
				}
				self.stopCapture()
				_ = self.startCapture()
			}
		}
	}
}

class ParsecSDKBridge: ParsecService
{
	var hostWidth: Float = 1920
	
	var hostHeight: Float = 1080
	
	
	static let PARSEC_VER: UInt32 = UInt32((PARSEC_VER_MAJOR << 16) | PARSEC_VER_MINOR)
	
	private var _parsec: OpaquePointer!
	private var _audio: OpaquePointer!
	private let _audioPtr: UnsafeRawPointer
	private let _sidecarSender = SidecarUDPSender()
	private var _micPcmFrameCount: UInt64 = 0
	private var _micPacketSequence: UInt32 = 0
	private lazy var _microphone = MicrophoneManager(supportEvaluator: { [weak self] in
		self?.isSidecarConfigured() ?? false
	}) { [weak self] buffer, _ in
		self?.handleMicrophonePcm(buffer: buffer)
	}
	
	private var isVirtualShiftOn = false
	
	public var clientWidth: Float = 1920
	public var clientHeight: Float = 1080
	
	public var netProtocol: Int32 = 1
	public var mediaContainer: Int32 = 0
	public var pngCursor: Bool = false
	var backgroundTaskRunning = true
	var didSetResolution = false
	
	public var mouseInfo = MouseInfo()
	
	init() {
		print("Parsec SDK Version: " + String(ParsecSDKBridge.PARSEC_VER))
		
		ParsecSetLogCallback(
			{ (level, msg, opaque) in
				print("[\(level == LOG_DEBUG ? "D" : "I")] \(String(cString:msg!))")
			}, nil)
		
		audio_init(&_audio)
		
		self._audioPtr = UnsafeRawPointer(_audio)
		
		do {
			let reservedCfg = ["ssHost": "kessel-ws.parsec.app"]
			let json = JSONEncoder()
			try json.encode(reservedCfg).withUnsafeBytes { (jsonStrBPtr: UnsafeRawBufferPointer) in
				guard let jsonStrPtr = jsonStrBPtr.baseAddress else {
					return
				}
				ParsecInit(ParsecSDKBridge.PARSEC_VER, nil, jsonStrPtr, &_parsec)
			}

		} catch {
			print("error: \(error)")
		}
		applySidecarConfig()

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
		parsecClientCfg.video.0.decoderCompatibility = SettingsHandler.decoderCompatibility
		parsecClientCfg.video.0.decoderH265 = SettingsHandler.decoder == .h265

		parsecClientCfg.video.1.decoderIndex = 1
		parsecClientCfg.video.1.resolutionX = Int32(SettingsHandler.resolution.width)
		parsecClientCfg.video.1.resolutionY = Int32(SettingsHandler.resolution.height)
		parsecClientCfg.video.1.decoderCompatibility = SettingsHandler.decoderCompatibility
		parsecClientCfg.video.1.decoderH265 = SettingsHandler.decoder == .h265

		parsecClientCfg.mediaContainer = 0
		parsecClientCfg.protocol = 1
		//parsecClientCfg.secret = ""
		parsecClientCfg.pngCursor = false

		self.startBackgroundTask()
		
		let status = ParsecClientConnect(_parsec, &parsecClientCfg, NetworkHandler.clinfo?.session_id, peerID)
		
		if status == PARSEC_OK || status == PARSEC_CONNECTING {
			ParsecBackgroundManager.shared.connectionDidStart(peerId: peerID)
		}

		return status
	}
	
	func disconnect() {
		DispatchQueue.global(qos: .utility).async {
			self._microphone.setMuted(true)
			self._microphone.setEnabled(false)
			self._sidecarSender.reset()
		}
		audio_clear(&_audio)
		ParsecClientDisconnect(_parsec)
		backgroundTaskRunning = false
		
		ParsecBackgroundManager.shared.connectionDidEnd()
	}
	
	func getStatus() -> ParsecStatus {
		
		return ParsecClientGetStatus(_parsec, nil)
	}
	
	func getStatusEx(_ pcs:inout ParsecClientStatus) -> ParsecStatus {
		let ans = ParsecClientGetStatus(_parsec, &pcs)
		self.hostHeight = Float(pcs.decoder.0.height)
		self.hostWidth = Float(pcs.decoder.0.width)

		return ans;
	}
	
	func setFrame(_ width:CGFloat, _ height:CGFloat, _ scale: CGFloat) {
		
		ParsecClientSetDimensions(_parsec, UInt8(DEFAULT_STREAM), UInt32(width), UInt32(height), Float(scale))
		
		clientWidth = Float(width)
		clientHeight = Float(height)
		mouseInfo.mouseX = Int32(width / 2)
		mouseInfo.mouseY = Int32(height / 2)
	}
	
	// timeout in ms, 16 == 60 FPS, 8 == 120 FPS, etc.
	func renderGLFrame(timeout: UInt32 = 16) {
		
		ParsecClientGLRenderFrame(_parsec, UInt8(DEFAULT_STREAM), nil, nil, timeout)
	}
	
	/*static func renderMetalFrame(_ queue:inout MTLCommandQueue, _ texturePtr: UnsafeMutablePointer<UnsafeMutableRawPointer?>, timeout: UInt32 = 16) // timeout in ms, 16 == 60 FPS, 8 == 120 FPS, etc.
	 {
	 ParsecClientMetalRenderFrame(_parsec, UInt8(DEFAULT_STREAM), &queue, texturePtr, nil, nil, timeout)
	 }*/
	
	func pollAudio(timeout: UInt32 = 16) // timeout in ms, 16 == 60 FPS, 8 == 120 FPS, etc.
	{
		ParsecClientPollAudio(_parsec, audio_cb, timeout, _audioPtr)
	}
	
	var getFirstCursor = false
	var mousePositionRelative = false
	
	func pollEvent(timeout: UInt32 = 16) // timeout in ms, 16 == 60 FPS, 8 == 120 FPS, etc.
	{
		var e: ParsecClientEvent!
		var _event = ParsecClientEvent()
		var pollSuccess = false;
		withUnsafeMutablePointer(to: &_event, {(_eventPtr) in
			pollSuccess = ParsecClientPollEvents(_parsec, timeout, _eventPtr)
			e = _eventPtr.pointee
		})
		if !pollSuccess {
			return
		}
		if e.type == CLIENT_EVENT_CURSOR {
			handleCursorEvent(event: e.cursor)
		} else if e.type == CLIENT_EVENT_USER_DATA {
			handleUserDataEvent(event: e.userData)
		}
	}
	
	func handleUserDataEvent(event: ParsecClientUserDataEvent) {
		
		let pointer = ParsecGetBuffer(_parsec, event.key)
		switch event.id {
		case 11:
			do {
				let decoder = JSONDecoder()
				let config = try decoder.decode(ParsecUserDataVideoConfig.self, from: Data(bytesNoCopy: pointer!, count: strlen(pointer!), deallocator: .none))
				let videoConfig = config.video[0]

				DispatchQueue.main.async {
					DataManager.model.resolutionX = videoConfig.resolutionX
					DataManager.model.resolutionY = videoConfig.resolutionY
					DataManager.model.bitrate = videoConfig.encoderMaxBitrate
					DataManager.model.constantFps = videoConfig.fullFPS
					if !self.didSetResolution {
						self.didSetResolution = true
						DataManager.model.resolutionX = SettingsHandler.resolution.width
						DataManager.model.resolutionY = SettingsHandler.resolution.height
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
	
	func handleCursorEvent(event: ParsecClientCursorEvent) {
		let prevHidden = mouseInfo.cursorHidden
		mouseInfo.cursorHidden = event.cursor.hidden
		mouseInfo.mousePositionRelative = event.cursor.relative
		
		if event.cursor.imageUpdate || !getFirstCursor{
			getFirstCursor = true
			let imgKey = event.key
			let pointer = ParsecGetBuffer(_parsec, imgKey)
			if pointer == nil{
				return
			}
			let size = event.cursor.size
			let width = event.cursor.width
			let height = event.cursor.height
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
			let providerRef: CGDataProvider? = CGDataProvider(data: NSData(bytes: pointer, length: Int(size)))
			let cgimage: CGImage? = CGImage(width: Int(width), height: Int(height), bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: Int(width) * elmentLength, space: rgbColorSpace, bitmapInfo: bitmapInfo, provider: providerRef!, decode: nil, shouldInterpolate: true, intent: render)
			if cgimage != nil {
				mouseInfo.cursorImg = cgimage
			}
			ParsecFree(pointer)
		}
	}
	
	func setMuted(_ muted: Bool) {
		audio_mute(muted, _audioPtr)
	}

	func setMicrophoneEnabled(_ enabled: Bool) {
		applySidecarConfig()
		_microphone.setEnabled(enabled) { granted in
			if enabled && !granted {
				print("microphone unavailable: sidecar config incomplete or permission denied")
			}
			self.updateHostVideoConfig()
		}
	}

	func setMicrophoneMuted(_ muted: Bool) {
		_microphone.setMuted(muted)
	}

	func isMicrophoneEnabled() -> Bool {
		_microphone.isEnabled
	}

	func isMicrophoneMuted() -> Bool {
		_microphone.isMuted
	}

	func isMicrophoneSupported() -> Bool {
		isSidecarConfigured()
	}

	private func handleMicrophonePcm(buffer: AVAudioPCMBuffer) {
		_micPcmFrameCount += UInt64(buffer.frameLength)
		guard let samples = monoPcm16(from: buffer) else {
			return
		}
		_micPacketSequence &+= 1
		let timestampNs = DispatchTime.now().uptimeNanoseconds
		_sidecarSender.sendPcm16Mono(
			samples: samples,
			sampleRate: UInt32(max(1, Int(buffer.format.sampleRate))),
			sequence: _micPacketSequence,
			timestampNs: timestampNs
		)
	}

	private func applySidecarConfig() {
		let host = SettingsHandler.sidecarMicHost.trimmingCharacters(in: .whitespacesAndNewlines)
		let token = SettingsHandler.sidecarMicToken.trimmingCharacters(in: .whitespacesAndNewlines)
		_sidecarSender.updateConfig(
			enabled: SettingsHandler.sidecarMicEnabled,
			host: host,
			port: SettingsHandler.sidecarMicPort,
			token: token
		)
	}

	private func isSidecarConfigured() -> Bool {
		let host = SettingsHandler.sidecarMicHost.trimmingCharacters(in: .whitespacesAndNewlines)
		let token = SettingsHandler.sidecarMicToken.trimmingCharacters(in: .whitespacesAndNewlines)
		let validPort = SettingsHandler.sidecarMicPort > 0 && SettingsHandler.sidecarMicPort <= 65535
		return SettingsHandler.sidecarMicEnabled && !host.isEmpty && !token.isEmpty && validPort
	}

	private func monoPcm16(from buffer: AVAudioPCMBuffer) -> [Int16]? {
		let frames = Int(buffer.frameLength)
		if frames <= 0 {
			return nil
		}

		let gain = effectiveMicGain()

		let channels = max(Int(buffer.format.channelCount), 1)
		var output = [Int16](repeating: 0, count: frames)

		if let int16Channels = buffer.int16ChannelData {
			if buffer.format.isInterleaved {
				let base = int16Channels[0]
				for i in 0..<frames {
					let idx = i * channels
					if channels == 1 {
						output[i] = applyGainAndClamp(sample: base[idx], gain: gain)
					} else {
						let sum = Int(base[idx]) + Int(base[idx + 1])
						output[i] = applyGainAndClamp(sample: Int16(sum / 2), gain: gain)
					}
				}
			} else {
				let left = int16Channels[0]
				if channels == 1 {
					for i in 0..<frames {
						output[i] = applyGainAndClamp(sample: left[i], gain: gain)
					}
				} else {
					let right = int16Channels[1]
					for i in 0..<frames {
						let sum = Int(left[i]) + Int(right[i])
						output[i] = applyGainAndClamp(sample: Int16(sum / 2), gain: gain)
					}
				}
			}
			return output
		}

		if let floatChannels = buffer.floatChannelData {
			if buffer.format.isInterleaved {
				let base = floatChannels[0]
				for i in 0..<frames {
					let idx = i * channels
					let sample: Float
					if channels == 1 {
						sample = base[idx]
					} else {
						sample = (base[idx] + base[idx + 1]) * 0.5
					}
					let clamped = max(-1.0, min(1.0, sample * gain))
					output[i] = Int16(clamped * Float(Int16.max))
				}
			} else {
				let left = floatChannels[0]
				if channels == 1 {
					for i in 0..<frames {
						let clamped = max(-1.0, min(1.0, left[i] * gain))
						output[i] = Int16(clamped * Float(Int16.max))
					}
				} else {
					let right = floatChannels[1]
					for i in 0..<frames {
						let sample = (left[i] + right[i]) * 0.5
						let clamped = max(-1.0, min(1.0, sample * gain))
						output[i] = Int16(clamped * Float(Int16.max))
					}
				}
			}
			return output
		}

		return nil
	}

	private func applyGainAndClamp(sample: Int16, gain: Float) -> Int16 {
		let scaled = Float(sample) * gain
		let clamped = max(Float(Int16.min), min(Float(Int16.max), scaled))
		return Int16(clamped)
	}

	private func effectiveMicGain() -> Float {
		let session = AVAudioSession.sharedInstance()
		let portType = session.currentRoute.inputs.first?.portType
		let baseGain: Double
		switch portType {
		case .some(.builtInMic):
			baseGain = SettingsHandler.sidecarMicGainBuiltIn
		case .some(.bluetoothA2DP), .some(.bluetoothHFP), .some(.bluetoothLE), .some(.headsetMic), .some(.usbAudio), .some(.lineIn):
			baseGain = SettingsHandler.sidecarMicGainExternal
		default:
			baseGain = SettingsHandler.sidecarMicGain
		}
		return max(1.0, min(Float(baseGain), 8.0))
	}
	
	func applyConfig() {

		var parsecClientCfg = ParsecClientConfig()

		parsecClientCfg.video.0.decoderIndex = 1
		parsecClientCfg.video.0.resolutionX = 0
		parsecClientCfg.video.0.resolutionY = 0
		parsecClientCfg.video.0.decoderCompatibility = SettingsHandler.decoderCompatibility
		parsecClientCfg.video.0.decoderH265 = SettingsHandler.decoder == .h265

		parsecClientCfg.video.1.decoderIndex = 1
		parsecClientCfg.video.1.resolutionX = 0
		parsecClientCfg.video.1.resolutionY = 0
		parsecClientCfg.video.1.decoderCompatibility = SettingsHandler.decoderCompatibility
		parsecClientCfg.video.1.decoderH265 = SettingsHandler.decoder == .h265

		parsecClientCfg.mediaContainer = mediaContainer
		parsecClientCfg.protocol = netProtocol
		//parsecClientCfg.secret = ""
		parsecClientCfg.pngCursor = pngCursor

		ParsecClientSetConfig(_parsec, &parsecClientCfg);
	}
	
	func sendMouseMessage(_ button:ParsecMouseButton, _ x:Int32, _ y:Int32, _ pressed: Bool)
	{
		// Send the mouse position
		sendMousePosition(x, y)
		
		// Send the mouse button state
		var buttonMessage = ParsecMessage()
		buttonMessage.type = MESSAGE_MOUSE_BUTTON
		buttonMessage.mouseButton.button = button
		buttonMessage.mouseButton.pressed = pressed
		ParsecClientSendMessage(_parsec, &buttonMessage)
	}
	
	func sendMouseClickMessage(_ button:ParsecMouseButton, _ pressed: Bool) {
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
	static func clamp<T>(_ value: T, minValue: T, maxValue: T) -> T where T : Comparable {
		return min(max(value, minValue), maxValue)
	}
	
	func sendMousePosition(_ x:Int32, _ y:Int32)
	{
		mouseInfo.mouseX = ParsecSDKBridge.clamp(x, minValue: 0, maxValue: Int32(self.clientWidth))
		mouseInfo.mouseY = ParsecSDKBridge.clamp(y, minValue: 0, maxValue: Int32(self.clientHeight))
		var motionMessage = ParsecMessage()
		motionMessage.type = MESSAGE_MOUSE_MOTION
		motionMessage.mouseMotion.x = x
		motionMessage.mouseMotion.y = y
		ParsecClientSendMessage(_parsec, &motionMessage)
	}
	
	func sendMouseRelativeMove(_ dx:Int32, _ dy:Int32)
	{
		var motionMessage = ParsecMessage()
		motionMessage.type = MESSAGE_MOUSE_MOTION
		motionMessage.mouseMotion.x = dx
		motionMessage.mouseMotion.y = dy
		motionMessage.mouseMotion.relative = true
		ParsecClientSendMessage(_parsec, &motionMessage)
	}
	
	func getKeyCodeByText(text: String) -> (ParsecKeycode?, Bool) {
		var keyCode : ParsecKeycode?
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
			} else if char.isWhitespace{
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
		if !isVirtualShiftOn && useShift {
			keyboardMessagePress.keyboard = ParsecKeyboardMessage(code: KEY_LSHIFT, mod: MOD_NONE, pressed: true, __pad: (0,0,0))
			ParsecClientSendMessage(_parsec, &keyboardMessagePress)
		}
		keyboardMessagePress.keyboard = ParsecKeyboardMessage(code: keyCode, mod: MOD_NONE, pressed: true, __pad: (0,0,0))
		ParsecClientSendMessage(_parsec, &keyboardMessagePress)
		
		// add release delay in case some games ignore instant key release
		DispatchQueue.global().asyncAfter(deadline: .now() + 0.02) {
			keyboardMessagePress.keyboard = ParsecKeyboardMessage(code: keyCode, mod: MOD_NONE, pressed: false, __pad: (0,0,0))
			if !self.isVirtualShiftOn && useShift {
				keyboardMessagePress.keyboard = ParsecKeyboardMessage(code: KEY_LSHIFT, mod: MOD_NONE, pressed: false, __pad: (0,0,0))
			}
			ParsecClientSendMessage(self._parsec, &keyboardMessagePress)
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

	func sendKeyboardMessage(event:KeyBoardKeyEvent)
	{
		if event.input == nil {
			return
		}
		
		var keyboardMessagePress = ParsecMessage()
		keyboardMessagePress.type = MESSAGE_KEYBOARD
		keyboardMessagePress.keyboard.code = ParsecKeycode(UInt32(KeyCodeTranslators.uiKeyCodeToInt(key: event.input?.keyCode ?? UIKeyboardHIDUsage.keyboardErrorUndefined)))
		keyboardMessagePress.keyboard.pressed = event.isPressBegin
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
	
	func sendGameControllerAxisMessage(controllerId: UInt32, _ button:ParsecGamepadAxis, _ value: Int16)
	{
	    var pmsg = ParsecMessage()
		pmsg.type = MESSAGE_GAMEPAD_AXIS
		pmsg.gamepadAxis.id = controllerId
		pmsg.gamepadAxis.axis = button
		pmsg.gamepadAxis.value = value
		ParsecClientSendMessage(_parsec, &pmsg)
	}
	
	func sendGameControllerUnplugMessage(controllerId: UInt32)
	{
	    var pmsg = ParsecMessage()
		pmsg.type = MESSAGE_GAMEPAD_UNPLUG;
		pmsg.gamepadUnplug.id = controllerId;
		ParsecClientSendMessage(_parsec, &pmsg)
	}
	
	func sendWheelMsg(x: Int32, y: Int32) {
		var pmsg = ParsecMessage()
		pmsg.type = MESSAGE_MOUSE_WHEEL;
		pmsg.mouseWheel.x = x
		pmsg.mouseWheel.y = y
		ParsecClientSendMessage(_parsec, &pmsg)
	}
	
	func startBackgroundTask(){
	
		
		let item1 = DispatchWorkItem {
			while self.backgroundTaskRunning {
				self.pollAudio()
			}
			
		}

		let item2 = DispatchWorkItem {
			while self.backgroundTaskRunning {
				self.pollEvent()
	
				
			}
			
		}
		let mainQueue = DispatchQueue.global()
		mainQueue.async(execute: item1)
		mainQueue.async(execute: item2)
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
		videoConfig.virtualMicrophone = isMicrophoneEnabled() ? 1 : 0
		videoConfig.video[0].resolutionX = DataManager.model.resolutionX
		videoConfig.video[0].resolutionY = DataManager.model.resolutionY
		videoConfig.video[0].encoderMaxBitrate = DataManager.model.bitrate
		videoConfig.video[0].fullFPS = DataManager.model.constantFps
		videoConfig.video[0].output = DataManager.model.output
		let encoder = JSONEncoder()
		let data = try! encoder.encode(videoConfig)
		CParsec.sendUserData(type: .setVideoConfig, message: data)
	}
}
