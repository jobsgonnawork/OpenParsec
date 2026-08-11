import AVFoundation
import CoreAudio
import Darwin
import Foundation
import AudioToolbox

private let headerSize = 32
private let expectedMagic: [UInt8] = [0x4f, 0x50, 0x4d, 0x31] // OPM1

struct Config {
    let port: UInt16
    let token: String
    let outputDeviceName: String?
    let verbose: Bool
}

struct SidecarPacket {
    let version: UInt8
    let flags: UInt8
    let sequence: UInt32
    let timestampNs: UInt64
    let sampleRate: UInt32
    let channels: UInt8
    let frameCount: UInt16
    let payload: Data
}

final class Stats {
    private let queue = DispatchQueue(label: "mic.sidecar.stats")
    private var packetsReceived: UInt64 = 0
    private var packetsDecoded: UInt64 = 0
    private var packetsMalformed: UInt64 = 0
    private var authFailures: UInt64 = 0
    private var sequenceGaps: UInt64 = 0
    private var framesPlayed: UInt64 = 0
    private var lastSeq: UInt32?

    func onPacketReceived() {
        queue.async { self.packetsReceived += 1 }
    }

    func onMalformed() {
        queue.async { self.packetsMalformed += 1 }
    }

    func onAuthFailure() {
        queue.async { self.authFailures += 1 }
    }

    func onDecoded(sequence: UInt32) {
        queue.async {
            if let prev = self.lastSeq {
                let expected = prev &+ 1
                if sequence != expected {
                    self.sequenceGaps += 1
                }
            }
            self.lastSeq = sequence
            self.packetsDecoded += 1
        }
    }

    func onFramesPlayed(_ count: Int) {
        queue.async {
            self.framesPlayed += UInt64(max(0, count))
        }
    }

    func startPrinter() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 5, repeating: 5)
        timer.setEventHandler { [weak self] in
            guard let self = self else { return }
            print("[stats] recv=\(self.packetsReceived) decoded=\(self.packetsDecoded) malformed=\(self.packetsMalformed) authFail=\(self.authFailures) gaps=\(self.sequenceGaps) frames=\(self.framesPlayed)")
        }
        timer.resume()
    }
}

final class AudioPlaybackEngine {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var format: AVAudioFormat?
    private let outputDeviceID: AudioDeviceID?
    private var configuredSampleRate: Double = 0

    init(sampleRate: Double = 48_000, outputDeviceID: AudioDeviceID? = nil) throws {
        self.outputDeviceID = outputDeviceID
        engine.attach(player)
        try configureEngine(sampleRate: sampleRate)
    }

    private func configureEngine(sampleRate: Double) throws {
        guard let fmt = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: sampleRate, channels: 1, interleaved: false) else {
            throw NSError(domain: "MicSidecar", code: -1, userInfo: [NSLocalizedDescriptionKey: "Unable to create AVAudioFormat"])
        }

        player.stop()
        engine.stop()
        engine.disconnectNodeOutput(player)
        engine.connect(player, to: engine.mainMixerNode, format: fmt)

        if let outputDeviceID {
            var deviceID = outputDeviceID
            let setStatus = AudioUnitSetProperty(
                engine.outputNode.audioUnit!,
                kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global,
                0,
                &deviceID,
                UInt32(MemoryLayout<AudioDeviceID>.size)
            )
            guard setStatus == noErr else {
                throw NSError(
                    domain: "MicSidecar",
                    code: Int(setStatus),
                    userInfo: [NSLocalizedDescriptionKey: "Unable to route output to selected device"]
                )
            }
        }

