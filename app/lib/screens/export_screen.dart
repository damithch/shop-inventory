import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../models.dart';
import '../session.dart';
import '../widgets.dart';

/// Opens the phone's share sheet (WhatsApp, Gmail, Drive...) with the file.
Future<void> shareFileFromPhone(ExportFile file) async {
  await SharePlus.instance.share(
    ShareParams(
      files: [XFile.fromData(file.bytes, name: file.name, mimeType: file.mimeType)],
      fileNameOverrides: [file.name],
      subject: file.name,
    ),
  );
}

/// Asks where to save the file on the phone. Returns false if cancelled.
Future<bool> saveFileToPhone(ExportFile file) async {
  final uri = await FilePicker.saveFile(fileName: file.name, bytes: file.bytes, mimeType: file.mimeType);
  return uri != null;
}

/// How the export screen shares and saves files. Tests replace them, since
/// they can't open the share sheet or the phone's file picker.
Future<void> Function(ExportFile file) shareExport = shareFileFromPhone;
Future<bool> Function(ExportFile file) saveExport = saveFileToPhone;

/// Download stock (one place or all) or the item list as Excel or CSV, then
/// share it or save it on the phone.
class ExportScreen extends StatefulWidget {
  const ExportScreen({super.key});

  @override
  State<ExportScreen> createState() => _ExportScreenState();
}

class _ExportScreenState extends State<ExportScreen> {
  static const _allLocations = 'all';
  static const _items = 'items';

  // _allLocations, _items, or a location id.
  String _what = _allLocations;
  ExportFormat _format = ExportFormat.xlsx;
  bool _busy = false;

  Future<void> _export({required bool share}) async {
    final api = SessionScope.apiOf(context);
    setState(() => _busy = true);
    try {
      final file = switch (_what) {
        _items => await api.exportItems(format: _format),
        _allLocations => await api.exportStock(format: _format),
        _ => await api.exportStock(locationId: int.parse(_what), format: _format),
      };
      if (share) {
        await shareExport(file);
      } else if (await saveExport(file)) {
        if (mounted) showMessage(context, 'Saved ${file.name}');
      }
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _describe() {
    if (_what == _items) return 'Every item with its total stock and the date it was added.';
    if (_what == _allLocations) {
      return _format == ExportFormat.xlsx
          ? 'A summary sheet with each place\'s count and the total, then a sheet for every place.'
          : 'Each item with its count at every place and the total.';
    }
    return 'Every item\'s count there, with its alert level. After counting, '
        'the same file can be uploaded as a stock sheet for that place.';
  }

  @override
  Widget build(BuildContext context) {
    final api = SessionScope.apiOf(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Export')),
      body: Loader<List<Location>>(
        pullToRefresh: false,
        load: api.locations,
        builder: (context, locations, _) => ListView(
          padding: const EdgeInsets.all(16),
          children: [
            DropdownButtonFormField<String>(
              initialValue: _what,
              decoration: const InputDecoration(labelText: 'What to export', border: OutlineInputBorder()),
              items: [
                const DropdownMenuItem(value: _allLocations, child: Text('Stock at all places')),
                for (final l in locations) DropdownMenuItem(value: '${l.id}', child: Text('Stock at ${l.name}')),
                const DropdownMenuItem(value: _items, child: Text('Item list')),
              ],
              onChanged: _busy ? null : (v) => setState(() => _what = v ?? _allLocations),
            ),
            const SizedBox(height: 16),
            SegmentedButton<ExportFormat>(
              segments: [for (final f in ExportFormat.values) ButtonSegment(value: f, label: Text(f.label))],
              selected: {_format},
              onSelectionChanged: _busy ? null : (s) => setState(() => _format = s.single),
            ),
            const SizedBox(height: 12),
            Text(_describe(), style: Theme.of(context).textTheme.bodyMedium),
            const SizedBox(height: 24),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _busy ? null : () => _export(share: false),
                    icon: const Icon(Icons.download_outlined),
                    label: const Text('Save to phone'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton.icon(
                    onPressed: _busy ? null : () => _export(share: true),
                    icon: const Icon(Icons.share_outlined),
                    label: const Text('Share'),
                  ),
                ),
              ],
            ),
            if (_busy)
              const Padding(
                padding: EdgeInsets.only(top: 24),
                child: Center(child: CircularProgressIndicator()),
              ),
          ],
        ),
      ),
    );
  }
}
