import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:open_filex/open_filex.dart';
import 'package:super_drag_and_drop/super_drag_and_drop.dart';
import 'package:url_launcher/url_launcher.dart';

import 'app_state.dart';
import 'models.dart';
import 'ytdlp.dart';

enum SortMode { newest, oldest, title, size }

int _idCounter = 0;
String _newId() => '${DateTime.now().microsecondsSinceEpoch}_${_idCounter++}';

bool _isValidUrl(String s) {
  final uri = Uri.tryParse(s.trim());
  return uri != null &&
      (uri.scheme == 'http' || uri.scheme == 'https') &&
      uri.host.isNotEmpty;
}

class HomePage extends StatefulWidget {
  const HomePage({super.key, required this.state});

  final AppState state;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final _service = DownloadService();
  final _searchCtrl = TextEditingController();
  String _search = '';
  SortMode _sort = SortMode.newest;
  bool _autoDownload = true;

  AppState get state => widget.state;

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  // ---- adding / downloading ----

  void _addText(String text) {
    final urls = text
        .split(RegExp(r'[\r\n]+'))
        .map((e) => e.trim())
        .where(_isValidUrl)
        .map(
          cleanVideoUrl,
        ) // single video only — strip playlist/tracking params
        .toList();
    if (urls.isEmpty) {
      _toast('No valid link found');
      return;
    }
    for (final url in urls) {
      final item = DownloadItem(
        id: _newId(),
        url: url,
        kind: state.defaultKind,
      );
      state.addItem(item);
      if (_autoDownload) _start(item);
    }
  }

  Future<void> _start(DownloadItem item) async {
    await _service.run(
      item,
      dir: state.downloadDir,
      height: state.defaultQuality,
      audioFormat: state.audioFormat,
      cookieBrowser: state.cookieBrowser,
      cookieFile: state.cookieFilePath,
      onUpdate: () => state.touch(item, persist: false),
    );
    state.touch(item); // persist final result
  }

  Future<void> _pasteLink() async {
    final data = await Clipboard.getData('text/plain');
    final text = data?.text ?? '';
    if (text.trim().isEmpty) {
      _toast('Clipboard is empty');
      return;
    }
    _addText(text);
  }

  // ---- row actions ----

  /// Redownload always runs with the *current* settings (download folder,
  /// login), then offers a fix-it dialog if it failed on a known problem —
  /// and retries immediately when the user fixes it.
  Future<void> _redownload(DownloadItem item) async {
    await _start(item);
    if (item.status == DownloadStatus.failed && mounted) {
      final fixed = await _offerErrorFix(item);
      if (fixed) await _start(item);
    }
  }

