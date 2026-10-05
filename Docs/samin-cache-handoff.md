# Samin temp-cache / seamless playback — handoff

**Last Updated:** 2026-10-05  
**Branch:** `samin-temp-cache` (fork: `Saminahmed7/NuvioMobile`)  
**Latest Published Release:** **`samin-v0.5.6036-6036`** (Nuvio Samin 0.5.6036)  
**SideStore Source:** `https://raw.githubusercontent.com/Saminahmed7/NuvioMobile/samin-temp-cache/store-samin.json`  

---

## 0. Fixes released in Build 35 (0.5.6035 / 6035)

### A. Resume-from-position broken after app restart (FIXED)

**Symptom:** Watch part of a stream -> close app -> reopen -> tap the Continue Watching card ("x min left") -> pick a stream from the source list -> playback starts at 0:00 instead of the saved position.

**Root cause (iOS):** `PlayerEngine.ios.kt` fired `bridge.seekTo(resumePosition)` immediately after `loadFileWithAudio(...)`. But `loadFile` only *queues* the load - and in portrait it is deferred >= 0.9 s by the viewport-ready gate (`isViewportReadyForPlayback`) until the Metal view has laid out. mpv drops `seek <t> absolute` commands issued while no file is loaded, so the resume seek was silently discarded. The engine then reported the position as "handled" (`onInitialPositionHandled(key, true)`), which also disabled the Compose-level retry effect in `PlayerScreenRuntimeEffects`. On cold start (slower viewport attach + loopback proxy first open) the race was lost every time - matching the restart repro. This equally affected in-player source switches (fresh mpv instance per playback key).

**Fix:** The start position now travels with the load request and is applied at `MPV_EVENT_FILE_LOADED` - the same proven mechanism background recovery already uses:
- `PlayerBridge.kt`: `loadFileWithAudio(..., startPositionMs: Long = 0L)`.
- `PlayerEngine.ios.kt`: passes `startPositionMs` into the load; removed the dropped immediate seek.
- `MPVPlayerBridge.swift`: `PendingLoadRequest.startPositionMsSeconds`; `startLoad` queues `pendingResumePosition = request.startPositionMsSeconds` **only if nil** (recovery paths set it themselves right before `startLoad` and must win). The `FILE_LOADED` handler consumes it unchanged. `retryPlayback`'s delayed `time-pos` re-seek now only fires when `pos > 0.5` so a 0-position retry cannot clobber a still-pending initial resume.

### B. HLS buffering - Option B implemented (demuxer cache profile)

`startLoad` now applies a per-stream demuxer profile in `MPVPlayerViewController.applyDemuxerCacheProfile(for:)`:
- **HLS (.m3u8) / DASH (.mpd):** `demuxer-max-bytes = 256 MB`, `demuxer-max-back-bytes = 128 MB`, `demuxer-readahead-secs = 120` - mpv rides through upstream stalls entirely from RAM; also gives ~2 min of instant backward seek without re-fetching segments.
- **Progressive (loopback proxy / direct):** unchanged - 64 MB / 30 s from `setupMpv()`, `demuxer-max-back-bytes` left at the mpv default. The progressive disk cache in `LocalCacheProxy.swift` is untouched; each playback gets its own mpv instance, so profiles never leak across streams.

---

## 0b. HLS segment disk caching (Build 36, 0.5.6036)

