import Foundation

// MARK: - Exact byte<->time timeline index (Samin)
//
// Plain-language version: a movie file is a notebook where the handwriting
// changes size. A minute of explosion takes many pages (megabytes); a minute
// of black screen takes few. The disk cache counts *pages* (byte offsets) but
// the timeline shows *minutes* (time), so drawing the grey "saved" bar needs a
// pages->minutes conversion. The old code guessed it by watching reading speed
// (a few observed time/byte pairs, straight lines drawn between them) — right
// near the playhead, wrong everywhere else, and frozen while buffering. Real
// files carry their own table of contents: Matroska (MKV/WebM) has "Cues"
// ("minute 42 starts at page 910") and MP4 has sample tables ("every chunk:
// starts at byte X, plays for Y seconds"). This module reads that table from
// the bytes already on disk and converts exactly, within one table entry.
//
// Technical notes:
// - MKV cues give (cluster file offset, timestamp). Clusters last a few
//   seconds each, so interpolation inside one entry is off by at most that.
// - MP4 sample tables give per-chunk (file offset, decode duration). Mapping
//   uses decode time; B-frame reorder (presentation vs decode) offsets of a
//   few frames are ignored — within ~100 ms, invisible on a progress bar.
// - Edit lists (elst) are ignored; files with large edits stay monotonic and
//   are off by at most a constant shift.
// - Fragmented MP4 (moof/mvex, no sample tables), MPEG-TS (no index by design)
//   and unknown containers fall back to the estimated anchor mapping —
//   nothing regresses.
// - Best-effort and additive: any failure returns .unsupported/.needMoreData
//   and the proxy behaves exactly as before. All calls run on the proxy
//   server queue; reads are small (headers/tables, never media payloads).

/// Exact media-time lookup table: sorted (file byte offset -> seconds) points.
struct MediaIndexTable {
    /// Sorted by byte ascending. Starts at (0, 0), ends at (totalSize, duration).
    let points: [(byte: Int64, seconds: Double)]
    let durationSec: Double
    /// Where the table came from, for diagnostics ("MKV cues", "MP4 sample table").
    let source: String

    /// Seconds for a file byte, interpolated between neighbouring entries.
    func fraction(forByte byte: Int64, totalSize: Int64) -> Double {
        guard durationSec > 0, totalSize > 0, points.count >= 2 else { return 0 }
        let b = min(max(byte, 0), totalSize)
        var lo = 0
        var hi = points.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if points[mid].byte <= b {
                lo = mid
            } else {
                hi = mid - 1
            }
        }
        let p = points[lo]
        if lo + 1 < points.count {
            let q = points[lo + 1]
            if q.byte > p.byte {
                let f = Double(b - p.byte) / Double(q.byte - p.byte)
                let s = p.seconds + f * (q.seconds - p.seconds)
                return min(max(s / durationSec, 0.0), 1.0)
            }
        }
        return min(max(p.seconds / durationSec, 0.0), 1.0)
    }
}

enum MediaIndexBuildResult {
    case ready(MediaIndexTable)
    /// Fetch these 2 MB chunk indices (index lives there), then retry.
    case needChunks([Int64])
    /// Front of the file is still downloading; retry when the cache grows.
    case needMoreData
    /// Give up for this session; keep the estimated mapping.
    case unsupported(String)
}

/// Random-access reader over the session's 2 MB chunk files (c<N>.bin).
/// Returns nil for any range touching a not-yet-cached byte.
struct MediaIndexReader {
    let dir: URL
    let chunkBytes: Int64
    let totalSize: Int64

