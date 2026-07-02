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
String _newId() =>
    '${DateTime.now().microsecondsSinceEpoch}_${_idCounter++}';

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
        .map(cleanVideoUrl) // single video only — strip playlist/tracking params
        .toList();
    if (urls.isEmpty) {
      _toast('No valid link found');
      return;
    }
    for (final url in urls) {
      final item = DownloadItem(id: _newId(), url: url, kind: state.defaultKind);
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

  Future<void> _copyUrl(DownloadItem item) async {
    await Clipboard.setData(ClipboardData(text: item.url));
    _toast('Link copied');
  }

  Future<void> _play(DownloadItem item) async {
    if (item.filePath == null) return;
    final res = await OpenFilex.open(item.filePath!);
    if (res.type != ResultType.done) _toast('Could not open file');
  }

  Future<void> _openLink(DownloadItem item) async {
    final uri = Uri.tryParse(item.url);
    if (uri != null) await launchUrl(uri);
  }

  Future<void> _revealFolder(DownloadItem item) async {
    final path = item.filePath;
    if (path == null) return;
    if (Platform.isWindows) {
      await Process.run('explorer', ['/select,', path]);
    } else if (Platform.isMacOS) {
      await Process.run('open', ['-R', path]);
    } else {
      await Process.run('xdg-open', [File(path).parent.path]);
    }
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

  Future<void> _pickFolder() async {
    final dir = await FilePicker.getDirectoryPath(
      dialogTitle: 'Choose download folder',
      initialDirectory: state.downloadDir,
    );
    if (dir != null) state.setDownloadDir(dir);
  }

  Future<void> _pickCookieFile() async {
    final res = await FilePicker.pickFiles(
      dialogTitle: 'Choose exported cookies.txt',
      type: FileType.custom,
      allowedExtensions: ['txt'],
    );
    final path = res?.files.single.path;
    if (path == null) return;
    state.setCookieFile(path);
    _toast('Login set: cookies file');
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
          .where((i) =>
              i.displayTitle.toLowerCase().contains(q) ||
              i.url.toLowerCase().contains(q))
          .toList();
    }
    switch (_sort) {
      case SortMode.newest:
        list.sort((a, b) => b.addedAt.compareTo(a.addedAt));
      case SortMode.oldest:
        list.sort((a, b) => a.addedAt.compareTo(b.addedAt));
      case SortMode.title:
        list.sort((a, b) =>
            a.displayTitle.toLowerCase().compareTo(b.displayTitle.toLowerCase()));
      case SortMode.size:
        list.sort((a, b) => (b.fileSizeBytes ?? 0).compareTo(a.fileSizeBytes ?? 0));
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
            Icon(Icons.download_for_offline_outlined,
                size: 56, color: Colors.grey.shade400),
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
        onRedownload: () => _start(items[i]),
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
    required this.onImport,
    required this.onExport,
  });

  final AppState state;
  final bool autoDownload;
  final ValueChanged<bool> onToggleAuto;
  final VoidCallback onPaste;
  final VoidCallback onPickFolder;
  final VoidCallback onPickCookieFile;
  final VoidCallback onImport;
  final VoidCallback onExport;

  @override
  Widget build(BuildContext context) {
    final isAudio = state.defaultKind == MediaKind.audio;
    final folderName = state.downloadDir.isEmpty
        ? '…'
        : state.downloadDir
            .split(RegExp(r'[/\\]'))
            .where((e) => e.isNotEmpty)
            .last;

    return Material(
      color: Theme.of(context).colorScheme.surfaceContainerLow,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          children: [
            FilledButton.icon(
              onPressed: onPaste,
              icon: const Icon(Icons.link, size: 18),
              label: const Text('Paste Link'),
            ),
            const SizedBox(width: 4),
            Tooltip(
              message: 'Auto-download when a link is added',
              child: Switch(value: autoDownload, onChanged: onToggleAuto),
            ),
            const SizedBox(width: 8),
            // What to download — one merged dropdown.
            _ToolChip(
              color: const Color(0xFFE3F0FD), // soft blue
              child: _ChipDropdown<MediaKind>(
                value: state.defaultKind,
                items: {
                  MediaKind.video: (Icons.videocam_outlined, 'Download Video'),
                  MediaKind.audio: (Icons.music_note_outlined, 'Download Audio'),
                },
                onChanged: (v) => state.setDefaultKind(v),
              ),
            ),
            const SizedBox(width: 8),
            // Resolution — no label, greyed out for audio. 0 = "Best"
            // (a null dropdown value would render blank and be unselectable).
            Opacity(
              opacity: isAudio ? 0.45 : 1,
              child: _ToolChip(
                color: const Color(0xFFE9F7EC), // soft green
                child: _ChipDropdown<int>(
                  value: state.defaultQuality ?? 0,
                  enabled: !isAudio,
                  items: {
                    for (final h in Quality.options)
                      h ?? 0: (Icons.high_quality_outlined, Quality.label(h)),
                  },
                  showIcon: false,
                  onChanged: (v) =>
                      state.setDefaultQuality(v == 0 ? null : v),
                ),
              ),
            ),
            const SizedBox(width: 8),
            // Output format: fixed MP4 for video, M4A/MP3 choice for audio.
            _ToolChip(
              color: const Color(0xFFFDF2E0), // soft amber
              child: isAudio
                  ? _ChipDropdown<String>(
                      value: state.audioFormat,
                      items: {
                        for (final f in AudioFormat.options)
                          f: (Icons.audio_file_outlined, f.toUpperCase()),
                      },
                      showIcon: false,
                      onChanged: (v) => state.setAudioFormat(v),
                    )
                  : const Padding(
                      padding: EdgeInsets.symmetric(vertical: 8),
                      child: Text('MP4',
                          style: TextStyle(fontWeight: FontWeight.w600)),
                    ),
            ),
            const SizedBox(width: 8),
            _ToolChip(
              color: const Color(0xFFF3E9FA), // soft purple
              child: InkWell(
                onTap: onPickFolder,
                borderRadius: BorderRadius.circular(20),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.folder_outlined, size: 18),
                      const SizedBox(width: 6),
                      Text(folderName,
                          style: const TextStyle(fontWeight: FontWeight.w600)),
                      const Icon(Icons.arrow_drop_down, size: 18),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            _ToolChip(
              color: const Color(0xFFFDE9EC), // soft pink
              child: _ChipDropdown<String>(
                value: state.cookieFilePath != null
                    ? 'file'
                    : (state.cookieBrowser ?? 'off'),
                items: {
                  'off': (Icons.person_off_outlined, 'No login'),
                  'file': (
                    Icons.cookie_outlined,
                    state.cookieFilePath == null
                        ? 'Cookies file…'
                        : state.cookieFilePath!
                            .split(RegExp(r'[/\\]'))
                            .last,
                  ),
                  'chrome': (Icons.language, 'Chrome'),
                  'edge': (Icons.language, 'Edge'),
                  'firefox': (Icons.language, 'Firefox'),
                },
                onChanged: (v) {
                  if (v == 'file') {
                    onPickCookieFile();
                  } else if (v == 'off') {
                    state.setCookieBrowser(null);
                  } else {
                    state.setCookieBrowser(v);
                  }
                },
              ),
            ),
            const Spacer(),
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
                        title: Text('Import list…'))),
                PopupMenuItem(
                    value: 'export',
                    child: ListTile(
                        leading: Icon(Icons.file_download_outlined),
                        title: Text('Export list…'))),
              ],
            ),
          ],
        ),
      ),
    );
  }
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

