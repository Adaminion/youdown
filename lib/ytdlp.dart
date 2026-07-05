import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:path_provider/path_provider.dart';

import 'models.dart';

/// Strips playlist/tracking baggage off a video URL so yt-dlp downloads
/// exactly one video. YouTube `watch` URLs are reduced to just their `v` id,
/// `youtu.be` short links are expanded, and shorts/live/embed paths lose their
/// query string. Non-YouTube URLs pass through unchanged.
String cleanVideoUrl(String url) {
  final uri = Uri.tryParse(url.trim());
  if (uri == null) return url;
  final host = uri.host.toLowerCase().replaceFirst(RegExp(r'^www\.'), '');

  if (host == 'youtu.be') {
    final id = uri.pathSegments.isNotEmpty ? uri.pathSegments.first : '';
    if (id.isNotEmpty) return 'https://www.youtube.com/watch?v=$id';
    return url;
  }

  if (host == 'youtube.com' ||
      host == 'm.youtube.com' ||
      host == 'music.youtube.com') {
    if (uri.path == '/watch') {
      final v = uri.queryParameters['v'];
      if (v != null && v.isNotEmpty) {
        return 'https://www.youtube.com/watch?v=$v';
      }
    }
    // Single-video path styles: drop query/tracking params entirely.
    for (final p in ['/shorts/', '/live/', '/embed/']) {
      if (uri.path.startsWith(p)) {
        return Uri.https(uri.host, uri.path).toString();
      }
    }
  }
  return url;
}

/// Wraps the bundled yt-dlp binary: extracts it to a writable location on first
/// use, then runs downloads and reports progress / metadata back into a
/// [DownloadItem].
class DownloadService {
  String? _binPath;
  String? _jsRuntime;
  bool _jsRuntimeResolved = false;

  /// Concurrent-download cap. Each download spawns yt-dlp + deno (+ ffmpeg);
  /// an unbounded fan-out from pasting many links floods the CPU and the UI.
  static const int maxConcurrent = 3;
  int _running = 0;
  final List<Completer<void>> _waiters = [];

  Future<void> _acquireSlot() {
    if (_running < maxConcurrent) {
      _running++;
      return Future.value();
    }
    final c = Completer<void>();
    _waiters.add(c);
    return c.future; // completed by _releaseSlot, slot ownership transfers
  }

  void _releaseSlot() {
    if (_waiters.isNotEmpty) {
      _waiters.removeAt(0).complete();
    } else {
      _running--;
    }
  }

  /// Finds a JS runtime spec (`deno:<path>`) for yt-dlp's YouTube extractor.
  ///
  /// Modern yt-dlp needs a JS runtime to solve YouTube's player challenges;
  /// without one most formats are missing and videos misreport as "not
  /// available". We resolve deno ourselves and pass `--js-runtimes`
  /// explicitly because the app's inherited PATH is stale when deno was
  /// installed after login (or the app was already running). Resolved once.
  Future<String?> findJsRuntime() async {
    if (_jsRuntimeResolved) return _jsRuntime;
    _jsRuntimeResolved = true;
    final env = Platform.environment;
    final home = env['USERPROFILE'] ?? env['HOME'] ?? '';
    final candidates = Platform.isWindows
        ? [
            '${env['LOCALAPPDATA']}\\Microsoft\\WinGet\\Links\\deno.exe',
            '$home\\.deno\\bin\\deno.exe',
          ]
        : [
            '$home/.deno/bin/deno',
            '/usr/local/bin/deno',
            '/opt/homebrew/bin/deno',
          ];
    for (final c in candidates) {
      if (await File(c).exists()) {
        return _jsRuntime = 'deno:$c';
      }
    }
    try {
      final r = await Process.run(Platform.isWindows ? 'where' : 'which', [
        'deno',
      ]);
      if (r.exitCode == 0) {
        final p = (r.stdout as String)
            .trim()
            .split(RegExp(r'[\r\n]+'))
            .first
            .trim();
        if (p.isNotEmpty) return _jsRuntime = 'deno:$p';
      }
    } catch (_) {}
    return null;
  }