    func read(offset: Int64, count: Int) -> Data? {
        guard offset >= 0, count > 0, offset < totalSize else { return nil }
        let end = min(offset + Int64(count), totalSize)
        var out = Data()
        out.reserveCapacity(Int(end - offset))
        var cursor = offset
        while cursor < end {
            let idx = cursor / chunkBytes
            let intra = cursor % chunkBytes
            let fileEnd = min((idx + 1) * chunkBytes, totalSize)
            let want = Int(min(end, fileEnd) - cursor)
            guard want > 0 else { return nil }
            let url = dir.appendingPathComponent("c\(idx).bin")
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
                  let size = (attrs[.size] as? NSNumber)?.int64Value,
                  size >= intra + Int64(want),
                  let h = try? FileHandle(forReadingFrom: url) else { return nil }
            do {
                try h.seek(toOffset: UInt64(intra))
                guard let piece = try h.read(upToCount: want), piece.count == want else {
                    try? h.close()
                    return nil
                }
                out.append(piece)
                try? h.close()
            } catch {
                try? h.close()
                return nil
            }
            cursor += Int64(want)
        }
        return out
    }
}

// MARK: - Little helpers (big-endian data, EBML vint, MP4 boxes)

private func miU32(_ d: Data, _ o: Int) -> UInt32? {
    guard o >= 0, o + 4 <= d.count else { return nil }
    var v: UInt32 = 0
    for i in 0..<4 { v = (v << 8) | UInt32(d[o + i]) }
    return v
}

private func miU64(_ d: Data, _ o: Int) -> UInt64? {
    guard o >= 0, o + 8 <= d.count else { return nil }
    var v: UInt64 = 0
    for i in 0..<8 { v = (v << 8) | UInt64(d[o + i]) }
    return v
}

private func miF32(_ d: Data, _ o: Int) -> Double? {
    guard let v = miU32(d, o) else { return nil }
    let f = Float(bitPattern: v)
    guard f.isFinite else { return nil }
    return Double(f)
}

private func miF64(_ d: Data, _ o: Int) -> Double? {
    guard let v = miU64(d, o) else { return nil }
    let f = Double(bitPattern: v)
    guard f.isFinite else { return nil }
    return f
}

private func miFloat(_ d: Data) -> Double? {
    if d.count == 4 { return miF32(d, 0) }
    if d.count == 8 { return miF64(d, 0) }
    return nil
}

private func miUInt(_ d: Data, _ o: Int, _ n: Int) -> UInt64? {
    guard n >= 0, n <= 8, o >= 0, o + n <= d.count else { return nil }
    var v: UInt64 = 0
    for i in 0..<n { v = (v << 8) | UInt64(d[o + i]) }
    return v
}

private func miAsciiZ(_ d: Data) -> String {
    var end = d.count
    for i in 0..<d.count where d[i] == 0 {
        end = i
        break
    }
    return String(bytes: d.prefix(end), encoding: .ascii) ?? ""
}

/// EBML ID at offset: value keeps the length-marker bits. Length 1...4.
private func miEbmlID(_ d: Data, _ o: Int) -> (value: UInt64, length: Int)? {
    guard o >= 0, o < d.count else { return nil }
    let first = d[o]
    var mask: UInt8 = 0x80
    var len = 1
    while len <= 4, first & mask == 0 {
        mask >>= 1
        len += 1
    }
    guard len <= 4, o + len <= d.count else { return nil }
    var v: UInt64 = 0
    for i in 0..<len { v = (v << 8) | UInt64(d[o + i]) }
    return (v, len)
}

/// EBML size at offset: value masks the marker out; nil means unknown size.
private func miEbmlSize(_ d: Data, _ o: Int) -> (value: UInt64?, length: Int)? {
    guard o >= 0, o < d.count else { return nil }
    let first = d[o]
    var mask: UInt8 = 0x80
    var len = 1
    while len <= 8, first & mask == 0 {
        mask >>= 1
        len += 1
    }
    guard len <= 8, o + len <= d.count else { return nil }
    var v: UInt64 = 0
    for i in 0..<len { v = (v << 8) | UInt64(d[o + i]) }
    let max: UInt64 = (UInt64(1) << (7 * len)) - 1
    v &= max
    if v == max { return (nil, len) }
    return (v, len)
}

