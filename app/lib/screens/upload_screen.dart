import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../models.dart';
import '../session.dart';
import '../widgets.dart';

/// A file the user picked: its name and contents.
class PickedSheet {
  const PickedSheet(this.name, this.bytes);

  final String name;
  final List<int> bytes;
}

/// Opens the phone's file picker for an Excel or CSV file. Returns null if cancelled.
Future<PickedSheet?> pickSheetFromPhone() async {
  final file = await FilePicker.pickFile(type: FileType.custom, allowedExtensions: ['xlsx', 'csv']);
  if (file == null) return null;
  return PickedSheet(file.name, await file.readAsBytes());
}

/// How the upload screen gets a file. Tests replace it, since they can't open
/// the phone's file picker.
Future<PickedSheet?> Function() pickSheet = pickSheetFromPhone;

/// Upload a stock sheet: pick the file and the location, check the preview,
/// then save. Pops with true once saved.
class UploadScreen extends StatefulWidget {
  const UploadScreen({super.key});

  @override
  State<UploadScreen> createState() => _UploadScreenState();
}

class _UploadScreenState extends State<UploadScreen> {
  List<Location>? _locations;
  int? _locationId;
  PickedSheet? _file;
  UploadPreview? _preview;
  bool _busy = false;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _loadLocations();
  }

  Future<void> _loadLocations() async {
    try {
      final all = await SessionScope.apiOf(context).locations();
      if (!mounted) return;
      setState(() {
        _locations = all.where((l) => !l.archived).toList();
        _locationId = _locations!.firstWhere((l) => l.isMain, orElse: () => _locations!.first).id;
      });
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  Future<void> _pick() async {
    final file = await pickSheet();
    if (file == null || !mounted) return;
    setState(() => _file = file);
    await _loadPreview();
  }

  Future<void> _loadPreview() async {
    final file = _file;
    if (file == null) return;
    setState(() {
      _busy = true;
      _error = null;
      _preview = null;
    });
    try {
      final preview = await SessionScope.apiOf(context)
          .previewUpload(filename: file.name, bytes: file.bytes, locationId: _locationId);
      if (mounted) setState(() => _preview = preview);
    } catch (e) {
      if (mounted) setState(() => _error = e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _save() async {
    final file = _file!;
    setState(() => _busy = true);
    try {
      final result = await SessionScope.apiOf(context)
          .upload(filename: file.name, bytes: file.bytes, locationId: _locationId);
      if (!mounted) return;
      final s = result.summary;
      showMessage(context, 'Saved: ${s.newItems} new items, ${s.sold} sold, ${s.received} received');
      await showStockAlerts(context, result.alerts);
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final locations = _locations;
    final preview = _preview;
    final nothingToSave = preview != null && preview.summary.newItems == 0 && preview.summary.changedItems == 0;
    return Scaffold(
      appBar: AppBar(title: const Text('Upload stock sheet')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text(
            'Upload the stock count as an Excel (.xlsx) or CSV file. New items are added. '
            'For items already in the app, a lower count than the app has is recorded as sold, '
            'and a higher one as stock received.',
          ),
          const SizedBox(height: 16),
          if (locations != null)
            DropdownButtonFormField<int>(
              initialValue: _locationId,
              decoration: const InputDecoration(labelText: 'Stock count is for', border: OutlineInputBorder()),
              items: [for (final l in locations) DropdownMenuItem(value: l.id, child: Text(l.name))],
              onChanged: _busy
                  ? null
                  : (id) {
                      setState(() => _locationId = id);
                      _loadPreview();
                    },
            ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: _busy || locations == null ? null : _pick,
            icon: const Icon(Icons.upload_file),
            label: Text(_file == null ? 'Choose file' : _file!.name),
          ),
          const SizedBox(height: 16),
          if (_busy && preview == null) const Center(child: CircularProgressIndicator()),
          if (_error != null) Text('$_error', style: TextStyle(color: Theme.of(context).colorScheme.error)),
          if (preview != null) _PreviewView(preview: preview),
        ],
      ),
      bottomNavigationBar: preview == null
          ? null
          : SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: FilledButton(
                  onPressed: _busy || nothingToSave ? null : _save,
                  child: Text(nothingToSave ? 'Nothing to change' : 'Save'),
                ),
              ),
            ),
    );
  }
}

class _PreviewView extends StatelessWidget {
  const _PreviewView({required this.preview});

  final UploadPreview preview;

  @override
  Widget build(BuildContext context) {
    final s = preview.summary;
    final theme = Theme.of(context);
    final sold = preview.changes.where((c) => c.isSale).toList();
    final received = preview.changes.where((c) => !c.isSale).toList();
    final lookalikes = preview.newItems.where((i) => i.similarTo.isNotEmpty).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('If you save this sheet', style: theme.textTheme.titleMedium),
                const SizedBox(height: 8),
                Text('${s.newItems} new items (${s.newStock} in stock)'),
                Text('${s.sold} sold'),
                Text('${s.received} received'),
                Text('${s.unchangedItems} items unchanged'),
                if (s.skippedRows > 0) Text('${s.skippedRows} rows can\'t be used'),
              ],
            ),
          ),
        ),
        for (final note in preview.notes) _Notice(icon: Icons.info_outline, text: note),
        for (final entry in preview.stockColumns.entries)
          _Notice(icon: Icons.view_column_outlined, text: 'Column "${entry.key}" is stock at ${entry.value}'),
        if (preview.ignoredColumns.isNotEmpty)
          _Notice(
            icon: Icons.visibility_off_outlined,
            text: 'Not used: ${preview.ignoredColumns.map((c) => '"$c"').join(', ')}',
          ),
        if (lookalikes.isNotEmpty)
          _Notice(
            icon: Icons.warning_amber_rounded,
            warning: true,
            text:
                '${lookalikes.length} new items look like items already in the app. If they are the same, '
                'rename them in the sheet so they match, or they will be added as separate items.',
          ),
        _Section(
          title: 'Sold (${sold.length})',
          children: [
            for (final c in sold)
              ListTile(
                dense: true,
                title: Text(c.itemName),
                subtitle: Text(c.locationName),
                trailing: Text('${c.from} → ${c.to}  (−${c.from - c.to})'),
              ),
          ],
        ),
        _Section(
          title: 'Received (${received.length})',
          children: [
            for (final c in received)
              ListTile(
                dense: true,
                title: Text(c.itemName),
                subtitle: Text(c.locationName),
                trailing: Text('${c.from} → ${c.to}  (+${c.to - c.from})'),
              ),
          ],
        ),
        _Section(
          title: 'New items (${preview.newItems.length})',
          initiallyExpanded: lookalikes.isNotEmpty,
          children: [
            for (final i in preview.newItems)
              ListTile(
                dense: true,
                title: Text(i.name),
                subtitle: i.similarTo.isEmpty
                    ? null
                    : Text('Looks like: ${i.similarTo.join(', ')}', style: TextStyle(color: theme.colorScheme.error)),
                trailing: Text(i.stock.isEmpty ? '0' : i.stock.entries.map((e) => '${e.value} at ${e.key}').join(', ')),
              ),
          ],
        ),
        _Section(
          title: 'Can\'t be used (${preview.skipped.length})',
          initiallyExpanded: preview.skipped.isNotEmpty,
          children: [
            for (final r in preview.skipped)
              ListTile(dense: true, title: Text('Row ${r.row}: ${r.item}'), subtitle: Text(r.reason)),
          ],
        ),
      ],
    );
  }
}

class _Notice extends StatelessWidget {
  const _Notice({required this.icon, required this.text, this.warning = false});

  final IconData icon;
  final String text;
  final bool warning;

  @override
  Widget build(BuildContext context) {
    final color = warning ? Theme.of(context).colorScheme.error : null;
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(icon, color: color),
      title: Text(text, style: TextStyle(color: color)),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.children, this.initiallyExpanded = false});

  final String title;
  final List<Widget> children;
  final bool initiallyExpanded;

  @override
  Widget build(BuildContext context) {
    if (children.isEmpty) return const SizedBox.shrink();
    return ExpansionTile(
      title: Text(title),
      initiallyExpanded: initiallyExpanded,
      tilePadding: EdgeInsets.zero,
      children: children,
    );
  }
}