        try engine.start()
        player.play()
        format = fmt
        configuredSampleRate = sampleRate
    }

    func enqueue(samples: [Int16], sampleRate: Double) {
        guard !samples.isEmpty else { return }

        let targetRate = max(8_000, min(96_000, sampleRate))
        if abs(configuredSampleRate - targetRate) > 1 {
            do {
                try configureEngine(sampleRate: targetRate)
                print("[audio] reconfigured playback sample rate: \(Int(targetRate)) Hz")
            } catch {
                fputs("Failed to reconfigure audio engine: \(error.localizedDescription)\n", stderr)
                return
            }
        }

        guard let format = format else { return }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else {
            return
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)

        guard let channel = buffer.int16ChannelData?[0] else {
            return
        }

        samples.withUnsafeBufferPointer { src in
            channel.update(from: src.baseAddress!, count: src.count)
        }

        player.scheduleBuffer(buffer, completionHandler: nil)
    }
}

final class UDPReceiver {
    private let queue = DispatchQueue(label: "mic.sidecar.udp")
    private let port: UInt16
    private let onDatagram: (Data) -> Void

    private var socketFd: Int32 = -1
    private var source: DispatchSourceRead?

    init(port: UInt16, onDatagram: @escaping (Data) -> Void) {
        self.port = port
        self.onDatagram = onDatagram
    }

    func start() throws {
        socketFd = Darwin.socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard socketFd >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .ENOTSUP)
        }

        var yes: Int32 = 1
        setsockopt(socketFd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        let flags = fcntl(socketFd, F_GETFL, 0)
        if flags >= 0 {
            _ = fcntl(socketFd, F_SETFL, flags | O_NONBLOCK)
        }

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(port).bigEndian
        addr.sin_addr = in_addr(s_addr: INADDR_ANY.bigEndian)

        let bindResult = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { raw in
                Darwin.bind(socketFd, raw, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }

        guard bindResult == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .ENOTSUP)
        }

        let readSource = DispatchSource.makeReadSource(fileDescriptor: socketFd, queue: queue)
        readSource.setEventHandler { [weak self] in
            self?.drainSocket()
        }
        readSource.setCancelHandler { [weak self] in
            guard let self = self else { return }
            if self.socketFd >= 0 {
                Darwin.close(self.socketFd)
                self.socketFd = -1
            }
        }
        source = readSource
        readSource.resume()

        print("[receiver] listening on UDP :\(port)")
    }

    private func drainSocket() {
        while true {
            var storage = sockaddr_storage()
            var storageLen = socklen_t(MemoryLayout<sockaddr_storage>.size)
            var buffer = [UInt8](repeating: 0, count: 65_535)

            let count = withUnsafeMutablePointer(to: &storage) { storagePtr -> Int in
                storagePtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { addrPtr in
                    Darwin.recvfrom(
                        socketFd,
                        &buffer,
                        buffer.count,
                        0,
                        addrPtr,
                        &storageLen
                    )
                }
            }

            if count > 0 {
                onDatagram(Data(buffer.prefix(count)))
                continue
            }

            if count == 0 {
                break
            }

            if errno == EAGAIN || errno == EWOULDBLOCK {
                break
            }

            break
        }
    }
}

func parseConfig() -> Config {
    var port: UInt16 = 26500
    var token = ""
    var outputDeviceName: String?
    var verbose = false

    var i = 1
    let args = CommandLine.arguments
    while i < args.count {
        let arg = args[i]
        switch arg {
        case "--port":
            if i + 1 < args.count, let value = UInt16(args[i + 1]) {
                port = value
                i += 1
            }
        case "--token":
            if i + 1 < args.count {
                token = args[i + 1]
                i += 1
            }
        case "--output-device":
            if i + 1 < args.count {
                outputDeviceName = args[i + 1]
                i += 1
            }
        case "--verbose":
            verbose = true
        default:
            break
        }
        i += 1
    }

    if token.isEmpty {
        fputs("Missing required --token\n", stderr)
        exit(2)
    }

    return Config(port: port, token: token, outputDeviceName: outputDeviceName, verbose: verbose)
}

