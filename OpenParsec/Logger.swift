import Foundation

final class Logger {
	private static let logsFolderName = "Logs"
	private static let logFileName = "OpenParsec.log"

	private static var logsDirectoryURL: URL {
		let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
		return docs.appendingPathComponent(logsFolderName, isDirectory: true)
	}

	private static var logFileURL: URL {
		logsDirectoryURL.appendingPathComponent(logFileName)
	}

	static func setupIfNeeded() {
		if !FileManager.default.fileExists(atPath: logsDirectoryURL.path) {
			try? FileManager.default.createDirectory(at: logsDirectoryURL, withIntermediateDirectories: true)
		}
		if !FileManager.default.fileExists(atPath: logFileURL.path) {
			FileManager.default.createFile(atPath: logFileURL.path, contents: nil)
		}
	}

	static func log(_ message: String) {
		let ts = ISO8601DateFormatter().string(from: Date())
		let line = "[\(ts)] \(message)\n"
		if let data = line.data(using: .utf8) {
			if let handle = try? FileHandle(forWritingTo: logFileURL) {
				handle.seekToEndOfFile()
				handle.write(data)
				try? handle.close()
			}
		}
	}
}