/// Compact dropdown used inside a [_ToolChip]: optional leading icon,
/// bold label, no underline.
class _ChipDropdown<T> extends StatelessWidget {
  const _ChipDropdown({
    required this.value,
    required this.items,
    required this.onChanged,
    this.enabled = true,
    this.showIcon = true,
  });

  final T value;
  final Map<T, (IconData, String)> items;
  final ValueChanged<T> onChanged;
  final bool enabled;
  final bool showIcon;

  @override
  Widget build(BuildContext context) {
    return DropdownButtonHideUnderline(
      child: DropdownButton<T>(
        value: value,
        isDense: true,
        borderRadius: BorderRadius.circular(12),
        style: TextStyle(
          fontWeight: FontWeight.w600,
          fontSize: 14,
          color: Theme.of(context).colorScheme.onSurface,
        ),
        items: [
          for (final e in items.entries)
            DropdownMenuItem(
              value: e.key,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (showIcon) ...[
                    Icon(e.value.$1, size: 18),
                    const SizedBox(width: 6),
                  ],
                  Text(e.value.$2),
                ],
              ),
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
            bottom: BorderSide(color: Theme.of(context).dividerColor)),
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
              PopupMenuItem(value: SortMode.newest, child: Text('Newest first')),
              PopupMenuItem(value: SortMode.oldest, child: Text('Oldest first')),
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
                      fontWeight: FontWeight.w500, fontSize: 14),
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
                        fontSize: 12),
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
            _IconBtn(icon: Icons.play_arrow, tip: 'Play', onTap: onPlay),
          if (done)
            _IconBtn(icon: Icons.folder_open, tip: 'Open folder', onTap: onFolder),
          if (!downloading)
            _IconBtn(
                icon: Icons.refresh,
                tip: failed ? 'Retry' : 'Redownload',
                onTap: onRedownload),
          _IconBtn(icon: Icons.copy, tip: 'Copy URL', onTap: onCopyUrl),
          _IconBtn(icon: Icons.open_in_new, tip: 'Open link', onTap: onLink),
          _IconBtn(icon: Icons.delete_outline, tip: 'Remove', onTap: onRemove),
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
    final hasThumb = item.thumbnailPath != null &&
        File(item.thumbnailPath!).existsSync();
    return Container(
      width: 64,
      height: 40,
      decoration: BoxDecoration(
        color: Colors.grey.shade200,
        borderRadius: BorderRadius.circular(6),
      ),
      clipBehavior: Clip.antiAlias,
      child: hasThumb
          ? Image.file(File(item.thumbnailPath!),
              fit: BoxFit.cover,
              errorBuilder: (context, error, stack) => _placeholder())
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
        Text('${(progress * 100).round()}%',
            style: const TextStyle(fontSize: 12)),
      ],
    );
  }
}

class _IconBtn extends StatelessWidget {
  const _IconBtn({required this.icon, required this.tip, required this.onTap});
  final IconData icon;
  final String tip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      icon: Icon(icon, size: 20),
      tooltip: tip,
      visualDensity: VisualDensity.compact,
      onPressed: onTap,
    );
  }
}
