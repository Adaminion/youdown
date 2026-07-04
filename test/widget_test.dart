import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:youdown/app_state.dart';
import 'package:youdown/main.dart';
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

  test('abbreviatePath keeps short paths, shortens long ones', () {
    expect(abbreviatePath(r'C:\dl'), r'C:\dl');
    expect(abbreviatePath(r'C:\Users\adamt\Downloads'), r'C:\Use...ads');
    expect(abbreviatePath('/home/adam/Videos/youtube'), '/home/...ube');
  });

  test('versionFromPubspec reads version, drops the build number', () {
    expect(versionFromPubspec('name: x\nversion: 1.3.12+7\n'), '1.3.12');
    expect(versionFromPubspec('name: x\nversion: 1.2.0\n'), '1.2.0');
    expect(versionFromPubspec('name: x\n'), '');
    // must not match the "like 1.2.43" example in pubspec comments
    expect(versionFromPubspec('# A version number is 1.2.43\nversion: 2.0.0+1'),
        '2.0.0');
  });

  testWidgets('version overlay and abbreviated Save-to path render',
      (tester) async {
    final state = AppState();
    state.downloadDir = r'C:\Users\adamt\Downloads';
    await tester.pumpWidget(YouDownApp(state: state, version: '9.9.9'));

    expect(find.text('9.9.9'), findsOneWidget); // bottom-right overlay
    expect(find.text(r'C:\Use...ads'), findsOneWidget); // Save-to chip

    // Full path is available as the chip's tooltip.
    expect(
      find.byWidgetPredicate(
          (w) => w is Tooltip && w.message == r'C:\Users\adamt\Downloads'),
      findsOneWidget,
    );
  });

  test('quality labels', () {
    expect(Quality.label(null), 'Best');
    expect(Quality.label(2160), '4K');
    expect(Quality.label(1080), '1080p');
    expect(Quality.options, contains(2160));
  });
}
