import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models.dart';
import '../session.dart';
import '../widgets.dart';
import 'upload_screen.dart' show PickedMatch, pickExistingItem;

/// Paste a list copied from Excel or WhatsApp: purchases received, stock moved
/// between places (a bulk move), or sales. Check the preview, then save.
/// Pops with true once saved.
class PasteScreen extends StatefulWidget {
  const PasteScreen({super.key, this.action = PasteAction.receive, this.fromLocationId});

  final PasteAction action;

  /// Where stock leaves for a move, or is sold: the place the user came from.
  final int? fromLocationId;

  @override
  State<PasteScreen> createState() => _PasteScreenState();
}

class _PasteScreenState extends State<PasteScreen> {
  final _text = TextEditingController();
  List<Location>? _locations;
  late PasteAction _action = widget.action;

  /// Pasted names the user said are an item already in the app.
  final _matches = <String, PickedMatch>{};

  /// Pasted names the user kept as new items (purchases) or left out.
  final _decided = <String>{};

  /// Pasted names the app matched by itself, but the user said aren't that item.
  final _noMatch = <String>{};
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

  /// Purchases arrive at the main shop, moves go from it (or the place the
  /// user came from) to a branch, and sales are at a branch.
  void _setDefaults() {
    final locations = _locations!;
    final given = locations.where((l) => l.id == widget.fromLocationId).firstOrNull;
    final branches = locations.where((l) => !l.isMain).toList();
    final branch = branches.isEmpty ? _main.id : branches.first.id;
    _from = given?.id ?? (_action == PasteAction.sale ? branch : _main.id);
    _to = _action == PasteAction.transfer
        ? (branches.where((l) => l.id != _from).firstOrNull ??
                  locations.firstWhere((l) => l.id != _from, orElse: () => _main))
              .id
        : _main.id;
    _placeFromText();
  }

  static String _key(String s) => s.toLowerCase().replaceAll(RegExp('[^a-z0-9]'), '');

