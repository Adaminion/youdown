import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:youdown/models.dart';
import 'package:youdown/ytdlp.dart';

void main() {
  final service = DownloadService();

  List<String> args({
    MediaKind kind = MediaKind.video,
    int? height,
    String? cookieBrowser,
    String? cookieFile,
  }) => service.buildArgs(
    url: 'https://youtube.com/watch?v=x',
    kind: kind,
    outTemplate: r'C:\dl\%(title)s.%(ext)s',
    height: height,
    cookieBrowser: cookieBrowser,
    cookieFile: cookieFile,
  );

  group('format selection', () {
    String fmt(List<String> a) => a[a.indexOf('-f') + 1];

    test('video uses bestvideo+bestaudio (not 360p progressive-only)', () {
      // Progressive `best` tops out at 360p on YouTube; the selector must
      // request separate video+audio streams to reach higher resolutions.
      expect(fmt(args(height: 1080)), startsWith('bestvideo'));
      expect(fmt(args(height: 1080)), contains('+bestaudio'));
      expect(fmt(args()), startsWith('bestvideo'));
    });

    test('height cap is applied to the video stream', () {
      expect(fmt(args(height: 720)), contains('[height<=720]'));
      expect(fmt(args()), isNot(contains('height<=')));
    });

    test('video merges into mp4', () {
      final a = args(height: 1080);
      expect(a[a.indexOf('--merge-output-format') + 1], 'mp4');
    });

    test('audio prefers m4a, falls back to muxed, never merges video', () {
      final a = args(kind: MediaKind.audio);
      expect(fmt(a), 'bestaudio[ext=m4a]/bestaudio/best');
      expect(a, isNot(contains('--merge-output-format')));
    });
  });

  group('url cleaning', () {
    test('watch URL loses playlist and tracking params', () {
      expect(
        cleanVideoUrl(
          'https://www.youtube.com/watch?v=ayo-NgC3_Z0&pp=ugUEEgJIbg%3D%3D',
        ),
        'https://www.youtube.com/watch?v=ayo-NgC3_Z0',
      );
      expect(
        cleanVideoUrl(
          'https://www.youtube.com/watch?v=abc123&list=PLxyz&index=7',
        ),
        'https://www.youtube.com/watch?v=abc123',
      );
    });

    test('youtu.be short links expand to a bare watch URL', () {
      expect(
        cleanVideoUrl('https://youtu.be/dQw4w9WgXcQ?si=share_tracking'),
        'https://www.youtube.com/watch?v=dQw4w9WgXcQ',
      );
    });

    test('shorts keep their path but lose the query', () {
      expect(
        cleanVideoUrl('https://www.youtube.com/shorts/xyz?feature=share'),
        'https://www.youtube.com/shorts/xyz',
      );
    });

    test('non-YouTube URLs pass through unchanged', () {
      const fb = 'https://www.facebook.com/reel/2697743477309323';
      expect(cleanVideoUrl(fb), fb);
    });
  });

  group('audio formats', () {
    test('audio always extracts (-x) with the chosen format', () {
      final a = args(kind: MediaKind.audio);
      expect(a, contains('-x'));
      expect(a[a.indexOf('--audio-format') + 1], 'm4a');
      // video never extracts
      expect(args(), isNot(contains('-x')));
    });

    test('download URL is cleaned of playlist params', () {
      final a = service.buildArgs(
        url: 'https://www.youtube.com/watch?v=Qs9XrrjuFn8&list=LL&index=2',
        kind: MediaKind.video,
        outTemplate: r'C:\dl\%(title)s.%(ext)s',
        height: null,
      );
      expect(a.first, 'https://www.youtube.com/watch?v=Qs9XrrjuFn8');
    });

    test('mp3 extracts and converts', () {
      final a = args(kind: MediaKind.audio, cookieBrowser: null);
      final mp3 = service.buildArgs(
        url: 'https://youtube.com/watch?v=x',
        kind: MediaKind.audio,
        outTemplate: r'C:\dl\%(title)s.%(ext)s',
        height: null,
        audioFormat: 'mp3',
      );
      expect(mp3, contains('-x'));
      expect(mp3[mp3.indexOf('--audio-format') + 1], 'mp3');
      expect(mp3[mp3.indexOf('-f') + 1], 'bestaudio/best');
      // and video downloads never convert audio
      expect(a, isNot(contains('mp3')));
    });
  });

  group('login args', () {
    test('off by default', () {
      final a = args();
      expect(a, isNot(contains('--cookies')));
      expect(a, isNot(contains('--cookies-from-browser')));
    });

    test('browser cookies', () {
      final a = args(cookieBrowser: 'edge');
      expect(a[a.indexOf('--cookies-from-browser') + 1], 'edge');
      expect(a, isNot(contains('--cookies')));
    });

    test('cookie file wins over browser', () {
      final a = args(cookieBrowser: 'chrome', cookieFile: r'C:\c\cookies.txt');
      expect(a[a.indexOf('--cookies') + 1], r'C:\c\cookies.txt');
      expect(a, isNot(contains('--cookies-from-browser')));
    });
  });

  group('js runtime', () {
    test('buildArgs passes --js-runtimes when resolved', () {
      final a = service.buildArgs(
        url: 'https://youtube.com/watch?v=x',
        kind: MediaKind.video,
        outTemplate: r'C:\dl\%(title)s.%(ext)s',
        height: null,
        jsRuntime: r'deno:C:\tools\deno.exe',
      );
      expect(a[a.indexOf('--js-runtimes') + 1], r'deno:C:\tools\deno.exe');
      expect(args(), isNot(contains('--js-runtimes'))); // omitted when null
    });

    test('findJsRuntime returns a deno spec or null, never throws', () async {
      final r = await service.findJsRuntime();
      expect(r, anyOf(isNull, startsWith('deno:')));
    });
  });

  group('error summaries', () {
    test('missing JS runtime hint wins for "not available" errors', () {
      final msg = service.summarizeError([
        'ERROR: [youtube] abc: This video is not available',
      ], jsRuntimeMissing: true);
      expect(msg, contains('install Deno'));
      expect(msg, isNot(contains('set Login'))); // runtime hint takes priority
    });

    test('no runtime hint when a runtime is present', () {
      final msg = service.summarizeError([
        'ERROR: [youtube] abc: This video is not available',
      ]);
      expect(msg, isNot(contains('install Deno')));
    });

    test('locked cookie DB becomes actionable', () {
      final msg = service.summarizeError(
        [
          'ERROR: Could not copy Chrome cookie database. See '
              'https://github.com/yt-dlp/yt-dlp/issues/7271 for more info',
        ],
        cookieBrowser: 'chrome',
        loginConfigured: true,
      );
      expect(msg, contains('close chrome'));
      expect(msg, contains('cookies.txt'));
    });

    test('DPAPI decrypt failure points to cookies.txt', () {
      final msg = service.summarizeError(
        ['ERROR: Failed to decrypt with DPAPI. See https://... for more info'],
        cookieBrowser: 'chrome',
        loginConfigured: true,
      );
      expect(msg, contains('cookies.txt'));
      expect(msg, contains('chrome'));
    });

    test('app-bound (v20) decrypt warnings point to cookies.txt', () {
      // yt-dlp only WARNs about undecryptable v20 cookies; the final ERROR is
      // YouTube rejecting the (empty) login. The summary must still name the
      // real cause.
      final msg = service.summarizeError(
        [
          'WARNING: [youtube] Failed to decrypt 42 cookies as they are in '
              'v20 format',
          "ERROR: [youtube] abc: Sign in to confirm you're not a bot.",
        ],
        cookieBrowser: 'chrome',
        loginConfigured: true,
      );
      expect(msg, contains('cookies.txt'));
      expect(msg, contains('app-bound'));
    });

    test('missing firefox profile gets install/sign-in guidance', () {
      final msg = service.summarizeError(
        [
          "ERROR: could not find firefox cookies database in "
              "'C:\\Users\\x\\AppData\\Roaming\\Mozilla\\Firefox\\Profiles'",
        ],
        cookieBrowser: 'firefox',
        loginConfigured: true,
      );
      expect(msg, contains('Firefox'));
      expect(msg, contains('cookies.txt'));
    });

    test('rotated cookies point to a fresh private-window export', () {
      final msg = service.summarizeError([
        'ERROR: The provided YouTube account cookies are no longer valid. '
            'They have likely been rotated in the browser as a security '
            'measure.',
      ], loginConfigured: true);
      expect(msg, contains('Re-export'));
      expect(msg, contains('private/incognito'));
    });

    test('auth-shaped error hints at Login when login is off', () {
      final msg = service.summarizeError([
        'ERROR: [youtube] abc: This video is not available',
      ]);
      expect(msg, contains('set Login in the toolbar'));
    });

    test('no login hint when login is already configured', () {
      final msg = service.summarizeError([
        'ERROR: [youtube] abc: This video is not available',
      ], loginConfigured: true);
      expect(msg, isNot(contains('set Login')));
    });

    test('PYI crash surfaces the real Python exception', () {
      final msg = service.summarizeError([
        '  File "yt_dlp\\cookies.py", line 1305, in open',
        "FileNotFoundError: [Errno 2] No such file or directory: 'F:\\\\downloads\\\\cookies.txt'",
        "[PYI-4284:ERROR] Failed to execute script '__main__' due to unhandled exception!",
      ]);
      expect(msg, contains('yt-dlp crashed'));
      expect(msg, contains('FileNotFoundError'));
      expect(msg, isNot(contains('PYI')));
    });

    test('PYI crash without traceback gets a generic path hint', () {
      final msg = service.summarizeError([
        "[PYI-1:ERROR] Failed to execute script '__main__' due to unhandled exception!",
      ]);
      expect(msg, contains('check that the download folder'));
    });

    test('plain errors pass through', () {
      expect(
        service.summarizeError(['ERROR: unsupported URL: foo']),
        'unsupported URL: foo',
      );
      expect(service.summarizeError([]), 'Download failed');
    });
  });

  group('run pipeline', () {
    test(
      'run() completes instead of hanging when the process exits fast',
      () async {
        // Regression: the pipe-drain wait used to attach asFuture() after the
        // streams had already closed, which never completes — items sat at
        // "downloading" forever even though the process was long gone.
        final svc = DownloadService();
        svc.binaryOverride = Platform.isWindows
            ? '${Platform.environment['SystemRoot']}\\System32\\where.exe'
            : '/bin/ls';
        final dir = await Directory.systemTemp.createTemp('youdown_run');
        addTearDown(() => dir.delete(recursive: true));
        final item = DownloadItem(
          id: 'run1',
          url: 'https://example.com/x',
          kind: MediaKind.video,
        );

        await svc
            .run(item, dir: dir.path, height: null, onUpdate: () {})
            .timeout(const Duration(seconds: 20));

        // The stub isn't yt-dlp, so the download fails — the point is that
        // run() *returns* and reports a terminal status.
        expect(item.status, DownloadStatus.failed);
        expect(item.error, isNotNull);
      },
    );
  });

  group('locateOutput fallback', () {
    test(
      'finds the media file via info.json when stdout path is unusable',
      () async {
        // Simulates the codepage-mangling case: yt-dlp wrote correct files to
        // disk but the YDFILE stdout line was garbled.
        final svc = DownloadService();
        final dir = await Directory.systemTemp.createTemp('youdown_locate');
        addTearDown(() => dir.delete(recursive: true));

        const title = 'Krajský přebor Zlínského kraje 2014';
        final media = File('${dir.path}/$title.mp4');
        await media.writeAsString('fake video');
        await File('${dir.path}/$title.info.json').writeAsString(
          '{"id": "gXcP_0lMaHc", "title": "$title", "ext": "mp4"}',
        );
        // An unrelated older-looking info.json must not match.
        await File(
          '${dir.path}/Other Video.info.json',
        ).writeAsString('{"id": "zzzzzzzzzzz", "ext": "mp4"}');

        final found = await svc.locateOutput(
          url: 'https://www.youtube.com/watch?v=gXcP_0lMaHc',
          dir: dir.path,
          since: DateTime.now().subtract(const Duration(seconds: 30)),
        );
        // Normalize separators: the scan returns OS-native `\` paths.
        String norm(String? p) => p?.replaceAll('/', r'\') ?? '';
        expect(norm(found), norm(media.path));
      },
    );

    test('returns null when nothing matches', () async {
      final svc = DownloadService();
      final dir = await Directory.systemTemp.createTemp('youdown_locate2');
      addTearDown(() => dir.delete(recursive: true));
      final found = await svc.locateOutput(
        url: 'https://www.youtube.com/watch?v=gXcP_0lMaHc',
        dir: dir.path,
        since: DateTime.now(),
      );
      expect(found, isNull);
    });
  });

  group('preflight', () {
    test('missing download folder is reported', () async {
      final msg = await service.preflight(dir: r'Q:\no\such\folder');
      expect(msg, contains('Download folder not found'));
    });

    test('missing cookies file is reported', () async {
      final dir = await Directory.systemTemp.createTemp('youdown_test');
      addTearDown(() => dir.delete(recursive: true));
      final nonExistentPath = '${dir.path}/nonexistent_cookies_xyz_12345.txt';
      final msg = await service.preflight(
        dir: dir.path,
        cookieFile: nonExistentPath,
      );
      expect(msg, contains('Cookies file not found'));
      expect(msg, contains(nonExistentPath));
    });

    test('valid paths pass', () async {
      final dir = await Directory.systemTemp.createTemp('youdown_test');
      addTearDown(() => dir.delete(recursive: true));
      final cookies = File('${dir.path}/cookies.txt');
      await cookies.writeAsString('# Netscape HTTP Cookie File\n');
      expect(
        await service.preflight(dir: dir.path, cookieFile: cookies.path),
        isNull,
      );
      expect(await service.preflight(dir: dir.path), isNull);
    });
  });
}
