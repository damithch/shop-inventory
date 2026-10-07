import 'package:flutter/material.dart';

import '../models.dart';
import '../session.dart';
import '../widgets.dart';
import 'export_screen.dart';

/// One reset or delete, as the confirmation dialog describes it.
class _Job {
  const _Job({
    required this.title,
    required this.message,
    required this.word,
    required this.backupLocationId,
    required this.run,
    required this.done,
  });

  final String title;
  final String message;

  /// What has to be typed to confirm, e.g. the place's name or DELETE.
  final String word;

  /// The place whose stock is saved as a backup first; null for every place.
  final int? backupLocationId;
  final Future<ResetResult> Function(String password, {required bool dryRun}) run;
  final String Function(ResetResult result) done;
}

String _units(int n) => n == 1 ? '1 unit' : '$n units';
String _items(int n) => n == 1 ? '1 item' : '$n items';

/// Set stock to zero at one place or everywhere, delete an item, every item
/// or a branch. Each asks for a typed word and the password, saves an Excel
/// backup of the stock, then does it. Sales history is always kept.
class ResetScreen extends StatefulWidget {
  const ResetScreen({super.key});

  @override
  State<ResetScreen> createState() => _ResetScreenState();
}

class _ResetScreenState extends State<ResetScreen> {
  final _loader = GlobalKey<LoaderState<List<Location>>>();
  bool _busy = false;

  Future<void> _start(_Job job) async {
    final password = await showDialog<String>(
      context: context,
      builder: (_) => _ConfirmDialog(job: job),
    );
    if (password == null || !mounted) return;
    final api = SessionScope.apiOf(context);
    setState(() => _busy = true);
    try {
      final backup = await api.exportStock(locationId: job.backupLocationId, format: ExportFormat.xlsx);
      if (!await saveExport(backup)) {
        if (mounted) showError(context, 'No backup was saved, so nothing was changed.');
        return;
      }
      final result = await job.run(password, dryRun: false);
      if (mounted) showMessage(context, '${job.done(result)} Backup saved as ${backup.name}.');
      _loader.currentState?.reload();
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  _Job _resetPlace(Location l) => _Job(
    title: 'Reset ${l.name} to zero?',
    message:
        '${_items(l.itemCount)} (${_units(l.totalUnits)}) at ${l.name} go to 0. '
        'Items stay in the list and sales history is kept.',
    word: l.name,
    backupLocationId: l.id,
    run: (password, {required dryRun}) =>
        SessionScope.apiOf(context).resetStock(locationId: l.id, password: password, dryRun: dryRun),
    done: (r) => '${l.name} reset: ${_units(r.units)} taken to zero.',
  );

  _Job _resetAll(List<Location> locations) => _Job(
    title: 'Reset every place to zero?',
    message:
        '${_units(locations.fold(0, (s, l) => s + l.totalUnits))} at ${locations.length} places go to 0. '
        'Items stay in the list and sales history is kept.',
    word: 'RESET',
    backupLocationId: null,
    run: (password, {required dryRun}) => SessionScope.apiOf(context).resetStock(password: password, dryRun: dryRun),
    done: (r) => 'Every place reset: ${_units(r.units)} taken to zero.',
  );

  _Job _deleteItem(Item item) => _Job(
    title: 'Delete ${item.name}?',
    message:
        '${_units(item.totalQuantity)} across all places go to 0, then the item is removed from every list. '
        'Its sales history is kept.',
    word: 'DELETE',
    backupLocationId: null,
    run: (password, {required dryRun}) =>
        SessionScope.apiOf(context).deleteItem(item.id, password: password, dryRun: dryRun),
    done: (r) => '${item.name} deleted.',
  );

  _Job _deleteAllItems() => _Job(
    title: 'Delete every item?',
    message:
        'All stock goes to 0 and every item is removed, for a fresh start. '
        'Places stay, and sales history is kept.',
    word: 'DELETE',
    backupLocationId: null,
    run: (password, {required dryRun}) =>
        SessionScope.apiOf(context).deleteAllItems(password: password, dryRun: dryRun),
    done: (r) => '${_items(r.deletedItems)} deleted.',
  );

  _Job _deleteBranch(Location l) => _Job(
    title: 'Delete ${l.name}?',
    message:
        '${_units(l.totalUnits)} there go to 0, then the branch is removed. '
        'Its sales history is kept and the name can be used again.',
    word: l.name,
    backupLocationId: l.id,
    run: (password, {required dryRun}) =>
        SessionScope.apiOf(context).deleteBranch(l.id, password: password, dryRun: dryRun),
    done: (r) => '${l.name} deleted.',
  );

  Future<void> _pickItemToDelete() async {
    final item = await showDialog<Item>(context: context, builder: (_) => const _ItemPicker());
    if (item != null && mounted) await _start(_deleteItem(item));
  }

  @override
  Widget build(BuildContext context) {
    final api = SessionScope.apiOf(context);
    final theme = Theme.of(context);
    final danger = theme.colorScheme.error;
    Widget heading(String text) => Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 4),
      child: Text(text, style: theme.textTheme.titleSmall?.copyWith(color: theme.colorScheme.primary)),
    );
    return Scaffold(
      appBar: AppBar(title: const Text('Reset and delete')),
      body: Stack(
        children: [
          Loader<List<Location>>(
            key: _loader,
            load: api.locations,
            builder: (context, locations, _) {
              final branches = locations.where((l) => !l.isMain).toList();
              return ListView(
                padding: const EdgeInsets.only(bottom: 32),
                children: [
                  const Padding(
                    padding: EdgeInsets.fromLTRB(16, 16, 16, 0),
                    child: Text(
                      'Each of these asks you to type a word and your password, and saves an Excel '
                      'backup of the stock on the phone before it changes anything. Sales history is kept.',
                    ),
                  ),
                  heading('Set stock to zero'),
                  ListTile(
                    enabled: !_busy,
                    leading: const Icon(Icons.restart_alt),
                    title: const Text('Reset every place'),
                    subtitle: Text('${_units(locations.fold(0, (s, l) => s + l.totalUnits))} in total'),
                    onTap: () => _start(_resetAll(locations)),
                  ),
                  for (final l in locations)
                    ListTile(
                      enabled: !_busy,
                      leading: const Icon(Icons.exposure_zero),
                      title: Text('Reset ${l.name}'),
                      subtitle: Text('${_items(l.itemCount)} · ${_units(l.totalUnits)}'),
                      onTap: () => _start(_resetPlace(l)),
                    ),
                  heading('Delete'),
                  ListTile(
                    enabled: !_busy,
                    leading: Icon(Icons.delete_outline, color: danger),
                    title: const Text('Delete an item'),
                    onTap: _pickItemToDelete,
                  ),
                  ListTile(
                    enabled: !_busy,
                    leading: Icon(Icons.delete_sweep_outlined, color: danger),
                    title: const Text('Delete all items'),
                    subtitle: const Text('For a fresh start. Places stay.'),
                    onTap: () => _start(_deleteAllItems()),
                  ),
                  for (final b in branches)
                    ListTile(
                      enabled: !_busy,
                      leading: Icon(Icons.store_mall_directory_outlined, color: danger),
                      title: Text('Delete ${b.name}'),
                      subtitle: Text(_units(b.totalUnits)),
                      onTap: () => _start(_deleteBranch(b)),
                    ),
                ],
              );
            },
          ),
          if (_busy) const Center(child: CircularProgressIndicator()),
        ],
      ),
    );
  }
}