func getAllOutputDevices() -> [AudioDeviceID] {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    var dataSize: UInt32 = 0
    let sizeStatus = AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize)
    guard sizeStatus == noErr, dataSize > 0 else {
        return []
    }

    let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
    var deviceIDs = [AudioDeviceID](repeating: 0, count: count)
    let dataStatus = AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject),
        &address,
        0,
        nil,
        &dataSize,
        &deviceIDs
    )
    guard dataStatus == noErr else {
        return []
    }
    return deviceIDs
}

func getDeviceName(_ id: AudioDeviceID) -> String? {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioObjectPropertyName,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    var dataSize = UInt32(MemoryLayout<CFString?>.size)
    let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(dataSize), alignment: MemoryLayout<CFString?>.alignment)
    defer { raw.deallocate() }

    let status = AudioObjectGetPropertyData(id, &address, 0, nil, &dataSize, raw)
    guard status == noErr else {
        return nil
    }

    let name = raw.assumingMemoryBound(to: CFString?.self).pointee
    return (name as String?)
}

func hasOutputStream(_ id: AudioDeviceID) -> Bool {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyStreamConfiguration,
        mScope: kAudioDevicePropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain
    )

    var dataSize: UInt32 = 0
    let sizeStatus = AudioObjectGetPropertyDataSize(id, &address, 0, nil, &dataSize)
    guard sizeStatus == noErr, dataSize > 0 else {
        return false
    }

    let audioBufferList = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: Int(dataSize))
    defer { audioBufferList.deallocate() }

    var mutableSize = dataSize
    let status = AudioObjectGetPropertyData(id, &address, 0, nil, &mutableSize, audioBufferList)
    guard status == noErr else {
        return false
    }

    let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
    for buffer in buffers where buffer.mNumberChannels > 0 {
        return true
    }
    return false
}

func findOutputDevice(named name: String) -> (id: AudioDeviceID, name: String)? {
    let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !normalized.isEmpty else {
        return nil
    }

    let devices = getAllOutputDevices()
    for deviceID in devices {
        guard hasOutputStream(deviceID) else {
            continue
        }
        guard let deviceName = getDeviceName(deviceID) else {
            continue
        }
        if deviceName.lowercased().contains(normalized) {
            return (deviceID, deviceName)
        }
    }

    return nil
}

func listOutputDeviceNames() -> [String] {
    let devices = getAllOutputDevices()
    var names: [String] = []
    for deviceID in devices {
        guard hasOutputStream(deviceID), let deviceName = getDeviceName(deviceID) else {
            continue
        }
        names.append(deviceName)
    }
    return names.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
}

func readUInt16LE(_ data: Data, _ offset: Int) -> UInt16 {
    data.withUnsafeBytes { ptr in
        ptr.loadUnaligned(fromByteOffset: offset, as: UInt16.self).littleEndian
    }
}

func readUInt32LE(_ data: Data, _ offset: Int) -> UInt32 {
    data.withUnsafeBytes { ptr in
        ptr.loadUnaligned(fromByteOffset: offset, as: UInt32.self).littleEndian
    }
}

func readUInt64LE(_ data: Data, _ offset: Int) -> UInt64 {
    data.withUnsafeBytes { ptr in
        ptr.loadUnaligned(fromByteOffset: offset, as: UInt64.self).littleEndian
    }
}

func parsePacket(_ data: Data) -> SidecarPacket? {
    guard data.count >= headerSize else { return nil }

    let bytes = [UInt8](data.prefix(4))
    guard bytes == expectedMagic else { return nil }

    let version = data[4]
    let flags = data[5]
    let sequence = readUInt32LE(data, 6)
    let timestampNs = readUInt64LE(data, 10)
    let sampleRate = readUInt32LE(data, 18)
    let channels = data[22]
    let frameCount = readUInt16LE(data, 24)
    let tokenLen = Int(readUInt16LE(data, 26))
    let payloadLen = Int(readUInt32LE(data, 28))

    let total = headerSize + tokenLen + payloadLen
    guard total == data.count else { return nil }

    let payloadStart = headerSize + tokenLen
    let payload = data.subdata(in: payloadStart..<payloadStart + payloadLen)

    return SidecarPacket(
        version: version,
        flags: flags,
        sequence: sequence,
        timestampNs: timestampNs,
        sampleRate: sampleRate,
        channels: channels,
        frameCount: frameCount,
        payload: payload
    )
}