/// Calls body for each EBML child in the buffer. Unknown-size tail = rest.
private func miForEachEBMLChild(_ d: Data, _ body: (UInt64, Data) -> Bool) {
    var o = 0
    var steps = 0
    while o < d.count, steps < 100_000 {
        steps += 1
        guard let (id, idLen) = miEbmlID(d, o),
              let (size, sizeLen) = miEbmlSize(d, o + idLen) else { return }
        let cs = o + idLen + sizeLen
        let clen = size.map(Int.init) ?? (d.count - cs)
        guard clen >= 0, cs + clen <= d.count else { return }
        if !body(id, d.subdata(in: cs..<(cs + clen))) { return }
        o = cs + clen // zero-size elements still advance past their header
        if size == nil { return }
    }
}

/// Calls body for each MP4 box in the buffer: (type, content).
private func miForEachMP4Box(_ d: Data, _ body: (UInt32, Data) -> Bool) {
    var o = 0
    var steps = 0
    while o + 8 <= d.count, steps < 10_000 {
        steps += 1
        guard let s32 = miU32(d, o), let type = miU32(d, o + 4) else { return }
        var hlen = 8
        var blen = UInt64(s32)
        if s32 == 1 {
            guard let l = miU64(d, o + 8), l >= 16 else { return }
            blen = l
            hlen = 16
        } else if s32 == 0 {
            blen = UInt64(d.count - o)
        }
        guard blen >= UInt64(hlen), blen <= UInt64(d.count - o) else { return }
        let cs = o + hlen
        let ce = o + Int(blen)
        if !body(type, d.subdata(in: cs..<ce)) { return }
        o = ce
    }
}

// MARK: - Builder

enum MediaIndexBuilder {
    static func build(dir: URL, chunkBytes: Int64, totalSize: Int64) -> MediaIndexBuildResult {
        guard totalSize > 0 else { return .needMoreData }
        let reader = MediaIndexReader(dir: dir, chunkBytes: chunkBytes, totalSize: totalSize)
        guard let magic = reader.read(offset: 0, count: 16) else {
            return .needChunks(chunksCovering(0..<16, chunkBytes: chunkBytes))
        }
        guard magic.count >= 8 else { return .needMoreData }
        if magic[0] == 0x1A, magic[1] == 0x45, magic[2] == 0xDF, magic[3] == 0xA3 {
            return buildMKV(reader: reader, totalSize: totalSize)
        }
        if magic[4] == 0x66, magic[5] == 0x74, magic[6] == 0x79, magic[7] == 0x70 { // "ftyp"
            return buildMP4(reader: reader, totalSize: totalSize)
        }
        if magic[0] == 0x47 { return .unsupported("MPEG-TS carries no index") }
        return .unsupported("unknown container")
    }

    static func chunksCovering(_ r: Range<Int64>, chunkBytes: Int64, cap: Int = 8) -> [Int64] {
        guard r.lowerBound < r.upperBound, chunkBytes > 0 else { return [] }
        let lo = max(r.lowerBound, 0) / chunkBytes
        let hi = max(r.upperBound - 1, 0) / chunkBytes
        let last = min(hi, lo + Int64(cap - 1))
        guard last >= lo else { return [] }
        return (lo...last).map { $0 }
    }

    // MARK: Matroska (MKV/WebM) via Cues

    private static func fileElementHeader(_ reader: MediaIndexReader, at offset: Int64)
        -> (id: UInt64, headLen: Int, size: UInt64?, dataStart: Int64)?
    {
        guard offset >= 0, offset < reader.totalSize else { return nil }
        guard let buf = reader.read(offset: offset, count: 12) else { return nil }
        guard let (id, idLen) = miEbmlID(buf, 0),
              let (size, sizeLen) = miEbmlSize(buf, idLen) else { return nil }
        return (id, idLen + sizeLen, size, offset + Int64(idLen + sizeLen))
    }