  static int _distance(String a, String b) {
    var prev = List<int>.generate(b.length + 1, (j) => j);
    for (var i = 1; i <= a.length; i++) {
      final row = [i];
      for (var j = 1; j <= b.length; j++) {
        row.add(
          [prev[j] + 1, row[j - 1] + 1, prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1)].reduce((x, y) => x < y ? x : y),
        );
      }
      prev = row;
    }
    return prev[b.length];
  }

  /// A move list often starts with where it's going ("Dehiwela"): pick that
  /// place as the destination, allowing one wrong letter.
  void _placeFromText() {
    if (_action != PasteAction.transfer || _locations == null) return;
    for (final line in _text.text.split('\n')) {
      final n = _key(line);
      if (n.length < 3) continue;
      final place = _locations!.where((l) {
        final m = _key(l.name);
        return l.id != _from && (m == n || (n.length >= 5 && _distance(m, n) <= 1));
      }).firstOrNull;
      if (place != null) {
        _to = place.id;
        return;
      }
    }
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
      showMessage(context, 'Nothing copied yet. Copy the list in Excel or WhatsApp first.');
      return;
    }
    _changed(() {
      _text.text = text;
      _placeFromText();
    });
  }

  Map<String, int> get _matchIds => {for (final e in _matches.entries) e.key: e.value.itemId};

  Future<void> _pickMatch(String name, List<int> similarIds, List<String> similarTo, {bool autoMatched = false}) async {
    final picked = await pickExistingItem(
      context,
      name: name,
      where: 'in the list',
      similarIds: similarIds,
      similarTo: similarTo,
      noneLabel: _action == PasteAction.receive ? 'Keep as a new item' : 'Leave it out',
    );
    if (picked == null || !mounted) return;
    if (picked.keepsNew) {
      final wasMatched = _matches.containsKey(name) || autoMatched;
      setState(() {
        _matches.remove(name);
        _decided.add(name);
        if (autoMatched) _noMatch.add(name);
      });
      showMessage(context, _action == PasteAction.receive ? '"$name" will be added as a new item' : '"$name" left out');
      if (wasMatched) await _check();
      return;
    }
    setState(() {
      _decided.remove(name);
      _noMatch.remove(name);
      _matches[name] = picked;
    });
    showMessage(context, '"$name" matched to ${picked.itemName}');
    await _check();
  }

  Future<void> _unmatch(String name) async {
    setState(() => _matches.remove(name));
    await _check();
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
      final preview = await SessionScope.apiOf(context).previewPaste(
        action: _action,
        text: _text.text,
        locationId: _locationId,
        toLocationId: _toLocationId,
        matches: _matchIds,
        noMatch: _noMatch,
      );
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
      final result = await SessionScope.apiOf(context).savePaste(
        action: _action,
        text: _text.text,
        locationId: _locationId,
        toLocationId: _toLocationId,
        matches: _matchIds,
        noMatch: _noMatch,
      );
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
      key: ValueKey('$label $_action $value'),
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
            onChanged: (_) => _changed(_placeFromText),
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
          if (preview != null)
            _PastePreviewView(
              action: _action,
              preview: preview,
              matches: _matches,
              decided: _decided,
              onPick: _busy ? null : _pickMatch,
              onUnmatch: _busy ? null : _unmatch,
            ),
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
  const _PastePreviewView({
    required this.action,
    required this.preview,
    required this.matches,
    this.decided = const {},
    this.onPick,
    this.onUnmatch,
  });

  final PasteAction action;
  final PastePreview preview;
  final Map<String, PickedMatch> matches;
  final Set<String> decided;
  final void Function(String name, List<int> similarIds, List<String> similarTo, {bool autoMatched})? onPick;
  final ValueChanged<String>? onUnmatch;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final s = preview.summary;
    final lookalikes = preview.lines
        .where((l) => l.newItem && l.similarTo.isNotEmpty && !decided.contains(l.name))
        .length;
    final unknown = preview.skipped.where((r) => r.name != null && !decided.contains(r.name)).length;
    final auto = preview.lines.where((l) => l.autoMatched).length;
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
              '$lookalikes new items look like items already in the app. Tap each one to pick the item '
              'it is, or it will be added as a separate item.',
              style: TextStyle(color: theme.colorScheme.error),
            ),
          ),
        if (unknown > 0)
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.touch_app_outlined, color: theme.colorScheme.error),
            title: Text(
              '$unknown names aren\'t in the app. Tap each one to pick the item it is. '
              'The app remembers it for next time.',
              style: TextStyle(color: theme.colorScheme.error),
            ),
          ),
        if (auto > 0)
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.auto_fix_high, color: theme.colorScheme.tertiary),
            title: Text(
              '$auto short names were matched to the one item they are part of. Check them below, '
              'and tap one to change it.',
            ),
          ),
        if (matches.isNotEmpty)
          ExpansionTile(
            title: Text('Matched by you (${matches.length})'),
            initiallyExpanded: true,
            tilePadding: EdgeInsets.zero,
            children: [
              for (final m in matches.values)
                ListTile(
                  dense: true,
                  title: Text(m.sheetName),
                  subtitle: Text('is ${m.itemName}'),
                  trailing: IconButton(
                    tooltip: 'Undo',
                    icon: const Icon(Icons.undo),
                    onPressed: onUnmatch == null ? null : () => onUnmatch!(m.sheetName),
                  ),
                ),
            ],
          ),
        if (preview.skipped.isNotEmpty)
          ExpansionTile(
            title: Text('Can\'t be used (${preview.skipped.length})'),
            initiallyExpanded: true,
            tilePadding: EdgeInsets.zero,
            children: [
              for (final r in preview.skipped)
                ListTile(
                  dense: true,
                  title: Text('Line ${r.row}: ${r.item}'),
                  subtitle: Text(r.name != null && decided.contains(r.name) ? 'Left out: your choice' : r.reason),
                  trailing: r.name == null ? null : const Icon(Icons.chevron_right),
                  onTap: r.name == null || onPick == null ? null : () => onPick!(r.name!, r.similarIds, r.similarTo),
                ),
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
                onTap: onPick == null
                    ? null
                    : l.autoMatched
                    ? () =>
                          onPick!(l.name, [l.itemId!, ...l.similarIds], [l.itemName, ...l.similarTo], autoMatched: true)
                    : l.newItem
                    ? () => onPick!(l.name, l.similarIds, l.similarTo)
                    : null,
                title: Text(l.itemName),
                subtitle: l.autoMatched
                    ? Text(
                        'Matched from "${l.name}". Tap to change',
                        style: TextStyle(color: theme.colorScheme.tertiary),
                      )
                    : !l.newItem
                    ? null
                    : Text(
                        decided.contains(l.name) || l.similarTo.isEmpty
                            ? (decided.contains(l.name) ? 'New item: your choice' : 'New item')
                            : 'New item. Looks like: ${l.similarTo.join(', ')}',
                        style: decided.contains(l.name) || l.similarTo.isEmpty
                            ? null
                            : TextStyle(color: theme.colorScheme.error),
                      ),
                trailing: Text('$sign${l.quantity}', style: const TextStyle(fontWeight: FontWeight.w600)),
              ),
          ],
        ),
      ],
    );
  }
}