/// Asks for the confirmation word and the password, checks the password with
/// a dry run, and returns the password when it is right.
class _ConfirmDialog extends StatefulWidget {
  const _ConfirmDialog({required this.job});

  final _Job job;

  @override
  State<_ConfirmDialog> createState() => _ConfirmDialogState();
}

class _ConfirmDialogState extends State<_ConfirmDialog> {
  final _word = TextEditingController();
  final _password = TextEditingController();
  bool _busy = false;
  String? _error;

  bool get _ready =>
      _word.text.trim().toLowerCase() == widget.job.word.trim().toLowerCase() && _password.text.isNotEmpty;

  @override
  void dispose() {
    _word.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _continue() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.job.run(_password.text, dryRun: true);
      if (mounted) Navigator.pop(context, _password.text);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AlertDialog(
      icon: Icon(Icons.warning_amber_rounded, color: scheme.error),
      title: Text(widget.job.title),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.job.message),
            const SizedBox(height: 8),
            const Text('An Excel backup is saved on the phone first.'),
            const SizedBox(height: 16),
            TextField(
              controller: _word,
              autofocus: true,
              decoration: InputDecoration(labelText: 'Type ${widget.job.word} to confirm'),
              onChanged: (_) => setState(() {}),
            ),
            TextField(
              controller: _password,
              obscureText: true,
              decoration: const InputDecoration(labelText: 'Your password'),
              onChanged: (_) => setState(() {}),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(_error!, style: TextStyle(color: scheme.error)),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: _busy ? null : () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: scheme.error, foregroundColor: scheme.onError),
          onPressed: _busy || !_ready ? null : _continue,
          child: const Text('Back up and continue'),
        ),
      ],
    );
  }
}

/// Search the item list and pick one.
class _ItemPicker extends StatefulWidget {
  const _ItemPicker();

  @override
  State<_ItemPicker> createState() => _ItemPickerState();
}

class _ItemPickerState extends State<_ItemPicker> {
  String _search = '';

  @override
  Widget build(BuildContext context) {
    final api = SessionScope.apiOf(context);
    return AlertDialog(
      title: const Text('Which item?'),
      contentPadding: const EdgeInsets.fromLTRB(8, 12, 8, 0),
      content: SizedBox(
        width: double.maxFinite,
        height: 420,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: TextField(
                autofocus: true,
                decoration: const InputDecoration(prefixIcon: Icon(Icons.search), labelText: 'Search items'),
                onChanged: (v) => setState(() => _search = v.trim().toLowerCase()),
              ),
            ),
            Expanded(
              child: Loader<List<Item>>(
                pullToRefresh: false,
                load: api.items,
                builder: (context, items, _) {
                  final shown = items.where((i) => i.name.toLowerCase().contains(_search)).toList();
                  if (shown.isEmpty) return const Center(child: Text('No items match'));
                  return ListView.builder(
                    itemCount: shown.length,
                    itemBuilder: (context, i) => ListTile(
                      title: Text(shown[i].name),
                      subtitle: Text('${shown[i].totalQuantity} in stock'),
                      onTap: () => Navigator.pop(context, shown[i]),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel'))],
    );
  }
}
