import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'models.dart';

/// Holds user settings + the persistent download library and notifies the UI
/// of changes. State is saved to a single JSON file in the app-support dir.
class AppState extends ChangeNotifier {
  AppState();

  // ---- settings ----
  String downloadDir = '';
  MediaKind defaultKind = MediaKind.video;
  int? defaultQuality; // null = best
  String audioFormat = 'm4a'; // 'm4a' | 'mp3'

  /// YouTube login. Exactly one of these is set (or neither):
  /// [cookieBrowser] = read cookies live from a browser profile
  /// ('chrome' | 'edge' | 'firefox'), [cookieFilePath] = an exported
  /// Netscape-format cookies.txt.
  String? cookieBrowser;
  String? cookieFilePath;

  // ---- library ----
  final List<DownloadItem> _items = [];
  List<DownloadItem> get items => List.unmodifiable(_items);

  late final Directory _supportDir;

  File get _stateFile => File('${_supportDir.path}/youdown_data.json');

  Future<void> load() async {
    _supportDir = await getApplicationSupportDirectory();
    if (!await _supportDir.exists()) {
      await _supportDir.create(recursive: true);
    }

    // Default download dir: the OS Downloads folder, falling back to documents.
    if (downloadDir.isEmpty) {
      final dl = await _downloadsDir();
      downloadDir = dl?.path ?? _supportDir.path;
    }

    if (await _stateFile.exists()) {
      try {
        final json =
            jsonDecode(await _stateFile.readAsString()) as Map<String, dynamic>;
        final settings = json['settings'] as Map<String, dynamic>? ?? {};
        downloadDir = settings['downloadDir'] as String? ?? downloadDir;
        defaultKind = MediaKind.values.firstWhere(
          (k) => k.name == settings['defaultKind'],
          orElse: () => MediaKind.video,
        );
        defaultQuality = settings['defaultQuality'] as int?;
        cookieBrowser = settings['cookieBrowser'] as String?;
        cookieFilePath = settings['cookieFilePath'] as String?;
        audioFormat = settings['audioFormat'] as String? ?? 'm4a';

        final items = json['items'] as List<dynamic>? ?? [];
        _items
          ..clear()
          ..addAll(items.map(
              (e) => DownloadItem.fromJson(e as Map<String, dynamic>)));
      } catch (e) {
        debugPrint('Failed to load state: $e');
      }
    }
    notifyListeners();
  }

  Future<Directory?> _downloadsDir() async {
    try {
      return await getDownloadsDirectory();
    } catch (_) {
      return null;
    }
  }

  Future<void> save() async {
    final data = {
      'settings': {
        'downloadDir': downloadDir,
        'defaultKind': defaultKind.name,
        'defaultQuality': defaultQuality,
        'cookieBrowser': cookieBrowser,
        'cookieFilePath': cookieFilePath,
        'audioFormat': audioFormat,
      },
      'items': _items.map((e) => e.toJson()).toList(),
    };
    try {
      await _stateFile
          .writeAsString(const JsonEncoder.withIndent('  ').convert(data));
    } catch (e) {
      debugPrint('Failed to save state: $e');
    }
  }

  // ---- settings mutators ----
  void setDownloadDir(String dir) {
    downloadDir = dir;
    notifyListeners();
    save();
  }

  void setDefaultKind(MediaKind kind) {
    defaultKind = kind;
    notifyListeners();
    save();
  }

  void setDefaultQuality(int? height) {
    defaultQuality = height;
    notifyListeners();
    save();
  }

  void setAudioFormat(String fmt) {
    audioFormat = fmt;
    notifyListeners();
    save();
  }

  /// Selects browser-cookie login (clears any cookie file), or turns login
  /// off when [browser] is null.
  void setCookieBrowser(String? browser) {
    cookieBrowser = browser;
    cookieFilePath = null;
    notifyListeners();
    save();
  }

  /// Selects cookies.txt login (clears any browser selection).
  void setCookieFile(String path) {
    cookieFilePath = path;
    cookieBrowser = null;
    notifyListeners();
    save();
  }

  // ---- library mutators ----
  void addItem(DownloadItem item) {
    _items.insert(0, item); // newest first
    notifyListeners();
    save();
  }

  /// Notify + persist after a download service mutates an item in place.
  void touch(DownloadItem item, {bool persist = true}) {
    notifyListeners();
    if (persist) save();
  }

  void removeItem(DownloadItem item, {bool deleteFile = false}) {
    _items.remove(item);
    if (deleteFile && item.filePath != null) {
      try {
        final f = File(item.filePath!);
        if (f.existsSync()) f.deleteSync();
      } catch (e) {
        debugPrint('Failed to delete file: $e');
      }
    }
    notifyListeners();
    save();
  }

  // ---- import / export ----
  Future<void> exportLibrary(String path) async {
    final data = {
      'youdown_library': 1,
      'items': _items.map((e) => e.toJson()).toList(),
    };
    await File(path)
        .writeAsString(const JsonEncoder.withIndent('  ').convert(data));
  }

  /// Imports items from a previously exported file, skipping ones already
  /// present (matched by id). Returns the number of items added.
  Future<int> importLibrary(String path) async {
    final json = jsonDecode(await File(path).readAsString());
    final List<dynamic> raw;
    if (json is Map<String, dynamic>) {
      raw = json['items'] as List<dynamic>? ?? [];
    } else if (json is List) {
      raw = json;
    } else {
      raw = [];
    }
    final existing = _items.map((e) => e.id).toSet();
    int added = 0;
    for (final e in raw) {
      final item = DownloadItem.fromJson(e as Map<String, dynamic>);
      if (existing.contains(item.id)) continue;
      _items.add(item);
      existing.add(item.id);
      added++;
    }
    _items.sort((a, b) => b.addedAt.compareTo(a.addedAt));
    notifyListeners();
    await save();
    return added;
  }
}