  /// The asset key + extracted filename for the current platform.
  ({String asset, String name}) get _binaryFor {
    if (Platform.isWindows) {
      return (asset: 'assets/yt-dlp.exe', name: 'yt-dlp.exe');
    }
    if (Platform.isMacOS) {
      return (asset: 'assets/yt-dlp_macos', name: 'yt-dlp');
    }
    return (asset: 'assets/yt-dlp', name: 'yt-dlp');
  }

  /// Test hook: skip asset extraction and run this executable instead.
  @visibleForTesting
  set binaryOverride(String path) => _binPath = path;

  /// Copies the bundled binary out of the asset bundle (you can't exec assets
  /// directly) and returns its path. Cached after the first call.
  Future<String> ensureBinary() async {
    if (_binPath != null) return _binPath!;
    final support = await getApplicationSupportDirectory();
    final spec = _binaryFor;
    final out = File('${support.path}/${spec.name}');

    final data = await rootBundle.load(spec.asset);
    final bytes = data.buffer.asUint8List();

    // Re-extract only if missing or a different size (e.g. binary updated).
    if (!await out.exists() || await out.length() != bytes.length) {
      await out.writeAsBytes(bytes, flush: true);
      if (!Platform.isWindows) {
        await Process.run('chmod', ['+x', out.path]);
      }
    }
    _binPath = out.path;
    return out.path;
  }

  /// Builds the yt-dlp format selector.
  ///
  /// Video uses `bestvideo+bestaudio` (separate DASH streams merged by ffmpeg).
  /// This is required for anything above 360p: on YouTube the only *progressive*
  /// (single-file, muxed) streams top out at 360p, so a bare `best[ext=mp4]`
  /// silently caps quality there regardless of the requested height. Each
  /// selector falls back to a progressive `best` if merging isn't possible.
  String _formatSelector(MediaKind kind, int? height) {
    if (kind == MediaKind.audio) {
      // `/best` fallback: if no audio-only stream is listed, grab the best
      // muxed one — `-x` (always set for audio) extracts the audio from it.
      return 'bestaudio[ext=m4a]/bestaudio/best';
    }
    if (height == null) {
      return 'bestvideo[ext=mp4]+bestaudio[ext=m4a]/bestvideo+bestaudio/'
          'best[ext=mp4]/best';
    }
    return 'bestvideo[ext=mp4][height<=$height]+bestaudio[ext=m4a]/'
        'bestvideo[height<=$height]+bestaudio/'
        'best[ext=mp4][height<=$height]/best[height<=$height]/best';
  }

  /// Builds the full yt-dlp argument list. Split out from [run] so tests can
  /// verify it without spawning a process.
  @visibleForTesting
  List<String> buildArgs({
    required String url,
    required MediaKind kind,
    required String outTemplate,
    required int? height,
    String audioFormat = 'm4a',
    String? cookieBrowser,
    String? cookieFile,
    String? jsRuntime,
  }) {
    final audio = kind == MediaKind.audio;
    final mp3 = audio && audioFormat == 'mp3';
    return <String>[
      // Cleaned again here so retries of items added before URL cleaning
      // existed also drop their playlist baggage.
      cleanVideoUrl(url),
      '-o', outTemplate,
      '-f', mp3 ? 'bestaudio/best' : _formatSelector(kind, height),
      if (kind == MediaKind.video) ...['--merge-output-format', 'mp4'],
      // Audio is always run through -x: converts to mp3 when asked (not a
      // native YouTube format), and guarantees an audio file even when the
      // selector fell back to a muxed video stream. Already-m4a downloads
      // are left untouched by ffmpeg.
      if (audio) ...[
        '-x',
        '--audio-format',
        audioFormat,
        '--audio-quality',
        '0',
      ],
      if (jsRuntime != null) ...['--js-runtimes', jsRuntime],
      // YouTube login: an exported cookies.txt wins over live browser cookies.
      if (cookieFile != null) ...[
        '--cookies',
        cookieFile,
      ] else if (cookieBrowser != null) ...[
        '--cookies-from-browser',
        cookieBrowser,
      ],
      '--no-playlist',
      '--newline',
      '--progress',
      '--progress-template',
      'download:YDPROG\t%(progress.downloaded_bytes)s\t%(progress.total_bytes)s\t%(progress.total_bytes_estimate)s',
      '--write-info-json',
      '--write-thumbnail',
      '--no-mtime',
      '--print', 'after_move:YDFILE\t%(filepath)s',
    ];
  }