    private static func parseSeekHead(_ d: Data) -> [UInt64: UInt64] {
        var out: [UInt64: UInt64] = [:]
        miForEachEBMLChild(d) { id, c in
            guard id == 0x4DBB else { return true } // Seek
            var seekID: UInt64?
            var seekPos: UInt64?
            miForEachEBMLChild(c) { id2, c2 in
                if id2 == 0x53AB { seekID = miUInt(c2, 0, c2.count) } // SeekID bytes
                else if id2 == 0x53AC { seekPos = miUInt(c2, 0, c2.count) } // relative to Segment data
                return true
            }
            if let sid = seekID, let sp = seekPos { out[sid] = sp }
            return true
        }
        return out
    }

    private static func parseInfo(_ d: Data) -> (timescale: UInt64, durationSec: Double, ok: Bool) {
        var timescale: UInt64 = 1_000_000 // Matroska default: nanoseconds
        miForEachEBMLChild(d) { id, c in
            if id == 0x2AD7B1, let v = miUInt(c, 0, c.count), v > 0 { timescale = v }
            return true
        }
        var durationSec = 0.0
        var ok = false
        miForEachEBMLChild(d) { id, c in
            if id == 0x4489, let f = miFloat(c) {
                durationSec = f * Double(timescale) / 1_000_000_000.0
                ok = true
            }
            return true
        }
        return (timescale, durationSec, ok)
    }

    /// Raw cue ticks (CueTime is in TimestampScale units); scaled to seconds
    /// once the final timescale is known, so element order never matters.
    private static func parseCues(_ d: Data, segDataStart: Int64)
        -> [(byte: Int64, ticks: UInt64)]
    {
        var out: [(byte: Int64, ticks: UInt64)] = []
        miForEachEBMLChild(d) { id, c in
            guard id == 0xBB else { return true } // CuePoint
            var t: UInt64?
            var positions: [Int64] = []
            miForEachEBMLChild(c) { id2, c2 in
                if id2 == 0xB3, let v = miUInt(c2, 0, c2.count) { // CueTime
                    t = v
                } else if id2 == 0xB7 { // CueTrackPositions
                    miForEachEBMLChild(c2) { id3, c3 in
                        if id3 == 0xF1, let v = miUInt(c3, 0, c3.count) { // CueClusterPosition
                            positions.append(segDataStart + Int64(v))
                        }
                        return true
                    }
                }
                return true
            }
            if let t {
                for p in positions { out.append((byte: p, ticks: t)) }
            }
            return true
        }
        return out
    }

