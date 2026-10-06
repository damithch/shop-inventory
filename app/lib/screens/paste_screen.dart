import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models.dart';
import '../session.dart';
import '../widgets.dart';

/// Paste rows copied from Excel: purchases received, stock moved
/// from the main shop to a branch, or sales. Check the preview, then save.
/// Pops with true once saved.
class PasteScreen extends StatefulWidget {
  const PasteScreen({super.key});

  @override
  State<PasteScreen> createState() => _PasteScreenState();
}

class _PasteScreenState extends State<PasteScreen> {
  final _text = TextEditingController();
  List<Location>? _locations;
  PasteAction _action = PasteAction.receive;
  int? _from;
  int? _to;
  PastePreview? _preview;
  bool _busy = false;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _loadLocations();
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _loadLocations() async {
    try {
      final all = await SessionScope.apiOf(context).locations();
      if (!mounted) return;
      setState(() {
        _locations = all.where((l) => !l.archived).toList();
        _setDefaults();
      });
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  Location get _main => _locations!.firstWhere((l) => l.isMain, orElse: () => _locations!.first);

  /// Purchases arrive at the main shop, transfers go from it to a branch, and
  /// sales are at a branch.
  void _setDefaults() {
    final branches = _locations!.where((l) => !l.isMain).toList();
    final branch = branches.isEmpty ? _main.id : branches.first.id;
    _from = _action == PasteAction.sale ? branch : _main.id;
    _to = _action == PasteAction.transfer ? branch : _main.id;
  }

  void _changed(VoidCallback change) {
    setState(() {
      change();
      _preview = null;
      _error = null;
    });
  }

  Future<void> _pasteFromClipboard() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text ?? '';
    if (!mounted) return;
    if (text.trim().isEmpty) {
      showMessage(context, 'Nothing copied yet. Copy the rows in Excel first.');
      return;
    }
    _changed(() => _text.text = text);
  }

  int? get _locationId => _action == PasteAction.receive ? _to : _from;
  int? get _toLocationId => _action == PasteAction.transfer ? _to : null;

  Future<void> _check() async {
    FocusScope.of(context).unfocus();
    setState(() {
      _busy = true;
      _error = null;
      _preview = null;
    });
    try {
      final preview = await SessionScope.apiOf(context)
          .previewPaste(action: _action, text: _text.text, locationId: _locationId, toLocationId: _toLocationId);
      if (mounted) setState(() => _preview = preview);
    } catch (e) {
      if (mounted) setState(() => _error = e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _save() async {
    setState(() => _busy = true);
    try {
      final result = await SessionScope.apiOf(context)
          .savePaste(action: _action, text: _text.text, locationId: _locationId, toLocationId: _toLocationId);
      if (!mounted) return;
      final s = result.summary;
      showMessage(context, switch (_action) {
        PasteAction.receive => 'Saved: ${s.received} received',
        PasteAction.transfer => 'Saved: ${s.transferred} moved',
        PasteAction.sale => 'Saved: ${s.sold} sold',
      });
      await showStockAlerts(context, result.alerts);
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _place(String label, int? value, ValueChanged<int?> onChanged) {
    return DropdownButtonFormField<int>(
      key: ValueKey('$label $_action'),
      initialValue: value,
      decoration: InputDecoration(labelText: label, border: const OutlineInputBorder()),
      items: [for (final l in _locations!) DropdownMenuItem(value: l.id, child: Text(l.name))],
      onChanged: _busy ? null : (id) => _changed(() => onChanged(id)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final locations = _locations;
    final preview = _preview;
    final canSave = preview != null && preview.lines.isNotEmpty;
    return Scaffold(
      appBar: AppBar(title: const Text('Paste list')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          SegmentedButton<PasteAction>(
            segments: [for (final a in PasteAction.values) ButtonSegment(value: a, label: Text(a.label))],
            selected: {_action},
            onSelectionChanged: _busy
                ? null
                : (s) => _changed(() {
                    _action = s.single;
                    if (locations != null) _setDefaults();
                  }),
          ),
          const SizedBox(height: 16),
          if (locations != null)
            ...switch (_action) {
              PasteAction.receive => [_place('Stock arrives at', _to, (id) => _to = id)],
              PasteAction.transfer => [
                _place('From', _from, (id) => _from = id),
                const SizedBox(height: 12),
                _place('To', _to, (id) => _to = id),
              ],
              PasteAction.sale => [_place('Sold at', _from, (id) => _from = id)],
            },
          const SizedBox(height: 12),
          TextField(
            controller: _text,
            minLines: 6,
            maxLines: 14,
            enabled: !_busy,
            onChanged: (_) => _changed(() {}),
            decoration: InputDecoration(
              labelText: 'Items and quantities',
              hintText: 'One item per line, for example:\nAFNAN 9AM 2\nYARA x 3',
              alignLabelWithHint: true,
              border: const OutlineInputBorder(),
              suffixIcon: IconButton(
                tooltip: 'Clear',
                icon: const Icon(Icons.clear),
                onPressed: _busy ? null : () => _changed(_text.clear),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _busy ? null : _pasteFromClipboard,
                  icon: const Icon(Icons.content_paste),
                  label: const Text('Paste'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton.tonalIcon(
                  onPressed: _busy || locations == null || _text.text.trim().isEmpty ? null : _check,
                  icon: const Icon(Icons.fact_check_outlined),
                  label: const Text('Check list'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          if (_busy && preview == null) const Center(child: CircularProgressIndicator()),
          if (_error != null) Text('$_error', style: TextStyle(color: Theme.of(context).colorScheme.error)),
          if (preview != null) _PastePreviewView(action: _action, preview: preview),
        ],
      ),
      bottomNavigationBar: preview == null
          ? null
          : SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: FilledButton(
                  onPressed: _busy || !canSave ? null : _save,
                  child: Text(canSave ? 'Save' : 'Nothing to save'),
                ),
              ),
            ),
    );
  }
}

class _PastePreviewView extends StatelessWidget {
  const _PastePreviewView({required this.action, required this.preview});

  final PasteAction action;
  final PastePreview preview;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final s = preview.summary;
    final lookalikes = preview.lines.where((l) => l.newItem && l.similarTo.isNotEmpty).length;
    final units = preview.lines.fold<int>(0, (t, l) => t + l.quantity);
    final headline = switch (action) {
      PasteAction.receive => '$units received at ${preview.toName}',
      PasteAction.transfer => '$units moved from ${preview.fromName} to ${preview.toName}',
      PasteAction.sale => '$units sold at ${preview.fromName}',
    };
    final sign = action == PasteAction.receive ? '+' : '−';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('If you save this list', style: theme.textTheme.titleMedium),
                const SizedBox(height: 8),
                Text(headline),
                Text('${preview.lines.length} items'),
                if (s.newItems > 0) Text('${s.newItems} new items will be added'),
                if (preview.skipped.isNotEmpty) Text('${preview.skipped.length} lines can\'t be used'),
              ],
            ),
          ),
        ),
        if (lookalikes > 0)
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.warning_amber_rounded, color: theme.colorScheme.error),
            title: Text(
              '$lookalikes new items look like items already in the app. If they are the same, '
              'fix the name in the list so it matches, or they will be added as separate items.',
              style: TextStyle(color: theme.colorScheme.error),
            ),
          ),
        if (preview.skipped.isNotEmpty)
          ExpansionTile(
            title: Text('Can\'t be used (${preview.skipped.length})'),
            initiallyExpanded: true,
            tilePadding: EdgeInsets.zero,
            children: [
              for (final r in preview.skipped)
                ListTile(dense: true, title: Text('Line ${r.row}: ${r.item}'), subtitle: Text(r.reason)),
            ],
          ),
        ExpansionTile(
          title: Text('Items (${preview.lines.length})'),
          initiallyExpanded: preview.lines.length <= 30,
          tilePadding: EdgeInsets.zero,
          children: [
            for (final l in preview.lines)
              ListTile(
                dense: true,
                title: Text(l.itemName),
                subtitle: !l.newItem
                    ? null
                    : Text(
                        l.similarTo.isEmpty ? 'New item' : 'New item. Looks like: ${l.similarTo.join(', ')}',
                        style: l.similarTo.isEmpty ? null : TextStyle(color: theme.colorScheme.error),
                      ),
                trailing: Text('$sign${l.quantity}', style: const TextStyle(fontWeight: FontWeight.w600)),
              ),
          ],
        ),
      ],
    );
  }
}
