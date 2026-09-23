import CoreServices
import Foundation

/// Watches directory trees with FSEvents and reports the paths of changed files.
public final class FileWatcher: @unchecked Sendable {
    private let paths: [String]
    private let latency: CFTimeInterval
    private let handler: @Sendable ([String]) -> Void
    private let queue = DispatchQueue(label: "io.github.iipanda.clankertracker.fsevents")
    private var stream: FSEventStreamRef?

    public init(paths: [String], latency: CFTimeInterval = 1, handler: @escaping @Sendable ([String]) -> Void) {
        self.paths = paths
        self.latency = latency
        self.handler = handler
    }

    deinit { stop() }

    public func start() {
        guard stream == nil else { return }
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, count, eventPaths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<FileWatcher>.fromOpaque(info).takeUnretainedValue()
            let array = unsafeBitCast(eventPaths, to: NSArray.self)
            let changed = (0..<count).compactMap { array[$0] as? String }
            if !changed.isEmpty { watcher.handler(changed) }
        }
        let flags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer)
        guard let s = FSEventStreamCreate(
            kCFAllocatorDefault, callback, &context, paths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, flags
        ) else { return }
        FSEventStreamSetDispatchQueue(s, queue)
        FSEventStreamStart(s)
        stream = s
    }

    public func stop() {
        guard let s = stream else { return }
        FSEventStreamStop(s)
        FSEventStreamInvalidate(s)
        FSEventStreamRelease(s)
        stream = nil
    }
}