    private static func buildMKV(reader: MediaIndexReader, totalSize: Int64) -> MediaIndexBuildResult {
        guard let hdr = fileElementHeader(reader, at: 0) else {
            return .needChunks(chunksCovering(0..<12, chunkBytes: reader.chunkBytes))
        }
        guard hdr.id == 0x1A45DFA3 else { return .unsupported("not EBML") }
        guard let ebmlSize = hdr.size, ebmlSize <= 4 * 1024 * 1024 else {
            return .unsupported("bad EBML header")
        }
        let ebmlEnd = hdr.dataStart + Int64(ebmlSize)
        guard let ebml = reader.read(offset: hdr.dataStart, count: Int(ebmlSize)) else {
            return .needChunks(chunksCovering(hdr.dataStart..<(hdr.dataStart + Int64(ebmlSize)),
                                              chunkBytes: reader.chunkBytes))
        }
        var docType = ""
        miForEachEBMLChild(ebml) { id, c in
            if id == 0x4282 { docType = miAsciiZ(c); return false }
            return true
        }
        guard docType == "matroska" || docType == "webm" else {
            return .unsupported("not matroska (\(docType))")
        }
        guard ebmlEnd < totalSize else { return .needMoreData }
        guard let seg = fileElementHeader(reader, at: ebmlEnd) else {
            return .needChunks(chunksCovering(ebmlEnd..<(ebmlEnd + 12), chunkBytes: reader.chunkBytes))
        }
        guard seg.id == 0x18538067 else { return .unsupported("no Segment") } // Segment
        let segData = seg.dataStart
        let segEnd: Int64 = seg.size.map { min(seg.dataStart + Int64($0), totalSize) } ?? totalSize

        var seeks: [UInt64: UInt64] = [:]
        var timescale: UInt64 = 1_000_000
        var durationSec = 0.0
        var haveDuration = false
        var cueTicks: [(byte: Int64, ticks: UInt64)] = []
        var cursor = segData
        var steps = 0
        var missingRange: Range<Int64>?
        walk: while cursor < segEnd, steps < 5000 {
            steps += 1
            guard let eh = fileElementHeader(reader, at: cursor) else {
                missingRange = cursor..<(cursor + 12)
                break walk
            }
            let elEnd: Int64? = eh.size.map { eh.dataStart + Int64($0) }
            switch eh.id {
            case 0x114D9B74: // SeekHead
                guard let s = eh.size, s <= 2 * 1024 * 1024,
                      let dd = reader.read(offset: eh.dataStart, count: Int(s)) else {
                    missingRange = eh.dataStart..<(eh.dataStart + Int64(eh.size ?? 12))
                    break walk
                }
                for (k, v) in parseSeekHead(dd) { seeks[k] = v }
                cursor = eh.dataStart + Int64(s)
            case 0x1549A966: // Info
                guard let s = eh.size, s <= 1024 * 1024,
                      let dd = reader.read(offset: eh.dataStart, count: Int(s)) else {
                    missingRange = eh.dataStart..<(eh.dataStart + Int64(eh.size ?? 12))
                    break walk
                }
                let info = parseInfo(dd)
                timescale = info.timescale
                if info.ok { durationSec = info.durationSec; haveDuration = true }
                cursor = eh.dataStart + Int64(s)
            case 0x1C53BB6B: // Cues
                guard let s = eh.size, s <= 64 * 1024 * 1024,
                      let dd = reader.read(offset: eh.dataStart, count: Int(s)) else {
                    missingRange = eh.dataStart..<(eh.dataStart + Int64(eh.size ?? 12))
                    break walk
                }
                cueTicks += parseCues(dd, segDataStart: segData)
                cursor = eh.dataStart + Int64(s)
            case 0x1F43B675, 0xEC, 0xBF: // Cluster, Void, CRC-32: skip by size
                guard let e = elEnd, e > cursor, e <= segEnd else { break walk }
                cursor = e
            default:
                guard let e = elEnd, e > cursor, e <= segEnd else { break walk }
                cursor = e
            }
            _ = elEnd
        }

        // Prefer indexed jumps: the walk may have stopped at an unskippable
        // element while the real targets sit elsewhere. Info first, so the
        // timescale is final before cue ticks are scaled to seconds.
        if !haveDuration, let infoPos = seeks[0x1549A966] {
            let abs = segData + Int64(infoPos)
            if let ih = fileElementHeader(reader, at: abs), ih.id == 0x1549A966,
               let s = ih.size, s <= 1024 * 1024,
               let dd = reader.read(offset: ih.dataStart, count: Int(s))
            {
                let info = parseInfo(dd)
                timescale = info.timescale
                if info.ok { durationSec = info.durationSec; haveDuration = true }
            }
        }
        if cueTicks.isEmpty, let cuesPos = seeks[0x1C53BB6B] {
            let abs = segData + Int64(cuesPos)
            guard let ch = fileElementHeader(reader, at: abs) else {
                return .needChunks(chunksCovering(abs..<(abs + 12), chunkBytes: reader.chunkBytes))
            }
            if ch.id == 0x1C53BB6B, let s = ch.size, s <= 64 * 1024 * 1024 {
                guard let dd = reader.read(offset: ch.dataStart, count: Int(s)) else {
                    return .needChunks(chunksCovering(ch.dataStart..<(ch.dataStart + Int64(s)),
                                                      chunkBytes: reader.chunkBytes))
                }
                cueTicks = parseCues(dd, segDataStart: segData)
            }
        }
        if cueTicks.isEmpty {
            if let missing = missingRange {
                return .needChunks(chunksCovering(missing, chunkBytes: reader.chunkBytes))
            }
            return .unsupported("no cues")
        }
        let scale = Double(timescale) / 1_000_000_000.0
        let cuePoints: [(byte: Int64, seconds: Double)] =
            cueTicks.map { (byte: $0.byte, seconds: Double($0.ticks) * scale) }
        let dur = haveDuration && durationSec > 0 ? durationSec : cuePoints.map { $0.seconds }.max() ?? 0
        guard dur > 0 else { return .unsupported("no duration") }
        guard let table = cleaned(cuePoints, totalSize: totalSize, durationSec: dur, source: "MKV cues") else {
            return .unsupported("empty cues")
        }
        return .ready(table)
    }

