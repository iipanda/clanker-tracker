import Darwin
import Foundation

/// Captures credential commands without blocking a Swift executor or a Foundation run loop.
/// Process exit and pipe EOF are separate: a descendant can keep stdout open after its parent exits.
enum CommandRunner {
    static func run(_ path: String, _ arguments: [String], timeout: TimeInterval) async -> Data? {
        await withCheckedContinuation { continuation in
            let command = Execution(continuation: continuation)
            command.queue.async { command.start(path, arguments, timeout: timeout) }
        }
    }

    // All mutable state is confined to queue, including termination and timeout callbacks.
    private final class Execution: @unchecked Sendable {
        let queue = DispatchQueue(label: "io.github.iipanda.clankertracker.command", qos: .utility)
        private let process = Process()
        private let pipe = Pipe()
        private var continuation: CheckedContinuation<Data?, Never>?
        private var reader: (any DispatchSourceRead)?
        private var deadline: DispatchWorkItem?
        private var output = Data()
        private var exited = false
        private var eof = false

        init(continuation: CheckedContinuation<Data?, Never>) {
            self.continuation = continuation
        }

        func start(_ path: String, _ arguments: [String], timeout: TimeInterval) {
            let fd = pipe.fileHandleForReading.fileDescriptor
            let flags = fcntl(fd, F_GETFL)
            guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else {
                finish(nil)
                return
            }
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            // The reader retains this execution until completion cancels it.
            source.setEventHandler { self.readAvailable(fd) }
            source.setCancelHandler { [pipe] in try? pipe.fileHandleForReading.close() }
            reader = source
            source.resume()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = arguments
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { [self] _ in
                self.queue.async {
                    self.exited = true
                    self.completeIfReady()
                }
            }
            do {
                try process.run()
                try pipe.fileHandleForWriting.close()
            } catch {
                stop()
                finish(nil)
                return
            }
            let deadline = DispatchWorkItem { [weak self] in
                guard let self, self.continuation != nil else { return }
                self.stop()
                self.finish(nil)
            }
            self.deadline = deadline
            queue.asyncAfter(deadline: .now() + max(0, timeout), execute: deadline)
        }

        private func readAvailable(_ fd: Int32) {
            var bytes = [UInt8](repeating: 0, count: 16_384)
            // Yield to the timeout even if a command writes continuously.
            for _ in 0..<64 where continuation != nil {
                let count = Darwin.read(fd, &bytes, bytes.count)
                if count > 0 {
                    output.append(contentsOf: bytes.prefix(count))
                } else if count == 0 {
                    eof = true
                    reader?.setEventHandler {}
                    reader?.cancel()
                    completeIfReady()
                    return
                } else if errno == EINTR {
                    continue
                } else if errno == EAGAIN || errno == EWOULDBLOCK {
                    return
                } else {
                    stop()
                    finish(nil)
                    return
                }
            }
        }

        private func completeIfReady() {
            guard continuation != nil, exited else { return }
            if process.terminationReason != .exit || process.terminationStatus != 0 {
                finish(nil)
            } else if eof {
                finish(output)
            }
        }

        private func stop() {
            guard process.isRunning else { return }
            process.terminate()
            // SIGTERM is advisory; the caller's deadline must also cover commands that ignore it.
            queue.asyncAfter(deadline: .now() + 1) { [process] in
                if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
            }
        }

        private func finish(_ result: Data?) {
            guard let continuation else { return }
            self.continuation = nil
            process.terminationHandler = nil
            deadline?.cancel()
            deadline = nil
            reader?.setEventHandler {}
            reader?.cancel()
            reader = nil
            try? pipe.fileHandleForWriting.close()
            continuation.resume(returning: result)
        }
    }
}