**Goal (work-queue item #4, handoff "Option A"):** give HLS (.m3u8) the same
loopback disk cache experience progressive files already have - grey bar,
cached badge, instant replay of watched segments - without touching the
progressive byte-chunk path.

**Kotlin (TempPlaybackCache.kt):**
- New gates: `isAdaptivePlaylist()` (http(s) .m3u8) and
  `shouldProxy() = shouldMirror(url) || isAdaptivePlaylist(url)`.
- `resolveProxiedSource` now uses `shouldProxy`, so HLS startSession calls the
  proxy and returns `http://127.0.0.1:<port>/s/<key>/playlist`. The background
  mirror effect still gates on `shouldMirror`, so Android behavior is
  unchanged (and `NuvioCacheProxyBridgeFactory.create()` returns nil there
  anyway). DASH (.mpd) stays excluded (byte-range init segments unsupported).

**Swift (LocalCacheProxy.swift):**
- `ProxySessionKind` (`.progressive` / `.hls` / `.passThrough`); startSession
  picks the kind from the upstream URL and hands mpv `/playlist` for HLS.
- `HLSStreamState` per-session engine: fetches the playlist (follows one
  master -> best-bandwidth variant hop), parses it with a dependency-free
  parser, rewrites every segment/key/init URI to
  `/s/<key>/seg/<i>` / `key/<i>` / `map/<i>`, disk-caches each segment as
  `seg_<i>.bin` under the session dir, prefetches 8 segments ahead of the
  playhead, evicts watched segments only under the 300 MB low-space
  threshold, and parks/waiters loopback requests until their segment lands
  (3 s watchdog re-kick). Session teardown (`stopSession`, `stopAllSessions`,
  `invalidate`) reuses the existing directory deletion path unchanged.
- Graceful degradation: live playlists, `EXT-X-BYTERANGE`, unknown key
  methods, malformed playlists, or a failed initial playlist fetch all flip
  the session to pass-through, where `/playlist` answers 302 -> upstream
  playlist (exact pre-feature behavior, demuxer cache still active).
- Reporting: `cachedRangesJson` returns true time-domain spans (segment
  table), `cacheStatsJson` reports speed/cachedBytes/isComplete - so the
  grey bar, speed badge and Settings diagnostics light up for HLS with no
  UI changes. Diagnostics gained a per-session "Session kind" line plus HLS
  state lines (playlist host/status, segments cached, fetches in flight,
  parked waiters, master variant).

**MPVPlayerBridge.swift:** `applyDemuxerCacheProfile` also matches
`/playlist` (proxied HLS) so those sessions keep the 256 MB / 120 s demuxer
buffer; progressive defaults untouched.

**Known limits:** no persistence across sessions (same as progressive:
ephemeral by design), single-variant master playlists only (highest
bandwidth), AES-128 keys cached per-segment (shared keys refetched per
segment index - negligible size), and no byte-range map support (falls back
to redirect).

---

## 1. Where things stand right now

- **Build 34 (`0.5.6034 (6034)`) is LIVE and published**:
  - Built via GitHub Actions run [#37207867375](https://github.com/Saminahmed7/NuvioMobile/actions/runs/37207867375) (54m 25s, success).
  - Release tag: `samin-v0.5.6034-6034`, asset: `nuvio-samin-0.5.6034-full-release.ipa`.
  - SideStore repository JSON (`store-samin.json`) is updated on `samin-temp-cache`.
  - Fixes the versioning issue where SideStore/Settings showed stock `0.5.6 (138)`. Now explicitly displays `0.5.6034 (6034)` with distinct `"Nuvio Samin • Temp Playback Cache Engine"` branding.
  - Adds **Playback & Cache Diagnostics** directly to the main Settings menu under "About".
  - Keeps the cache speed & buffered amount badge permanently visible during progressive playback (`⚡ Cache Active` -> `↓ Speed · Cached` -> `✓ Cached`).
  - Scrubber grey bar contrast brightened to `Color(0.72f, 0.72f, 0.75f)` and wired into both modern and legacy player layouts.

- **Build 33 (`0.5.6033 (6033)`)**:
  - Published via run [#37194948849](https://github.com/Saminahmed7/NuvioMobile/actions/runs/37194948849).
  - Included Swift mutability fixes (`var sourceUrl`, `var headers`, `var headerNames` in `ProxySession`), Smart LRU eviction under low space (<300 MB), Step 2c cache preservation on debrid re-resolve, 15 s client timeout, and bridge offloading to `Dispatchers.IO`.

---

## 2. Root Cause Analysis: Versioning, SideStore, and Visibility in Build 33 vs 34

### A. Why "About" Showed `0.5.6 (138)`
1. In `composeApp/build.gradle.kts`, `releaseAppVersionName` was reading strictly from `iosApp/Configuration/Version.xcconfig`, which upstream bumped to `MARKETING_VERSION=0.5.6` and `CURRENT_PROJECT_VERSION=138`.
2. In CI (`.github/workflows/samin-sync-and-build.yml`), we previously avoided writing to `Version.xcconfig` so Gradle's 50-minute Kotlin Native cache wouldn't bust. `MARKETING_VERSION=0.5.6033` was passed *only to Xcode* via `XCODE_XCCONFIG_FILE`.
3. Consequently, SideStore and iOS saw the bundle as `0.5.6033`, but the internal Compose "About" screen in Settings rendered `AppVersionConfig.VERSION_NAME`, which was hardcoded to `0.5.6 (138)`. This led the user to believe official stock Nuvio had been installed.
4. **Fix in Build 34:** In `composeApp/build.gradle.kts`, `releaseAppVersionName` and `releaseAppVersionCode` now check:
   - Gradle properties `nuvio.app.versionName` / `nuvio.app.versionCode`
   - Environment variables `MARKETING_VERSION` / `SAMIN_BUILD`
   - Java `System.getenv(...)`
   - Fallback to `Version.xcconfig`
   Additionally, `scripts/build-ios-ipa.sh` exports `ORG_GRADLE_PROJECT_nuvio.app.versionName` and `ORG_GRADLE_PROJECT_nuvio.app.versionCode`.

### B. Why SideStore Installed Build 33 Instead of 34
1. Build numbers are calculated dynamically in CI via:
   `SAMIN_REV="$(( $(gh api "repos/${GITHUB_REPOSITORY}/releases" --jq '[.[] | select(.tag_name | startswith("samin-v"))] | length') + 1 ))"`
2. Prior to the completed release of Build 33, exactly 32 releases existed, so the CI computed $32 + 1 = 33$ (`0.5.6033`).
3. Now that Release 33 exists on GitHub, CI computed $33 + 1 = 34$ (`0.5.6034`). SideStore sees `0.5.6034 > 0.5.6033` and cleanly prompts to overwrite the app on iPad.

### C. Why Cache Indicators Were Missing: The HLS Factor
1. **Stream Type Distinction:**
   - **Progressive HTTP (MP4 / MKV):** Supported. `TempPlaybackCache` routes the stream through `127.0.0.1:19842`, saves 2 MB sequential chunks (`c0.bin`, `c1.bin`), renders the grey bar on the scrubber, and displays the speed/size badge.
   - **HLS (`.m3u8`):** Bypassed by design in `TempPlaybackCache.shouldMirror(url)`. HLS is a plain text playlist file linking to hundreds of 2–6 second video segments (`.ts` / `.m4s`). Feeding an `.m3u8` to the single-file chunk proxy caused it to treat the 1 KB text file as the whole video. Thus, playing an HLS stream caused the app to bypass the proxy entirely, rendering no grey bar or badge.
2. **Badge Persistence Fix:** In Build 34, `CacheStatsBadge` now displays `⚡ Cache Active` even before the first byte arrives or when paused, rather than disappearing when speed is 0.

---

## 3. The HLS Roadmap & Architecture Options

To support caching for HLS (`.m3u8`) streams:

### Option A: Local Reverse Proxy Segment Cache (Full Disk Cache)
Extend `LocalCacheProxy.swift`:
1. **Playlist Interception:** When MPV requests `master.m3u8`, the proxy downloads it from upstream and rewrites all variant and segment URLs to point to `http://127.0.0.1:19842/hls/<key>/seg_N.ts`.
2. **Segment Storage:** As MPV requests each segment, the proxy downloads and saves `seg_N.ts` to `Caches/nuvio_proxy/<key>/`.
3. **Prefetching:** A background task parses the playlist and pre-downloads the next 10–20 segments ahead of the playhead.
4. **Instant Replay:** Seeking back to an already-cached segment serves immediately from disk with zero network request.
5. **Timeline Grey Bar:** Total segments cached / total segments in playlist mapped to the scrubber.
6. **Cleanup:** Evicted on low disk space and deleted when player closes.

### Option B: MPV Large In-Memory & Demuxer Cache (Fastest, High Reliability, Battery Friendly)
Configure MPV options in `MPVPlayerBridge.swift` for HLS streams:
- `demuxer-max-bytes = 268435456` (256 MB RAM buffer)
- `demuxer-max-back-bytes = 134217728` (128 MB rewind buffer)
- `demuxer-readahead-secs = 120` (2 minutes ahead)
- **Advantages:** Eliminates buffering/stuttering on HLS without touching flash storage (saves iPad SSD write wear and battery), handles multi-bitrate/AES-128 HLS without complex playlist rewriting.

---

## 4. Build history: what each build changed, what it broke, what it fixed

| Release | Date | Player/cache content | Note |
|---|---|---|---|
| **0.5.6034** | **10-04** | `dbf22d2c` **Build 34**: Wire `MARKETING_VERSION` & `SAMIN_BUILD` into `AppVersionConfig.kt`; add explicit "Nuvio Samin • Temp Playback Cache Engine" branding and "Playback & Cache Diagnostics" to Settings; make `CacheStatsBadge` persistent (`⚡ Cache Active` fallback) with cyan download tint; brightened `SavedTrackGray` to `0.72` and added grey bar support to legacy player layout. | **LIVE on SideStore** (Run `#37207867375`, 54m) |
| **0.5.6033** | **10-04** | `592247f4` fix Swift mutability (`var sourceUrl`, `headers`, `headerNames`); `becc64b8` Step 2c preserve cache on re-resolve; `c6caa3aa` align low-space 300 MB; `1bdb4312` parked client 15s timeout; `2a9830b0` bridge calls offloaded to `Dispatchers.IO`. | Released in CI (`37194948849`, 1h02m) |
| 0.5.6032 | 10-03 | `b273fb7a` keep forward downloader running during pause; backward-seek re-anchor, adaptive 32→128 MB window, skip cached runs, wire `streamPos`. | |
| 0.5.6031 | 10-03 | `4aaafd49` seek fixes, pause-aware battery, grey bar via MPV stream-pos, MPV readahead cache re-added. | |
| 0.5.6030 | 10-03 | `2cdcbea9` rate-limit backoff (429/503 + `Retry-After`), foreground debounce, grey-bar byte↔time map. | |
| 0.5.6029 | 10-03 | `c164cd6d` fixed loopback port 19842, sleep-aware clock `saminNow()`, `probeAccepting()`, diagnostics report. | |

---

## 5. Current Priority Work Queue

| # | Item | Status | Notes |
|---|------|--------|-------|
| 1 | **Verify Build 34 on iPad** | **Ready for user test** | Install `0.5.6034` via SideStore. Verify "About" shows `0.5.6034 (6034)` and test progressive stream (debrid MP4/MKV) for grey bar + speed badge. |
| 2 | **HLS Buffering Optimization (Option B)** | **Shipped in 6035** | Demuxer profile in `MPVPlayerBridge.swift`: HLS/DASH get 256 MB / 120 s (now also matches proxied `/playlist` URLs); progressive untouched. |
| 3 | **Resume-from-position after restart** | **Shipped in 6035** | Seek now applied at `MPV_EVENT_FILE_LOADED` via `startPositionMs` in the load request. Test: watch 10 min -> kill app -> Continue Watching -> pick stream -> must resume. |
| 4 | **HLS Segment Disk Caching (Option A)** | **Shipped in 6036** | `HLSStreamState` in `LocalCacheProxy.swift`: playlist rewrite + segment disk cache + prefetch; `/playlist` 302 redirect fallback for live/BYTERANGE/unsupported playlists. Test: HLS source -> grey bar + badge, instant replay of watched segments, diagnostics show 'Session kind: HLS segment cache'. |