    // MARK: MP4 via sample tables (moov)

    private struct MP4Track {
        var timescale: UInt64 = 0
        var durationSec: Double = 0
        var handler: UInt32 = 0
        var stts: [(count: UInt64, delta: UInt64)] = []
        var stsc: [(firstChunk: UInt64, perChunk: UInt64)] = []
        var constantSize: UInt64 = 0
        var sizes: [UInt64] = []
        var sampleCount: UInt64 = 0
        var offsets: [UInt64] = []
    }

    private static func parseMP4Track(_ trak: Data) -> MP4Track? {
        var track = MP4Track()
        var stbl: Data?
        miForEachMP4Box(trak) { type, c in
            if type == 0x6D646961 { // "mdia"
                miForEachMP4Box(c) { mtype, mc in
                    if mtype == 0x6D646864, mc.count >= 24 { // "mdhd"
                        let v = mc[0]
                        if v == 0 {
                            if let ts = miU32(mc, 12), let du = miU32(mc, 16), ts > 0 {
                                track.timescale = UInt64(ts)
                                track.durationSec = Double(du) / Double(ts)
                            }
                        } else if v == 1, mc.count >= 32 {
                            if let ts = miU32(mc, 20), let du = miU64(mc, 24), ts > 0 {
                                track.timescale = UInt64(ts)
                                track.durationSec = Double(du) / Double(ts)
                            }
                        }
                    } else if mtype == 0x68646C72, mc.count >= 12 { // "hdlr"
                        track.handler = miU32(mc, 8) ?? 0
                    } else if mtype == 0x6D696E66 { // "minf"
                        miForEachMP4Box(mc) { itype, ic in
                            if itype == 0x7374626C { stbl = ic; return false } // "stbl"
                            return true
                        }
                        return false
                    }
                    return true
                }
                return false
            }
            return true
        }
        guard let stbl else { return nil }
        miForEachMP4Box(stbl) { type, c in
            switch type {
            case 0x73747473 where c.count >= 8: // "stts"
                let n = Int(miU32(c, 4) ?? 0)
                guard c.count >= 8 + n * 8 else { return true }
                for i in 0..<min(n, 1_000_000) {
                    let cnt = UInt64(miU32(c, 8 + i * 8) ?? 0)
                    let del = UInt64(miU32(c, 8 + i * 8 + 4) ?? 0)
                    if cnt > 0 { track.stts.append((cnt, del)) }
                }
            case 0x73747363 where c.count >= 8: // "stsc"
                let n = Int(miU32(c, 4) ?? 0)
                guard c.count >= 8 + n * 12 else { return true }
                for i in 0..<min(n, 1_000_000) {
                    let fc = UInt64(miU32(c, 8 + i * 12) ?? 0)
                    let pc = UInt64(miU32(c, 8 + i * 12 + 4) ?? 0)
                    if fc > 0 { track.stsc.append((fc, pc)) }
                }
            case 0x7374737A where c.count >= 12: // "stsz"
                let uniform = UInt64(miU32(c, 4) ?? 0)
                let n = Int(miU32(c, 8) ?? 0)
                track.sampleCount = UInt64(n)
                if uniform > 0 {
                    track.constantSize = uniform
                } else {
                    guard c.count >= 12 + n * 4, n <= 10_000_000 else { return true }
                    track.sizes.reserveCapacity(n)
                    for i in 0..<n { track.sizes.append(UInt64(miU32(c, 12 + i * 4) ?? 0)) }
                }
            case 0x7374636F where c.count >= 8: // "stco"
                let n = Int(miU32(c, 4) ?? 0)
                guard c.count >= 8 + n * 4, n <= 10_000_000 else { return true }
                track.offsets.reserveCapacity(n)
                for i in 0..<n { track.offsets.append(UInt64(miU32(c, 8 + i * 4) ?? 0)) }
            case 0x636F3634 where c.count >= 8: // "co64"
                let n = Int(miU32(c, 4) ?? 0)
                guard c.count >= 8 + n * 8, n <= 10_000_000 else { return true }
                track.offsets.reserveCapacity(n)
                for i in 0..<n { track.offsets.append(miU64(c, 8 + i * 8) ?? 0) }
            default:
                break
            }
            return true
        }
        return track
    }