  /// Offers a fix for known failure causes (missing folder, missing or
  /// unreadable cookies). Returns true when the user changed something and
  /// the download should be retried right away.
  Future<bool> _offerErrorFix(DownloadItem item) async {
    final err = item.error;
    if (err == null || !mounted) return false;

    if (err.contains('Download folder not found')) {
      final result = await showDialog<String>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Download Folder Not Found'),
          content: Text(err),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, 'change'),
              child: const Text('Change Folder'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, null),
              child: const Text('Cancel'),
            ),
          ],
        ),
      );
      if (result == 'change') return _pickFolder();
      return false;
    }

    if (err.contains('Cookies file not found')) {
      final result = await showDialog<String>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Cookies File Not Found'),
          content: Text(err),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, 'change'),
              child: const Text('Re-select File'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, 'disable'),
              child: const Text('Turn Off Login'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, null),
              child: const Text('Cancel'),
            ),
          ],
        ),
      );
      if (result == 'change') return _pickCookieFile();
      if (result == 'disable') {
        state.setCookieBrowser(null);
        return true;
      }
      return false;
    }

    // Browser cookies unreadable (locked DB / Chrome-Edge encryption).
    if (state.cookieBrowser != null &&
        err.contains('cookies') &&
        (err.contains('decrypt') ||
            err.contains('close ') ||
            err.contains('cookies.txt'))) {
      final result = await showDialog<String>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Browser Login Failed'),
          content: Text(
            '$err\n\nAn exported cookies.txt file is the most '
            'reliable way to stay logged in.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, 'file'),
              child: const Text('Use cookies.txt…'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, 'disable'),
              child: const Text('Turn Off Login'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, null),
              child: const Text('Cancel'),
            ),
          ],
        ),
      );
      if (result == 'file') return _pickCookieFile();
      if (result == 'disable') {
        state.setCookieBrowser(null);
        return true;
      }
      return false;
    }
    return false;
  }

  Future<void> _copyUrl(DownloadItem item) async {
    await Clipboard.setData(ClipboardData(text: item.url));
    _toast('Link copied');
  }

  Future<void> _play(DownloadItem item) async {
    final path = item.filePath;
    if (path == null || !File(path).existsSync()) {
      _toast(
        'File not found — it may have been moved or deleted. '
        'Use Redownload to fetch it again.',
      );
      return;
    }
    final res = await OpenFilex.open(path);
    if (res.type != ResultType.done) _toast('Could not open file');
  }

  Future<void> _openLink(DownloadItem item) async {
    final uri = Uri.tryParse(item.url);
    if (uri != null) await launchUrl(uri);
  }

  Future<void> _revealFolder(DownloadItem item) async {
    final path = item.filePath;
    if (path != null && File(path).existsSync()) {
      if (Platform.isWindows) {
        // /select, and the path must be ONE argument: as separate args the
        // command line gets a space after the comma and Explorer silently
        // opens the default (Documents) folder instead.
        await Process.run('explorer.exe', ['/select,$path']);
      } else if (Platform.isMacOS) {
        await Process.run('open', ['-R', path]);
      } else {
        await Process.run('xdg-open', [File(path).parent.path]);
      }
      return;
    }
    // File gone (moved/deleted/never landed): open its folder — or the
    // current download folder — instead of doing nothing.
    var dir = path != null ? File(path).parent.path : state.downloadDir;
    if (!Directory(dir).existsSync()) dir = state.downloadDir;
    if (!Directory(dir).existsSync()) {
      _toast('Folder not found: $dir');
      return;
    }
    if (Platform.isWindows) {
      await Process.run('explorer.exe', [dir]);
    } else if (Platform.isMacOS) {
      await Process.run('open', [dir]);
    } else {
      await Process.run('xdg-open', [dir]);
    }
    if (path != null) _toast('File not found — opened the folder instead');
  }

  // ---- import / export / settings ----

  Future<void> _export() async {
    final path = await FilePicker.saveFile(
      dialogTitle: 'Export library',
      fileName: 'youdown_library.json',
      type: FileType.custom,
      allowedExtensions: ['json'],
    );
    if (path == null) return;
    await state.exportLibrary(path);
    _toast('Exported ${state.items.length} item(s)');
  }

  Future<void> _import() async {
    final res = await FilePicker.pickFiles(
      dialogTitle: 'Import library',
      type: FileType.custom,
      allowedExtensions: ['json'],
    );
    final path = res?.files.single.path;
    if (path == null) return;
    try {
      final added = await state.importLibrary(path);
      _toast('Imported $added new item(s)');
    } catch (e) {
      _toast('Import failed: $e');
    }
  }

  /// Returns true when a new folder was actually chosen.
  Future<bool> _pickFolder() async {
    try {
      final dir = await FilePicker.getDirectoryPath(
        dialogTitle: 'Choose download folder',
        initialDirectory: state.downloadDir,
      );
      if (dir != null) {
        state.setDownloadDir(dir);
        _toast('Save folder changed to: $dir');
        return true;
      }
    } catch (e) {
      _toast('Failed to change folder: $e');
    }
    return false;
  }

  /// Returns true when a cookies file was actually chosen.
  Future<bool> _pickCookieFile() async {
    final res = await FilePicker.pickFiles(
      dialogTitle: 'Choose exported cookies.txt',
      type: FileType.custom,
      allowedExtensions: ['txt'],
    );
    final path = res?.files.single.path;
    if (path == null) return false;
    state.setCookieFile(path);
    _toast('Login set: cookies file');
    return true;
  }

  /// Handles picking a browser in the Login dropdown. On Windows, Chrome and
  /// Edge cookies are app-bound encrypted and reading them almost always
  /// fails (even with the browser closed) — warn up front and steer to a
  /// cookies.txt export instead of letting downloads fail later.
  Future<void> _selectBrowserLogin(String browser) async {
    if (Platform.isWindows && (browser == 'chrome' || browser == 'edge')) {
      final name = browser == 'chrome' ? 'Chrome' : 'Edge';
      final choice = await showDialog<String>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text('$name login usually fails on Windows'),
          content: Text(
            '$name encrypts its cookies (app-bound encryption), so reading '
            'them typically fails even when $name is fully closed.\n\n'
            'Reliable options:\n'
            '• Export a cookies.txt file with a browser extension such as '
            '"Get cookies.txt LOCALLY" while logged in to YouTube, or\n'
            '• Use Firefox login instead.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, 'file'),
              child: const Text('Use cookies.txt…'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, 'anyway'),
              child: Text('Try $name anyway'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, null),
              child: const Text('Cancel'),
            ),
          ],
        ),
      );
      if (choice == 'file') {
        await _pickCookieFile();
      } else if (choice == 'anyway') {
        state.setCookieBrowser(browser);
      }
      return;
    }
    state.setCookieBrowser(browser);
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(msg)));
  }

  // ---- drop handling ----

  Future<void> _onPerformDrop(PerformDropEvent event) async {
    for (final item in event.session.items) {
      final reader = item.dataReader;
      if (reader == null) continue;
      if (reader.canProvide(Formats.uri)) {
        reader.getValue(Formats.uri, (value) {
          final uri = value?.uri;
          if (uri != null) _addText(uri.toString());
        });
      } else if (reader.canProvide(Formats.plainText)) {
        reader.getValue(Formats.plainText, (value) {
          if (value != null) _addText(value);
        });
      }
    }
  }

  // ---- build ----

  List<DownloadItem> get _visibleItems {
    var list = state.items.toList();
    if (_search.isNotEmpty) {
      final q = _search.toLowerCase();
      list = list
          .where(
            (i) =>
                i.displayTitle.toLowerCase().contains(q) ||
                i.url.toLowerCase().contains(q),
          )
          .toList();
    }
    switch (_sort) {
      case SortMode.newest:
        list.sort((a, b) => b.addedAt.compareTo(a.addedAt));
      case SortMode.oldest:
        list.sort((a, b) => a.addedAt.compareTo(b.addedAt));
      case SortMode.title:
        list.sort(
          (a, b) => a.displayTitle.toLowerCase().compareTo(
            b.displayTitle.toLowerCase(),
          ),
        );
      case SortMode.size:
        list.sort(
          (a, b) => (b.fileSizeBytes ?? 0).compareTo(a.fileSizeBytes ?? 0),
        );
    }
    return list;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: AnimatedBuilder(
        animation: state,
        builder: (context, _) {
          return DropRegion(
            formats: const [...Formats.standardFormats],
            onDropOver: (event) => DropOperation.copy,
            onPerformDrop: _onPerformDrop,
            child: Column(
              children: [
                _Toolbar(
                  state: state,
                  autoDownload: _autoDownload,
                  onToggleAuto: (v) => setState(() => _autoDownload = v),
                  onPaste: _pasteLink,
                  onPickFolder: _pickFolder,
                  onPickCookieFile: _pickCookieFile,
                  onSelectBrowser: _selectBrowserLogin,
                  onImport: _import,
                  onExport: _export,
                ),
                _SearchBar(
                  controller: _searchCtrl,
                  count: _visibleItems.length,
                  sort: _sort,
                  onSearch: (v) => setState(() => _search = v),
                  onSort: (s) => setState(() => _sort = s),
                ),
                Expanded(child: _buildList()),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _buildList() {
    final items = _visibleItems;
    if (items.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.download_for_offline_outlined,
              size: 56,
              color: Colors.grey.shade400,
            ),
            const SizedBox(height: 12),
            Text(
              state.items.isEmpty
                  ? 'Paste or drop a video link to start'
                  : 'No items match your search',
              style: TextStyle(color: Colors.grey.shade600),
            ),
          ],
        ),
      );
    }
    return ListView.separated(
      itemCount: items.length,
      separatorBuilder: (context, index) => const Divider(height: 1),
      itemBuilder: (context, i) => _DownloadRow(
        item: items[i],
        onPlay: () => _play(items[i]),
        onFolder: () => _revealFolder(items[i]),
        onLink: () => _openLink(items[i]),
        onCopyUrl: () => _copyUrl(items[i]),
        onRedownload: () => _redownload(items[i]),
        onRemove: () => state.removeItem(items[i]),
      ),
    );
  }
}

// ---------------------------------------------------------------------------

class _Toolbar extends StatelessWidget {
  const _Toolbar({
    required this.state,
    required this.autoDownload,
    required this.onToggleAuto,
    required this.onPaste,
    required this.onPickFolder,
    required this.onPickCookieFile,
    required this.onSelectBrowser,
    required this.onImport,
    required this.onExport,
  });

  final AppState state;
  final bool autoDownload;
  final ValueChanged<bool> onToggleAuto;
  final VoidCallback onPaste;
  final VoidCallback onPickFolder;
  final VoidCallback onPickCookieFile;
  final ValueChanged<String> onSelectBrowser;
  final VoidCallback onImport;
  final VoidCallback onExport;

  @override
  Widget build(BuildContext context) {
    final isAudio = state.defaultKind == MediaKind.audio;
    // Compact "C:\Use...ads" form; the full path lives in the tooltip.
    final folderLabel = state.downloadDir.isEmpty
        ? '…'
        : abbreviatePath(state.downloadDir);

    return Material(
      color: Theme.of(context).colorScheme.surfaceContainerLow,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              // Wrap, not Row: on narrow windows the chips flow onto another
              // line instead of overflowing (striped overflow bars).
              child: Wrap(
                spacing: 8,
                runSpacing: 6,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  FilledButton.icon(
                    onPressed: onPaste,
                    icon: const Icon(Icons.link, size: 18),
                    label: const Text('Paste Link'),
                  ),
                  Tooltip(
                    message: 'Auto-download when a link is added',
                    child: Switch(value: autoDownload, onChanged: onToggleAuto),
                  ),
                  _ToolChip(
                    color: _Palette.downloadBg,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          isAudio
                              ? Icons.music_note_outlined
                              : Icons.videocam_outlined,
                          size: 17,
                          color: _Palette.downloadFg,
                        ),
                        const SizedBox(width: 5),
                        const Text(
                          'Download ',
                          style: TextStyle(color: _Palette.downloadFg),
                        ),
                        _ChipDropdown<MediaKind>(
                          value: state.defaultKind,
                          accent: _Palette.downloadFg,
                          items: const {
                            MediaKind.video: 'Video',
                            MediaKind.audio: 'Audio',
                          },
                          onChanged: (v) => state.setDefaultKind(v),
                        ),
                      ],
                    ),
                  ),
                  // Resolution — greyed out for audio. 0 = "Best" (a null dropdown
                  // value would render blank and be unselectable).
                  Opacity(
                    opacity: isAudio ? 0.45 : 1,
                    child: _ToolChip(
                      color: _Palette.qualityBg,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(
                            Icons.tune,
                            size: 17,
                            color: _Palette.qualityFg,
                          ),
                          const SizedBox(width: 5),
                          const Text(
                            'Quality ',
                            style: TextStyle(color: _Palette.qualityFg),
                          ),
                          _ChipDropdown<int>(
                            value: state.defaultQuality ?? 0,
                            enabled: !isAudio,
                            accent: _Palette.qualityFg,
                            items: {
                              for (final h in Quality.options)
                                h ?? 0: Quality.label(h),
                            },
                            onChanged: (v) =>
                                state.setDefaultQuality(v == 0 ? null : v),
                          ),
                        ],
                      ),
                    ),
                  ),
                  // Output format: fixed MP4 for video, M4A/MP3 choice for audio.
                  _ToolChip(
                    color: _Palette.formatBg,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(
                          Icons.insert_drive_file_outlined,
                          size: 17,
                          color: _Palette.formatFg,
                        ),
                        const SizedBox(width: 5),
                        const Text(
                          'Format ',
                          style: TextStyle(color: _Palette.formatFg),
                        ),
                        if (isAudio)
                          _ChipDropdown<String>(
                            value: state.audioFormat,
                            accent: _Palette.formatFg,
                            items: {
                              for (final f in AudioFormat.options)
                                f: f.toUpperCase(),
                            },
                            onChanged: (v) => state.setAudioFormat(v),
                          )
                        else
                          const Padding(
                            padding: EdgeInsets.symmetric(vertical: 8),
                            child: Text(
                              'MP4',
                              style: TextStyle(
                                fontWeight: FontWeight.w600,
                                color: _Palette.formatFg,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                  Tooltip(
                    message: state.downloadDir.isEmpty ? '' : state.downloadDir,
                    waitDuration: const Duration(milliseconds: 400),
                    child: _ToolChip(
                      color: _Palette.folderBg,
                      child: InkWell(
                        onTap: onPickFolder,
                        borderRadius: BorderRadius.circular(20),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 8),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(
                                Icons.folder_outlined,
                                size: 17,
                                color: _Palette.folderFg,
                              ),
                              const SizedBox(width: 5),
                              const Text(
                                'Save to ',
                                style: TextStyle(color: _Palette.folderFg),
                              ),
                              Text(
                                folderLabel,
                                style: const TextStyle(
                                  fontWeight: FontWeight.w600,
                                  color: _Palette.folderFg,
                                ),
                              ),
                              const Icon(
                                Icons.arrow_drop_down,
                                size: 18,
                                color: _Palette.folderFg,
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                  _ToolChip(
                    color: _Palette.loginBg,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(
                          Icons.cookie_outlined,
                          size: 17,
                          color: _Palette.loginFg,
                        ),
                        const SizedBox(width: 5),
                        const Text(
                          'Login ',
                          style: TextStyle(color: _Palette.loginFg),
                        ),
                        _ChipDropdown<String>(
                          value: state.cookieFilePath != null
                              ? 'file'
                              : (state.cookieBrowser ?? 'off'),
                          accent: _Palette.loginFg,
                          items: {
                            'off': 'Off',
                            'file': state.cookieFilePath == null
                                ? 'Cookies file…'
                                : state.cookieFilePath!
                                      .split(RegExp(r'[/\\]'))
                                      .last,
                            'chrome': 'Chrome',
                            'edge': 'Edge',
                            'firefox': 'Firefox',
                          },
                          onChanged: (v) {
                            if (v == 'file') {
                              onPickCookieFile();
                            } else if (v == 'off') {
                              state.setCookieBrowser(null);
                            } else {
                              onSelectBrowser(v);
                            }
                          },
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            PopupMenuButton<String>(
              icon: const Icon(Icons.more_vert),
              tooltip: 'More',
              onSelected: (v) {
                if (v == 'import') onImport();
                if (v == 'export') onExport();
              },
              itemBuilder: (_) => const [
                PopupMenuItem(
                  value: 'import',
                  child: ListTile(
                    leading: Icon(Icons.file_upload_outlined),
                    title: Text('Import list…'),
                  ),
                ),
                PopupMenuItem(
                  value: 'export',
                  child: ListTile(
                    leading: Icon(Icons.file_download_outlined),
                    title: Text('Export list…'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Toolbar accent colors: light chip background + saturated foreground.
class _Palette {
  static const downloadBg = Color(0xFFE0E7FF); // indigo
  static const downloadFg = Color(0xFF3F51B5);
  static const qualityBg = Color(0xFFCCF5EE); // teal
  static const qualityFg = Color(0xFF0F766E);
  static const formatBg = Color(0xFFFEF3C7); // amber
  static const formatFg = Color(0xFFB45309);
  static const folderBg = Color(0xFFEDE9FE); // violet
  static const folderFg = Color(0xFF7C3AED);
  static const loginBg = Color(0xFFFFE4E9); // rose
  static const loginFg = Color(0xFFBE1254);

  // Row action icons.
  static const play = Color(0xFF16A34A); // green
  static const openFolder = Color(0xFFD97706); // amber
  static const redownload = Color(0xFF2563EB); // blue
  static const copy = Color(0xFF0D9488); // teal
  static const openLink = Color(0xFF7C3AED); // violet
  static const remove = Color(0xFFDC2626); // red
}

/// Rounded colored container for a toolbar control.
class _ToolChip extends StatelessWidget {
  const _ToolChip({required this.color, required this.child});
  final Color color;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(20),
      ),
      child: child,
    );
  }
}

/// Compact accent-colored dropdown used inside a [_ToolChip]: no underline,
/// bold value text.
class _ChipDropdown<T> extends StatelessWidget {
  const _ChipDropdown({
    required this.value,
    required this.items,
    required this.onChanged,
    required this.accent,
    this.enabled = true,
  });

  final T value;
  final Map<T, String> items;
  final ValueChanged<T> onChanged;
  final Color accent;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return DropdownButtonHideUnderline(
      child: DropdownButton<T>(
        value: value,
        isDense: true,
        borderRadius: BorderRadius.circular(12),
        iconEnabledColor: accent,
        style: TextStyle(
          fontWeight: FontWeight.w600,
          fontSize: 14,
          color: accent,
        ),
        items: [
          for (final e in items.entries)
            DropdownMenuItem(value: e.key, child: Text(e.value)),
        ],
        selectedItemBuilder: (context) => [
          // Menu entries render on a plain surface (dark accent text is fine),
          // but the closed button must use the accent too.
          for (final e in items.entries)
            Center(
              child: Text(e.value, style: TextStyle(color: accent)),
            ),
        ],
        onChanged: enabled ? (v) => onChanged(v as T) : null,
      ),
    );
  }
}

// ---------------------------------------------------------------------------

class _SearchBar extends StatelessWidget {
  const _SearchBar({
    required this.controller,
    required this.count,
    required this.sort,
    required this.onSearch,
    required this.onSort,
  });

  final TextEditingController controller;
  final int count;
  final SortMode sort;
  final ValueChanged<String> onSearch;
  final ValueChanged<SortMode> onSort;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 6),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(color: Theme.of(context).dividerColor),
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: SizedBox(
              height: 36,
              child: TextField(
                controller: controller,
                onChanged: onSearch,
                decoration: const InputDecoration(
                  isDense: true,
                  prefixIcon: Icon(Icons.search, size: 18),
                  hintText: 'Search downloads',
                  border: OutlineInputBorder(),
                ),
              ),
            ),
          ),
          const SizedBox(width: 12),
          Text('$count item(s)', style: const TextStyle(color: Colors.grey)),
          const SizedBox(width: 8),
          PopupMenuButton<SortMode>(
            icon: const Icon(Icons.sort),
            tooltip: 'Sort',
            initialValue: sort,
            onSelected: onSort,
            itemBuilder: (_) => const [
              PopupMenuItem(
                value: SortMode.newest,
                child: Text('Newest first'),
              ),
              PopupMenuItem(
                value: SortMode.oldest,
                child: Text('Oldest first'),
              ),
              PopupMenuItem(value: SortMode.title, child: Text('Title')),
              PopupMenuItem(value: SortMode.size, child: Text('File size')),
            ],
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------

class _DownloadRow extends StatelessWidget {
  const _DownloadRow({
    required this.item,
    required this.onPlay,
    required this.onFolder,
    required this.onLink,
    required this.onCopyUrl,
    required this.onRedownload,
    required this.onRemove,
  });

  final DownloadItem item;
  final VoidCallback onPlay;
  final VoidCallback onFolder;
  final VoidCallback onLink;
  final VoidCallback onCopyUrl;
  final VoidCallback onRedownload;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final downloading = item.status == DownloadStatus.downloading;
    final failed = item.status == DownloadStatus.failed;
    final done = item.status == DownloadStatus.done;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          _Thumb(item: item),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  item.displayTitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontWeight: FontWeight.w500,
                    fontSize: 14,
                  ),
                ),
                const SizedBox(height: 2),
                if (downloading)
                  _ProgressLine(progress: item.progress)
                else if (failed)
                  Text(
                    'failed · ${item.error ?? 'unknown error'}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                      fontSize: 12,
                    ),
                  )
                else
                  Text(
                    item.subtitle.isEmpty ? item.url : item.subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: Colors.grey.shade600, fontSize: 12),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          if (done)
            _IconBtn(
              icon: Icons.play_arrow,
              tip: 'Play',
              color: _Palette.play,
              onTap: onPlay,
            ),
          if (done)
            _IconBtn(
              icon: Icons.folder_open,
              tip: 'Open folder',
              color: _Palette.openFolder,
              onTap: onFolder,
            ),
          if (!downloading)
            _IconBtn(
              icon: Icons.refresh,
              tip: failed ? 'Retry' : 'Redownload',
              color: _Palette.redownload,
              onTap: onRedownload,
            ),
          _IconBtn(
            icon: Icons.copy,
            tip: 'Copy URL',
            color: _Palette.copy,
            onTap: onCopyUrl,
          ),
          _IconBtn(
            icon: Icons.open_in_new,
            tip: 'Open link',
            color: _Palette.openLink,
            onTap: onLink,
          ),
          _IconBtn(
            icon: Icons.delete_outline,
            tip: 'Remove',
            color: _Palette.remove,
            onTap: onRemove,
          ),
        ],
      ),
    );
  }
}

class _Thumb extends StatelessWidget {
  const _Thumb({required this.item});
  final DownloadItem item;

  @override
  Widget build(BuildContext context) {
    final path = item.thumbnailPath;
    return Container(
      width: 64,
      height: 40,
      decoration: BoxDecoration(
        color: Colors.grey.shade200,
        borderRadius: BorderRadius.circular(6),
      ),
      clipBehavior: Clip.antiAlias,
      // cacheWidth: decode at display size — source thumbnails can be 4K,
      // and full-size decodes thrash the image cache on every list rebuild.
      // Missing/broken files fall through to errorBuilder (no existsSync in
      // build: synchronous disk I/O per row per frame).
      child: path != null
          ? Image.file(
              File(path),
              fit: BoxFit.cover,
              cacheWidth: 128,
              errorBuilder: (context, error, stack) => _placeholder(),
            )
          : _placeholder(),
    );
  }

  Widget _placeholder() {
    IconData icon;
    switch (item.status) {
      case DownloadStatus.failed:
        icon = Icons.error_outline;
      case DownloadStatus.downloading:
        icon = Icons.downloading;
      default:
        icon = item.kind == MediaKind.audio
            ? Icons.music_note
            : Icons.play_arrow;
    }
    return Center(child: Icon(icon, size: 20, color: Colors.grey.shade600));
  }
}

class _ProgressLine extends StatelessWidget {
  const _ProgressLine({required this.progress});
  final double progress;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(99),
            child: LinearProgressIndicator(
              value: progress > 0 ? progress : null,
              minHeight: 6,
              backgroundColor: Colors.grey.shade200,
            ),
          ),
        ),
        const SizedBox(width: 8),
        Text(
          '${(progress * 100).round()}%',
          style: const TextStyle(fontSize: 12),
        ),
      ],
    );
  }
}

class _IconBtn extends StatelessWidget {
  const _IconBtn({
    required this.icon,
    required this.tip,
    required this.onTap,
    this.color,
  });
  final IconData icon;
  final String tip;
  final VoidCallback onTap;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      icon: Icon(icon, size: 20, color: color),
      tooltip: tip,
      visualDensity: VisualDensity.compact,
      onPressed: onTap,
    );
  }
}
