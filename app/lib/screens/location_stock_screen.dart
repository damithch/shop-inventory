import 'package:flutter/material.dart';

import '../models.dart';
import '../session.dart';
import '../widgets.dart';
import 'item_detail_screen.dart';
import 'new_item_screen.dart';
import 'paste_screen.dart';
import 'stock_action_screen.dart';

/// Every item's count at one location (the main shop or a branch), with the
/// actions that make sense there.
class LocationStockScreen extends StatefulWidget {
  const LocationStockScreen({super.key, required this.location});

  final Location location;

  @override
  State<LocationStockScreen> createState() => _LocationStockScreenState();
}

class _LocationStockScreenState extends State<LocationStockScreen> {
  final _loader = GlobalKey<LoaderState<LocationStock>>();
  final _search = TextEditingController();
  String _query = '';
  bool _lowOnly = false;
  late Location _location = widget.location;

  Future<void> _reload() async => _loader.currentState?.reload();

  Future<void> _open(Widget screen) async {
    final changed = await Navigator.push<bool>(context, MaterialPageRoute(builder: (_) => screen));
    if (changed == true) _reload();
  }

  void _openAction(StockAction action) => _open(StockActionScreen(action: action, locationId: _location.id));

  Future<void> _rename() async {
    final controller = TextEditingController(text: _location.name);
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Rename'),
        content: TextField(controller: controller, autofocus: true, textCapitalization: TextCapitalization.words),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, controller.text.trim()), child: const Text('Save')),
        ],
      ),
    );
    if (name == null || name.isEmpty || !mounted) return;
    try {
      final updated = await SessionScope.apiOf(context).updateLocation(_location.id, name: name);
      setState(() => _location = updated);
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _archive() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Remove ${_location.name}?'),
        content: const Text('The branch is hidden from the app. Its history is kept.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Remove')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      await SessionScope.apiOf(context).updateLocation(_location.id, archived: true);
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  List<_ActionTile> _actions() => [
    if (_location.isMain) ...[
      _ActionTile(Icons.add_box_outlined, 'Add stock', () => _openAction(StockAction.receive)),
      _ActionTile(Icons.local_shipping_outlined, 'Move stock to a branch', () => _openAction(StockAction.transfer)),
    ],
    _ActionTile(Icons.point_of_sale, 'Record sale', () => _openAction(StockAction.sale)),
    if (!_location.isMain)
      _ActionTile(Icons.local_shipping_outlined, 'Move stock from here', () => _openAction(StockAction.transfer)),
    _ActionTile(
      Icons.playlist_play,
      'Move a list of items',
      () => _open(PasteScreen(action: PasteAction.transfer, fromLocationId: _location.id)),
    ),
    _ActionTile(
      Icons.receipt_long_outlined,
      'Record sales from a list',
      () => _open(PasteScreen(action: PasteAction.sale, fromLocationId: _location.id)),
    ),
    _ActionTile(Icons.fact_check_outlined, 'Correct a count', () => _openAction(StockAction.adjust)),
    if (_location.isMain) _ActionTile(Icons.playlist_add, 'New item', () => _open(const NewItemScreen())),
  ];

  void _showActions() {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final tile in _actions())
              ListTile(
                leading: Icon(tile.icon),
                title: Text(tile.label),
                onTap: () {
                  Navigator.pop(sheetContext);
                  tile.onTap();
                },
              ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final api = SessionScope.apiOf(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(_location.name),
        actions: [
          IconButton(tooltip: 'Refresh', onPressed: _reload, icon: const Icon(Icons.refresh)),
          PopupMenuButton<String>(
            onSelected: (v) => v == 'rename' ? _rename() : _archive(),
            itemBuilder: (_) => [
              const PopupMenuItem(value: 'rename', child: Text('Rename')),
              if (!_location.isMain) const PopupMenuItem(value: 'archive', child: Text('Remove branch')),
            ],
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        heroTag: null,
        onPressed: _showActions,
        icon: const Icon(Icons.swap_vert),
        label: const Text('Stock'),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: TextField(
              controller: _search,
              decoration: InputDecoration(
                hintText: 'Search items',
                prefixIcon: const Icon(Icons.search),
                border: const OutlineInputBorder(),
                isDense: true,
                suffixIcon: _query.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.clear),
                        onPressed: () {
                          _search.clear();
                          setState(() => _query = '');
                        },
                      ),
              ),
              onChanged: (v) => setState(() => _query = v.trim().toLowerCase()),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                FilterChip(
                  label: const Text('Low stock only'),
                  selected: _lowOnly,
                  onSelected: (v) => setState(() => _lowOnly = v),
                ),
              ],
            ),
          ),
          Expanded(
            child: Loader<LocationStock>(
              key: _loader,
              load: () => api.locationStock(_location.id),
              builder: (context, data, _) {
                final lines = data.items.where((l) {
                  if (_lowOnly && !l.low) return false;
                  if (_query.isEmpty) return true;
                  return l.name.toLowerCase().contains(_query) || (l.sku?.toLowerCase().contains(_query) ?? false);
                }).toList();
                if (lines.isEmpty) {
                  return ListView(
                    padding: const EdgeInsets.all(32),
                    children: [
                      Text(
                        data.items.isEmpty
                            ? (_location.isMain
                                  ? 'No items yet. Tap Stock, then New item to add your first one.'
                                  : 'No items yet.')
                            : 'Nothing matches.',
                        textAlign: TextAlign.center,
                      ),
                    ],
                  );
                }
                return ListView.separated(
                  padding: const EdgeInsets.only(bottom: 96),
                  itemCount: lines.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (context, i) {
                    final line = lines[i];
                    return ListTile(
                      title: Text(line.name),
                      subtitle: Text([if (line.sku != null) line.sku!, 'Alert at ${line.threshold}'].join(' · ')),
                      trailing: QuantityBadge(quantity: line.quantity, low: line.low, unit: line.unit),
                      onTap: () => _open(ItemDetailScreen(itemId: line.itemId)),
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _ActionTile {
  _ActionTile(this.icon, this.label, this.onTap);

  final IconData icon;
  final String label;
  final VoidCallback onTap;
}