  /// Validates configured paths before spawning yt-dlp. A stale path (e.g. a
  /// cookies file on an unplugged drive) makes yt-dlp itself crash with a
  /// cryptic PyInstaller error, so fail fast with a message that names the
  /// problem instead.
  @visibleForTesting
  Future<String?> preflight({required String dir, String? cookieFile}) async {
    if (!await Directory(dir).exists()) {
      return 'Download folder not found: $dir — choose another under "Save to".';
    }
    if (cookieFile != null && !await File(cookieFile).exists()) {
      return 'Cookies file not found: $cookieFile — if it\'s on a removable '
          'drive, reconnect it, or re-select the file under Login.';
    }
    return null;
  }

  /// Runs the download, mutating [item] in place and calling [onUpdate] on every
  /// progress tick and on completion.
  Future<void> run(
    DownloadItem item, {
    required String dir,
    required int? height,
    String audioFormat = 'm4a',
    String? cookieBrowser,
    String? cookieFile,
    required void Function() onUpdate,
  }) async {
    final bin = await ensureBinary();

    final pathError = await preflight(dir: dir, cookieFile: cookieFile);
    if (pathError != null) {
      item.status = DownloadStatus.failed;
      item.error = pathError;
      onUpdate();
      return;
    }

    await _acquireSlot(); // caps simultaneous yt-dlp pipelines

    item.status = DownloadStatus.downloading;
    item.progress = 0;
    item.error = null;
    onUpdate();

    // yt-dlp can emit hundreds of progress lines per second; notifying the
    // UI for each one floods the event loop and freezes the app when several
    // downloads run at once. Progress is tracked on every line, but listener
    // notifications are rate-limited.
    var lastNotify = DateTime.fromMillisecondsSinceEpoch(0);
    void onProgressTick() {
      final now = DateTime.now();
      if (now.difference(lastNotify).inMilliseconds >= 150) {
        lastNotify = now;
        onUpdate();
      }
    }

    final jsRuntime = await findJsRuntime();

    String? finalFile;
    File? tmpCookies;
    final errBuffer = <String>[];

    try {
      // yt-dlp saves the cookie jar back to the file on exit; concurrent
      // downloads sharing one cookies.txt race each other (crashes/corrupted
      // file). Each run gets its own throwaway copy; the original is never
      // written to.
      var runCookieFile = cookieFile;
      if (cookieFile != null) {
        final support = await getApplicationSupportDirectory();
        tmpCookies = File('${support.path}/cookies_run_${item.id}.txt');
        await File(cookieFile).copy(tmpCookies.path);
        runCookieFile = tmpCookies.path;
      }

      final args = buildArgs(
        url: item.url,
        kind: item.kind,
        outTemplate: '$dir${Platform.pathSeparator}%(title)s.%(ext)s',
        height: height,
        audioFormat: audioFormat,
        cookieBrowser: cookieBrowser,
        cookieFile: runCookieFile,
        jsRuntime: jsRuntime,
      );
      final proc = await Process.start(bin, args, workingDirectory: dir);

      // allowMalformed: a single non-UTF8 byte in output must not kill the
      // listener (a dead listener blocks the pipe and hangs the download).
      final stdoutSub = proc.stdout
          .transform(const Utf8Decoder(allowMalformed: true))
          .transform(const LineSplitter())
          .listen((line) {
            if (line.startsWith('YDFILE\t')) {
              finalFile = line.substring('YDFILE\t'.length).trim();
            }
            _maybeProgress(line, item, onProgressTick);
          });

      final stderrSub = proc.stderr
          .transform(const Utf8Decoder(allowMalformed: true))
          .transform(const LineSplitter())
          .listen((line) {
            _maybeProgress(line, item, onProgressTick);
            if (!line.startsWith('YDPROG')) {
              errBuffer.add(line);
              if (errBuffer.length > 40) errBuffer.removeAt(0);
            }
          });

      // Capture the pipe-completion futures NOW, before awaiting exitCode:
      // the pipes usually close *before* exitCode resolves, and an asFuture()
      // attached after a stream is already done never completes — the item
      // would hang at "downloading" forever and leak its download slot.
      final stdoutDone = stdoutSub.asFuture<void>().catchError((_) {});
      final stderrDone = stderrSub.asFuture<void>().catchError((_) {});

      final code = await proc.exitCode;
      // Drain remaining buffered lines (the YDFILE path arrives here). The
      // timeout is a safety net for a child process holding the pipes open
      // after yt-dlp itself exited.
      await Future.wait([stdoutDone, stderrDone]).timeout(
        const Duration(seconds: 10),
        onTimeout: () {
          stdoutSub.cancel();
          stderrSub.cancel();
          return const <void>[];
        },
      );
      if (code == 0) {
        await _applyMetadata(item, finalFile);
        final onDisk =
            item.filePath != null && await File(item.filePath!).exists();
        if (onDisk) {
          item.progress = 1.0;
          item.status = DownloadStatus.done;
          item.fileMissing = false;
        } else {
          // exit 0 but nothing to show: don't claim success over a missing file.
          item.status = DownloadStatus.failed;
          item.error =
              'Finished, but no output file was found in $dir — check free '
              'space and retry.';
        }
      } else {
        item.status = DownloadStatus.failed;
        item.error = summarizeError(
          errBuffer,
          cookieBrowser: cookieBrowser,
          loginConfigured: cookieBrowser != null || cookieFile != null,
          jsRuntimeMissing: jsRuntime == null,
        );
      }
    } catch (e) {
      item.status = DownloadStatus.failed;
      item.error = e.toString();
    } finally {
      _releaseSlot();
      try {
        await tmpCookies?.delete();
      } catch (_) {}
    }
    onUpdate();
  }

