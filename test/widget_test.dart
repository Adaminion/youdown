import 'package:flutter_test/flutter_test.dart';
import 'package:youdown/models.dart';

void main() {
  test('DownloadItem JSON round-trips', () {
    final item = DownloadItem(
      id: 'abc',
      url: 'https://example.com/v',
      kind: MediaKind.video,
      title: 'My clip',
      filePath: r'C:\dl\My clip.mp4',
      durationSeconds: 42,
      fileSizeBytes: 6 * 1024 * 1024,
      ext: 'mp4',
      height: 720,
      fps: 30,
      uploader: 'Some Channel',
      status: DownloadStatus.done,
    );

    final restored = DownloadItem.fromJson(item.toJson());

    expect(restored.id, 'abc');
    expect(restored.url, 'https://example.com/v');
    expect(restored.kind, MediaKind.video);
    expect(restored.title, 'My clip');
    expect(restored.height, 720);
    expect(restored.status, DownloadStatus.done);
  });

  test('subtitle is built from available metadata', () {
    final item = DownloadItem(
      id: '1',
      url: 'https://x',
      kind: MediaKind.video,
      durationSeconds: 42,
      fileSizeBytes: 6 * 1024 * 1024,
      ext: 'mp4',
      height: 720,
      fps: 30,
      uploader: 'klips.funfun',
    );
    expect(item.subtitle, '00:42 · 6.0 MB · MP4 · 720p · 30fps · klips.funfun');
  });

  test('quality labels', () {
    expect(Quality.label(null), 'Best');
    expect(Quality.label(2160), '4K');
    expect(Quality.label(1080), '1080p');
    expect(Quality.options, contains(2160));
  });
}
