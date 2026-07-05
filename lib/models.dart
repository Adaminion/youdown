// Data model for YouDown.
//
// A DownloadItem is one row in the persistent library. Items are stored as
// JSON and survive across runs. Some fields are only known after a download
// finishes (size, duration, resolution...), so most are nullable.

enum MediaKind { video, audio }

enum DownloadStatus { queued, downloading, done, failed }

/// Quality is stored as a max video height in pixels. `null` means "best
/// available". Audio downloads ignore it.
class Quality {
  static const List<int?> options = [null, 2160, 1080, 720, 480, 360];

  static String label(int? height) {
    if (height == null) return 'Best';
    if (height == 2160) return '4K';
    return '${height}p';
  }
}

/// Audio output container/codec choices (yt-dlp `--audio-format`).
class AudioFormat {
  static const List<String> options = ['m4a', 'mp3'];
}

class DownloadItem {
  DownloadItem({
    required this.id,
    required this.url,
    required this.kind,
    this.title,
    this.filePath,
    this.thumbnailPath,
    this.durationSeconds,
    this.fileSizeBytes,
    this.ext,
    this.height,
    this.fps,
    this.uploader,
    this.status = DownloadStatus.queued,
    this.error,
    this.progress = 0.0,
    DateTime? addedAt,
  }) : addedAt = addedAt ?? DateTime.now();

  final String id;
  final String url;
  MediaKind kind;

  String? title;
  String? filePath;
  String? thumbnailPath;
  int? durationSeconds;
  int? fileSizeBytes;
  String? ext; // mp4, m4a, webm...
  int? height; // 720, 1080...
  double? fps;
  String? uploader; // channel / site
  DownloadStatus status;
  String? error;

  /// 0.0 .. 1.0, transient while [status] is downloading.
  double progress;

  /// Transient (not persisted): set at startup when a 'done' item's file no
  /// longer exists on disk, so the UI can say so instead of claiming success.
  bool fileMissing = false;

  final DateTime addedAt;

  String get displayTitle =>
      title?.trim().isNotEmpty == true ? title!.trim() : url;

  /// Human-readable second line, e.g. "00:42 · 6.1 MB · MP4 · 720p · 30fps · channel".
  String get subtitle {
    final parts = <String>[];
    if (durationSeconds != null) parts.add(_formatDuration(durationSeconds!));
    if (fileSizeBytes != null) parts.add(_formatBytes(fileSizeBytes!));
    if (ext != null) parts.add(ext!.toUpperCase());
    if (height != null) parts.add('${height}p');
    if (fps != null && fps! > 0) parts.add('${fps!.round()}fps');
    if (uploader != null && uploader!.isNotEmpty) parts.add(uploader!);
    return parts.join(' · ');
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'url': url,
    'kind': kind.name,
    'title': title,
    'filePath': filePath,
    'thumbnailPath': thumbnailPath,
    'durationSeconds': durationSeconds,
    'fileSizeBytes': fileSizeBytes,
    'ext': ext,
    'height': height,
    'fps': fps,
    'uploader': uploader,
    'status': status.name,
    'error': error,
    'addedAt': addedAt.toIso8601String(),
  };

  factory DownloadItem.fromJson(Map<String, dynamic> json) {
    final parsed = DownloadStatus.values.firstWhere(
      (s) => s.name == json['status'],
      orElse: () => DownloadStatus.failed,
    );
    // A download can't survive an app restart. 'queued' and 'downloading'
    // are valid enum names, so they parse fine — they must be explicitly
    // downgraded to failed or they reload as forever-spinning progress bars.
    final interrupted =
        parsed == DownloadStatus.downloading || parsed == DownloadStatus.queued;
    return DownloadItem(
      id: json['id'] as String,
      url: json['url'] as String,
      kind: MediaKind.values.firstWhere(
        (k) => k.name == json['kind'],
        orElse: () => MediaKind.video,
      ),
      title: json['title'] as String?,
      filePath: json['filePath'] as String?,
      thumbnailPath: json['thumbnailPath'] as String?,
      durationSeconds: json['durationSeconds'] as int?,
      fileSizeBytes: json['fileSizeBytes'] as int?,
      ext: json['ext'] as String?,
      height: json['height'] as int?,
      fps: (json['fps'] as num?)?.toDouble(),
      uploader: json['uploader'] as String?,
      status: interrupted ? DownloadStatus.failed : parsed,
      error: interrupted
          ? 'Interrupted — the app was closed during download. '
                'Press Retry to download again.'
          : json['error'] as String?,
      addedAt: DateTime.tryParse(json['addedAt'] as String? ?? ''),
    );
  }
}

/// Shortens a filesystem path for tight UI spots: first [head] and last
/// [tail] characters, e.g. `C:\Users\adamt\Downloads` → `C:\Use...ads`.
/// The full path belongs in a tooltip next to wherever this is shown.
String abbreviatePath(String path, {int head = 6, int tail = 3}) {
  if (path.length <= head + tail + 3) return path;
  return '${path.substring(0, head)}...${path.substring(path.length - tail)}';
}

/// Extracts the display version from pubspec.yaml text ("1.2.0+5" → "1.2.0",
/// the build number is dropped). Returns '' when no version line is found.
String versionFromPubspec(String yaml) {
  final m = RegExp(
    r'^version:\s*([0-9][^\s+]*)',
    multiLine: true,
  ).firstMatch(yaml);
  return m?.group(1) ?? '';
}

String _formatDuration(int seconds) {
  final h = seconds ~/ 3600;
  final m = (seconds % 3600) ~/ 60;
  final s = seconds % 60;
  String two(int n) => n.toString().padLeft(2, '0');
  return h > 0 ? '$h:${two(m)}:${two(s)}' : '${two(m)}:${two(s)}';
}

String _formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  const units = ['KB', 'MB', 'GB', 'TB'];
  double size = bytes / 1024;
  int unit = 0;
  while (size >= 1024 && unit < units.length - 1) {
    size /= 1024;
    unit++;
  }
  final str = size >= 100 ? size.toStringAsFixed(0) : size.toStringAsFixed(1);
  return '$str ${units[unit]}';
}