  void _maybeProgress(
    String line,
    DownloadItem item,
    void Function() onUpdate,
  ) {
    if (!line.startsWith('YDPROG')) return;
    final parts = line.split('\t');
    if (parts.length < 4) return;
    final done = double.tryParse(parts[1]);
    final total =
        double.tryParse(parts[2]) ??
        double.tryParse(parts[3]); // estimate fallback
    if (done != null && total != null && total > 0) {
      final p = (done / total).clamp(0.0, 1.0);
      // No `p >= 1.0` shortcut here: fragmented downloads sit at 100% for
      // many lines and would fire an update per line. Completion is
      // reported once via the exit path.
      if ((p - item.progress).abs() >= 0.005) {
        item.progress = p;
        onUpdate();
      }
    }
  }

  /// Reads the `.info.json` yt-dlp wrote next to the media file and fills in the
  /// item's metadata + thumbnail path.
  Future<void> _applyMetadata(DownloadItem item, String? finalFile) async {
    if (finalFile == null) return;
    item.filePath = finalFile;

    final media = File(finalFile);
    if (await media.exists()) {
      item.fileSizeBytes = await media.length();
      item.ext = _ext(finalFile);
    }

    final base = _stripExt(finalFile);
    final info = File('$base.info.json');
    if (await info.exists()) {
      try {
        final j = jsonDecode(await info.readAsString()) as Map<String, dynamic>;
        item.title = j['title'] as String? ?? item.title;
        item.durationSeconds = (j['duration'] as num?)?.round();
        item.height = (j['height'] as num?)?.toInt();
        item.fps = (j['fps'] as num?)?.toDouble();
        item.uploader =
            (j['uploader'] ??
                    j['channel'] ??
                    j['extractor_key'] ??
                    j['webpage_url_domain'])
                as String?;
      } catch (e) {
        debugPrint('info.json parse failed: $e');
      }
    }

    // Thumbnail: yt-dlp writes `<base>.<imgext>`.
    for (final e in ['jpg', 'webp', 'png', 'jpeg']) {
      final t = File('$base.$e');
      if (await t.exists()) {
        item.thumbnailPath = t.path;
        break;
      }
    }
  }

