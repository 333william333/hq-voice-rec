import Synchronization

/// Lock-free single-producer / single-consumer sample FIFO.
/// The producer is the real-time CoreAudio thread, the consumer the processing queue.
final class RingBuffer: @unchecked Sendable {
    let capacity: Int
    private let storage: UnsafeMutablePointer<Float>
    private let head = Atomic<Int>(0)   // total samples written
    private let tail = Atomic<Int>(0)   // total samples read
    let dropped = Atomic<Int>(0)

    init(capacity: Int) {
        self.capacity = capacity
        storage = .allocate(capacity: capacity)
        storage.initialize(repeating: 0, count: capacity)
    }

    deinit { storage.deallocate() }

    /// Real-time safe: no locks, no allocation.
    @discardableResult
    func write(_ source: UnsafePointer<Float>, count: Int) -> Bool {
        let h = head.load(ordering: .relaxed)
        let t = tail.load(ordering: .acquiring)
        guard capacity - (h - t) >= count else {
            dropped.wrappingAdd(count, ordering: .relaxed)
            return false
        }
        let start = h % capacity
        let first = min(count, capacity - start)
        (storage + start).update(from: source, count: first)
        if first < count { storage.update(from: source + first, count: count - first) }
        head.store(h + count, ordering: .releasing)
        return true
    }

    /// Reads up to `maxCount` samples, rounded down to a multiple of `granularity`.
    func read(into destination: UnsafeMutablePointer<Float>, maxCount: Int, granularity: Int = 1) -> Int {
        let t = tail.load(ordering: .relaxed)
        let h = head.load(ordering: .acquiring)
        var count = min(h - t, maxCount)
        count -= count % granularity
        guard count > 0 else { return 0 }
        let start = t % capacity
        let first = min(count, capacity - start)
        destination.update(from: storage + start, count: first)
        if first < count { (destination + first).update(from: storage, count: count - first) }
        tail.store(t + count, ordering: .releasing)
        return count
    }
}