func validateToken(_ data: Data, expectedToken: String) -> Bool {
    guard data.count >= headerSize else { return false }
    let tokenLen = Int(readUInt16LE(data, 26))
    guard tokenLen >= 0 else { return false }
    guard data.count >= headerSize + tokenLen else { return false }
    let tokenData = data.subdata(in: headerSize..<headerSize + tokenLen)
    return tokenData == expectedToken.data(using: .utf8)
}

func decodeSamples(packet: SidecarPacket) -> [Int16]? {
    guard packet.payload.count % 2 == 0 else { return nil }

    let sampleCount = packet.payload.count / 2
    if sampleCount == 0 { return [] }

    var rawSamples = [Int16](repeating: 0, count: sampleCount)
    _ = rawSamples.withUnsafeMutableBytes { dst in
        packet.payload.copyBytes(to: dst)
    }

    for idx in 0..<rawSamples.count {
        rawSamples[idx] = Int16(littleEndian: rawSamples[idx])
    }

    if packet.channels <= 1 {
        return rawSamples
    }

    let ch = Int(packet.channels)
    if ch <= 0 { return nil }

    let frames = rawSamples.count / ch
    var mono = [Int16](repeating: 0, count: frames)
    for frame in 0..<frames {
        var sum = 0
        for c in 0..<ch {
            sum += Int(rawSamples[frame * ch + c])
        }
        mono[frame] = Int16(sum / ch)
    }

    return mono
}

let config = parseConfig()
let stats = Stats()
stats.startPrinter()

let selectedOutputDeviceID: AudioDeviceID?
if let outputDeviceName = config.outputDeviceName {
    if let device = findOutputDevice(named: outputDeviceName) {
        selectedOutputDeviceID = device.id
        print("[audio] using output device \(device.name) (no system default change)")
    } else {
        fputs("Output device not found: \(outputDeviceName)\n", stderr)
        let options = listOutputDeviceNames()
        if options.isEmpty {
            fputs("No output-capable audio devices were detected.\n", stderr)
        } else {
            fputs("Available output devices:\n", stderr)
            for name in options {
                fputs("- \(name)\n", stderr)
            }
        }
        exit(2)
    }
} else {
    selectedOutputDeviceID = nil
}

let player: AudioPlaybackEngine
do {
    player = try AudioPlaybackEngine(sampleRate: 48_000, outputDeviceID: selectedOutputDeviceID)
} catch {
    fputs("Failed to start audio engine: \(error.localizedDescription)\n", stderr)
    exit(1)
}

let receiver = UDPReceiver(port: config.port) { datagram in
    stats.onPacketReceived()

    guard validateToken(datagram, expectedToken: config.token) else {
        stats.onAuthFailure()
        return
    }

    guard let packet = parsePacket(datagram) else {
        stats.onMalformed()
        return
    }

    guard packet.version == 1 else {
        stats.onMalformed()
        return
    }

    guard let samples = decodeSamples(packet: packet) else {
        stats.onMalformed()
        return
    }

    if config.verbose {
        print("[packet] seq=\(packet.sequence) sr=\(packet.sampleRate) ch=\(packet.channels) frames=\(packet.frameCount) payload=\(packet.payload.count)")
    }

    stats.onDecoded(sequence: packet.sequence)
    stats.onFramesPlayed(samples.count)
    player.enqueue(samples: samples, sampleRate: Double(packet.sampleRate))
}

do {
    try receiver.start()
} catch {
    fputs("Failed to start UDP receiver: \(error.localizedDescription)\n", stderr)
    exit(1)
}

dispatchMain()