    private static func buildMP4(reader: MediaIndexReader, totalSize: Int64) -> MediaIndexBuildResult {
        // Walk top-level boxes by their headers only (mdat payload never read).
        var cursor: Int64 = 0
        var moovStart: Int64 = 0
        var moovSize: Int64 = 0
        var steps = 0
        while cursor < totalSize, steps < 4096 {
            steps += 1
            guard let h = reader.read(offset: cursor, count: 16) else {
                return .needChunks(chunksCovering(cursor..<(cursor + 16), chunkBytes: reader.chunkBytes))
            }
            guard h.count >= 8, let s32 = miU32(h, 0), let type = miU32(h, 4) else {
                return .unsupported("truncated box")
            }
            var hlen: Int64 = 8
            var blen: Int64
            if s32 == 1 {
                guard let l = miU64(h, 8), l >= 16, l <= UInt64(Int64.max) else {
                    return .unsupported("bad largesize")
                }
                blen = Int64(l)
                hlen = 16
            } else if s32 == 0 {
                blen = totalSize - cursor
            } else {
                guard s32 >= 8 else { return .unsupported("bad box size") }
                blen = Int64(s32)
            }
            guard blen > 0 else { return .unsupported("bad box") }
            if type == 0x6D6F6F76 { // "moov"
                moovStart = cursor + hlen
                moovSize = blen - hlen
                break
            }
            cursor += blen
        }
        guard moovSize > 0 else { return .unsupported("moov not found") }
        guard moovSize <= 128 * 1024 * 1024 else { return .unsupported("moov too large") }
        guard let moov = reader.read(offset: moovStart, count: Int(moovSize)) else {
            return .needChunks(chunksCovering(moovStart..<(moovStart + moovSize),
                                              chunkBytes: reader.chunkBytes))
        }
        var movieDurationSec = 0.0
        var tracks: [MP4Track] = []
        miForEachMP4Box(moov) { type, c in
            if type == 0x6D766864, c.count >= 24 { // "mvhd"
                let v = c[0]
                if v == 0 {
                    if let ts = miU32(c, 12), let du = miU32(c, 16), ts > 0 {
                        movieDurationSec = Double(du) / Double(ts)
                    }
                } else if v == 1, c.count >= 32 {
                    if let ts = miU32(c, 20), let du = miU64(c, 24), ts > 0 {
                        movieDurationSec = Double(du) / Double(ts)
                    }
                }
            } else if type == 0x7472616B { // "trak"
                if let t = parseMP4Track(c) { tracks.append(t) }
            }
            return true
        }
        // Prefer the video track; otherwise the first one carrying samples.
        let track = tracks.first { $0.handler == 0x76696465 && $0.sampleCount > 0 } // "vide"
            ?? tracks.first { $0.sampleCount > 0 }
        guard let track, track.timescale > 0, !track.offsets.isEmpty,
              !track.stts.isEmpty, !track.stsc.isEmpty else {
            return .unsupported("no sample tables (fragmented?)")
        }
        let movieDur = movieDurationSec > 0 ? movieDurationSec : track.durationSec
        guard movieDur > 0 else { return .unsupported("no duration") }
        // Walk MP4 chunks: one control point per chunk + final EOF point.
        var points: [(byte: Int64, seconds: Double)] = [(0, 0)]
        points.reserveCapacity(track.offsets.count + 1)
        var cum = 0.0
        var g: UInt64 = 0
        var sttsE = 0
        var sttsLeft = track.stts[0].count
        var stride = 1
        if track.offsets.count > 32768 { stride = (track.offsets.count + 32767) / 32768 }
        for i in 0..<track.offsets.count {
            var perChunk: UInt64 = 0
            for e in track.stsc where e.firstChunk <= UInt64(i + 1) { perChunk = e.perChunk }
            guard perChunk > 0, perChunk <= 100_000 else { return .unsupported("bad stsc") }
            let base = track.offsets[i]
            guard base < UInt64(totalSize) else { return .unsupported("bad stco") }
            if i % stride == 0 || i == track.offsets.count - 1 {
                points.append((Int64(base), min(cum, movieDur)))
            }
            for _ in 0..<perChunk {
                let sz: UInt64
                if track.constantSize > 0 {
                    sz = track.constantSize
                } else {
                    guard g < UInt64(track.sizes.count) else { return .unsupported("truncated stsz") }
                    sz = track.sizes[Int(g)]
                }
                _ = sz
                var delta: UInt64 = 0
                while sttsE < track.stts.count {
                    if sttsLeft > 0 {
                        delta = track.stts[sttsE].delta
                        sttsLeft -= 1
                        break
                    }
                    sttsE += 1
                    if sttsE < track.stts.count { sttsLeft = track.stts[sttsE].count }
                }
                guard sttsE < track.stts.count else { return .unsupported("truncated stts") }
                cum += Double(delta) / Double(track.timescale)
                g += 1
            }
        }
        points.append((totalSize, movieDur))
        guard let table = cleaned(points, totalSize: totalSize, durationSec: movieDur,
                                  source: "MP4 sample table") else {
            return .unsupported("empty sample table")
        }
        return .ready(table)
    }

