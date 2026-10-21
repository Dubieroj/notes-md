import CoreServices
import Foundation

/// FSEvents for a whole folder tree: new, changed, renamed and deleted files anywhere
/// inside, delivered on the main queue.
public final class DirectoryWatcher {
    private var stream: FSEventStreamRef?
    private let callback: ([String]) -> Void

    public init?(url: URL, latency: TimeInterval = 0.3, callback: @escaping ([String]) -> Void) {
        self.callback = callback
        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let flags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer)
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            { _, info, count, paths, _, _ in
                guard let info else { return }
                let watcher = Unmanaged<DirectoryWatcher>.fromOpaque(info).takeUnretainedValue()
                let list = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as? [String] ?? []
                watcher.callback(Array(list.prefix(count)))
            },
            &context, [url.path] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, flags)
        else { return nil }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
    }

    public func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    deinit { stop() }
}
