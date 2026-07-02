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

  final DateTime addedAt;

  String get displayTitle => title?.trim().isNotEmpty == true
      ? title!.trim()
      : url;

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
      status: DownloadStatus.values.firstWhere(
        (s) => s.name == json['status'],
        // Anything previously mid-flight is treated as failed on reload.
        orElse: () => DownloadStatus.failed,
      ),
      error: json['error'] as String?,
      addedAt: DateTime.tryParse(json['addedAt'] as String? ?? ''),
    );
  }
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