    // MARK: Shared

    /// Sorts by byte, enforces non-decreasing time, pins (0,0) and EOF ends.
    private static func cleaned(_ pts: [(byte: Int64, seconds: Double)], totalSize: Int64,
                                durationSec: Double, source: String) -> MediaIndexTable?
    {
        guard durationSec > 0, totalSize > 0 else { return nil }
        var out: [(byte: Int64, seconds: Double)] = []
        out.reserveCapacity(pts.count)
        for p in pts.sorted(by: { $0.byte < $1.byte }) {
            guard p.byte >= 0, p.seconds.isFinite else { continue }
            let s = min(max(p.seconds, 0.0), durationSec)
            if let last = out.last {
                if p.byte == last.byte {
                    if s > last.seconds { out[out.count - 1] = (byte: p.byte, seconds: s) }
                    continue
                }
                if s < last.seconds { continue }
            }
            out.append((byte: p.byte, seconds: s))
        }
        if out.isEmpty { return nil }
        if out[0].byte > 0 { out.insert((byte: 0, seconds: 0.0), at: 0) }
        if out.last!.byte < totalSize { out.append((byte: totalSize, seconds: durationSec)) }
        guard out.count >= 2 else { return nil }
        return MediaIndexTable(points: out, durationSec: durationSec, source: source)
    }
}
