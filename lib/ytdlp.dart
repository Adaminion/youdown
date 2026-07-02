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
      if (audio) ...['-x', '--audio-format', audioFormat, '--audio-quality', '0'],
      // YouTube login: an exported cookies.txt wins over live browser cookies.
      if (cookieFile != null) ...['--cookies', cookieFile]
      else if (cookieBrowser != null) ...['--cookies-from-browser', cookieBrowser],
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

    item.status = DownloadStatus.downloading;
    item.progress = 0;
    item.error = null;
    onUpdate();

    final args = buildArgs(
      url: item.url,
      kind: item.kind,
      outTemplate: '$dir${Platform.pathSeparator}%(title)s.%(ext)s',
      height: height,
      audioFormat: audioFormat,
      cookieBrowser: cookieBrowser,
      cookieFile: cookieFile,
    );

    String? finalFile;
    final errBuffer = <String>[];

    try {
      final proc = await Process.start(bin, args, workingDirectory: dir);

      proc.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((line) {
        if (line.startsWith('YDFILE\t')) {
          finalFile = line.substring('YDFILE\t'.length).trim();
        }
        _maybeProgress(line, item, onUpdate);
      });

      proc.stderr
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((line) {
        _maybeProgress(line, item, onUpdate);
        if (!line.startsWith('YDPROG')) {
          errBuffer.add(line);
          if (errBuffer.length > 40) errBuffer.removeAt(0);
        }
      });

      final code = await proc.exitCode;
      if (code == 0) {
        await _applyMetadata(item, finalFile);
        item.progress = 1.0;
        item.status = DownloadStatus.done;
      } else {
        item.status = DownloadStatus.failed;
        item.error = summarizeError(
          errBuffer,
          cookieBrowser: cookieBrowser,
          loginConfigured: cookieBrowser != null || cookieFile != null,
        );
      }
    } catch (e) {
      item.status = DownloadStatus.failed;
      item.error = e.toString();
    }
    onUpdate();
  }

  void _maybeProgress(String line, DownloadItem item, void Function() onUpdate) {
    if (!line.startsWith('YDPROG')) return;
    final parts = line.split('\t');
    if (parts.length < 4) return;
    final done = double.tryParse(parts[1]);
    final total = double.tryParse(parts[2]) ??
        double.tryParse(parts[3]); // estimate fallback
    if (done != null && total != null && total > 0) {
      final p = (done / total).clamp(0.0, 1.0);
      if ((p - item.progress).abs() >= 0.005 || p >= 1.0) {
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
        item.uploader = (j['uploader'] ??
                j['channel'] ??
                j['extractor_key'] ??
                j['webpage_url_domain']) as String?;
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
  }) {
    final errors = err.where((l) => l.contains('ERROR')).toList();
    var msg = errors.isNotEmpty
        ? errors.last.replaceFirst(RegExp(r'^.*ERROR:\s*'), '')
        : (err.isNotEmpty ? err.last : 'Download failed');

    // Chromium locks its cookie DB while running, so live extraction fails.
    if (msg.contains('Could not copy') && msg.contains('cookie database')) {
      final b = cookieBrowser ?? 'the browser';
      return 'Could not read $b cookies — close $b completely and retry, '
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
    // Auth-shaped failures: point at the Login setting if it's off.
    if (!loginConfigured &&
        (msg.contains('Private video') ||
            msg.contains('Sign in') ||
            msg.contains('members-only') ||
            msg.contains('age-restricted') ||
            msg.contains('not available'))) {
      msg = '$msg — if this video needs your account, set Login in the toolbar.';
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