  /// Turns raw yt-dlp stderr into a one-line, actionable message.
  @visibleForTesting
  String summarizeError(
    List<String> err, {
    String? cookieBrowser,
    bool loginConfigured = false,
    bool jsRuntimeMissing = false,
  }) {
    final errors = err.where((l) => l.contains('ERROR')).toList();
    var msg = errors.isNotEmpty
        ? errors.last.replaceFirst(RegExp(r'^.*ERROR:\s*'), '')
        : (err.isNotEmpty ? err.last : 'Download failed');

    // A PyInstaller bootloader line ("[PYI-…] Failed to execute script")
    // means yt-dlp itself crashed; the real Python exception is a few lines
    // up in the traceback — show that instead.
    if (msg.contains('Failed to execute script')) {
      final exc = err.lastWhere(
        (l) => RegExp(r'^\s*\w+(Error|Exception)\b').hasMatch(l),
        orElse: () => '',
      );
      msg = exc.isNotEmpty
          ? 'yt-dlp crashed: ${exc.trim()}'
          : 'yt-dlp crashed unexpectedly — check that the download folder '
                'and cookies file paths still exist.';
    }

    // Without a JS runtime yt-dlp misses most YouTube formats and even
    // misreports videos as unavailable. Point at the actual fix.
    if (jsRuntimeMissing &&
        (msg.contains('not available') || msg.contains('Requested format'))) {
      return '$msg — no JS runtime found; install Deno '
          '(winget install DenoLand.Deno) and retry.';
    }

    // Chromium locks its cookie DB while running, so live extraction fails.
    // "Closing the window" is usually not enough: Chrome/Edge keep background
    // processes alive that hold the lock.
    if (msg.contains('Could not copy') && msg.contains('cookie database')) {
      final b = cookieBrowser ?? 'the browser';
      return 'Could not read $b cookies — close $b completely (also its '
          'background processes: system tray icon / Task Manager) and retry, '
          'or switch Login to a cookies.txt file.';
    }
    // Chrome/Edge App-Bound Encryption: yt-dlp often can't decrypt live
    // Chromium cookies on Windows. A cookies.txt export is the reliable path.
    if (msg.contains('DPAPI') || msg.contains('Failed to decrypt')) {
      final b = cookieBrowser ?? 'browser';
      return "Couldn't decrypt $b cookies (Chrome/Edge encryption). Switch "
          'Login to a cookies.txt file exported with a "Get cookies.txt" '
          'browser extension.';
    }
    // App-bound (v20) cookies decrypt to garbage: yt-dlp only warns, then
    // YouTube rejects the login ("Sign in to confirm…"). Scan the whole
    // stderr tail for the decrypt warnings, not just the final ERROR line.
    final chromiumLogin = cookieBrowser == 'chrome' || cookieBrowser == 'edge';
    if (chromiumLogin &&
        (msg.contains('Sign in') || msg.contains('cookies')) &&
        err.any(
          (l) =>
              l.contains('v20') ||
              l.contains('decrypt') ||
              l.contains('App Bound') ||
              l.contains('app-bound'),
        )) {
      return "YouTube didn't accept $cookieBrowser cookies — Chrome/Edge "
          'encrypt them on Windows (app-bound encryption), even when the '
          'browser is closed. Switch Login to a cookies.txt file exported '
          'with a "Get cookies.txt" extension, or use Firefox.';
    }
    // Auth-shaped failures: point at the Login setting if it's off.
    if (!loginConfigured &&
        (msg.contains('Private video') ||
            msg.contains('Sign in') ||
            msg.contains('members-only') ||
            msg.contains('age-restricted') ||
            msg.contains('not available'))) {
      msg =
          '$msg — if this video needs your account, set Login in the toolbar.';
    }
    return msg;
  }
}

String _ext(String path) {
  final dot = path.lastIndexOf('.');
  final sep = path.lastIndexOf(RegExp(r'[/\\]'));
  return dot > sep ? path.substring(dot + 1) : '';
}

String _stripExt(String path) {
  final dot = path.lastIndexOf('.');
  final sep = path.lastIndexOf(RegExp(r'[/\\]'));
  return dot > sep ? path.substring(0, dot) : path;
}
