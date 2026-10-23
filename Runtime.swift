import Foundation
import AppKit

struct CommandResult {
    let status: Int32
    let output: String
    let timedOut: Bool
}

private final class CaptureBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes = Data()
    private var timeout = false
    func append(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        bytes.append(data)
        if bytes.count > 128_000 { bytes = bytes.suffix(128_000) }
    }
    func setTimeout() { lock.lock(); timeout = true; lock.unlock() }
    func result(_ status: Int32) -> CommandResult {
        lock.lock(); defer { lock.unlock() }
        return CommandResult(status: status, output: String(decoding: bytes, as: UTF8.self), timedOut: timeout)
    }
}

enum Command {
    // A bounded capture keeps streaming output from growing without limit.
    static func run(_ executable: String, _ arguments: [String], timeout: Double = 12) async -> CommandResult {
        await Task.detached {
            let process = Process(), pipe = Pipe(), capture = CaptureBuffer()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = pipe; process.standardError = pipe
            do {
                try process.run()
                let timer = DispatchSource.makeTimerSource(queue: .global())
                timer.schedule(deadline: .now() + timeout)
                timer.setEventHandler {
                    if process.isRunning {
                        capture.setTimeout(); process.terminate()
                        // A command which ignores SIGTERM must still finish its timeout.
                        DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
                            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                        }
                    }
                }
                timer.resume()
                while true {
                    let chunk = pipe.fileHandleForReading.availableData
                    if chunk.isEmpty { break }
                    capture.append(chunk)
                }
                process.waitUntilExit(); timer.cancel()
                return capture.result(process.terminationStatus)
            } catch { return CommandResult(status: -1, output: error.localizedDescription, timedOut: false) }
        }.value
    }
}

@MainActor final class ViewerProcess {
    private var process: Process?
    private var pipe: Pipe?
    private var fileTask: Task<Void, Never>?
    private var logFile: URL?
    private var logOffset: UInt64 = 0
    private var callback: ((String) -> Void)?
    private(set) var requestedStop = false
    var running: Bool { process?.isRunning == true }

    func start(executable: String, arguments: [String], output: @escaping (String) -> Void,
               completion: @escaping (Int32, Bool) -> Void) throws {
        guard process == nil else { throw NSError(domain: "LocalLink", code: 1, userInfo: [NSLocalizedDescriptionKey: "A viewer operation is already running."]) }
        let child = Process(), pipe = Pipe()
        requestedStop = false; logFile = nil; logOffset = 0; callback = output
        child.executableURL = URL(fileURLWithPath: executable)
        child.arguments = arguments
        child.standardInput = FileHandle.nullDevice
        child.standardOutput = pipe; child.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { handle.readabilityHandler = nil; return }
            let text = String(decoding: data, as: UTF8.self)
            Task { @MainActor [weak self] in self?.receive(text) }
        }
        child.terminationHandler = { [weak self] ended in
            Task { @MainActor [weak self] in
                guard let self, self.process === ended else { return }
                self.readLog()
                self.fileTask?.cancel(); self.fileTask = nil
                self.pipe?.fileHandleForReading.readabilityHandler = nil
                self.pipe = nil; self.process = nil; self.callback = nil
                completion(ended.terminationStatus, self.requestedStop)
            }
        }
        self.pipe = pipe; process = child
        do { try child.run() }
        catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            self.pipe = nil; process = nil; callback = nil
            throw error
        }
    }

    private func receive(_ text: String) {
        callback?(text)
        // The engine announces its own log path. Only read its bounded local log.
        for line in text.components(separatedBy: .newlines) {
            let prefix = "Redirecting log output to "
            guard line.hasPrefix(prefix) else { continue }
            let path = String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            let name = URL(fileURLWithPath: path).lastPathComponent
            guard name.range(of: "^Moonlight-[0-9]+\\.log$", options: .regularExpression) != nil,
                  path.hasPrefix("/tmp/") || path.hasPrefix("/private/") || path.hasPrefix(NSHomeDirectory() + "/Library/") else { continue }
            logFile = URL(fileURLWithPath: path); logOffset = 0
            fileTask?.cancel()
            fileTask = Task { [weak self] in
                while !Task.isCancelled {
                    self?.readLog()
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                }
            }
        }
    }
    private func readLog() {
        guard let url = logFile, let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }
        do {
            let end = try handle.seekToEnd()
            if end < logOffset { logOffset = 0 }
            if end > logOffset + 64_000 { logOffset = end - 64_000 }
            try handle.seek(toOffset: logOffset)
            let data = try handle.read(upToCount: 64_000) ?? Data()
            logOffset += UInt64(data.count)
            if !data.isEmpty { callback?(String(decoding: data, as: UTF8.self)) }
        } catch { /* Log availability does not control the viewer session. */ }
    }
    func stop() {
        guard let child = process, child.isRunning else { return }
        requestedStop = true
        child.terminate()
        Task { @MainActor [weak child] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if let child, child.isRunning { kill(child.processIdentifier, SIGKILL) }
        }
    }
    func activate() {
        guard let pid = process?.processIdentifier else { return }
        NSRunningApplication(processIdentifier: pid)?.activate(options: [])
    }
}
