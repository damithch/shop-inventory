import 'package:flutter/material.dart';

import '../models.dart';
import '../session.dart';
import '../widgets.dart';
import 'stock_action_screen.dart';

/// One item's stock at every location, its alert levels, and recent history.
class ItemDetailScreen extends StatefulWidget {
  const ItemDetailScreen({super.key, required this.itemId});

  final int itemId;

  @override
  State<ItemDetailScreen> createState() => _ItemDetailScreenState();
}

class _Detail {
  _Detail(this.item, this.movements);

  final ItemDetail item;
  final List<Movement> movements;
}

class _ItemDetailScreenState extends State<ItemDetailScreen> {
  final _loader = GlobalKey<LoaderState<_Detail>>();
  bool _changed = false;

  Future<_Detail> _load() async {
    final api = SessionScope.apiOf(context);
    final results = await Future.wait([api.item(widget.itemId), api.movements(itemId: widget.itemId, limit: 20)]);
    return _Detail(results[0] as ItemDetail, results[1] as List<Movement>);
  }

  Future<void> _reload() async {
    _changed = true;
    await _loader.currentState?.reload();
  }

  Future<void> _action(StockAction action, {int? locationId}) async {
    final changed = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) => StockActionScreen(action: action, itemId: widget.itemId, locationId: locationId),
      ),
    );
    if (changed == true) _reload();
  }

  Future<void> _editThreshold(ItemDetail detail, ItemLocationStock s) async {
    final api = SessionScope.apiOf(context);
    Future<void> save(int? value) async {
      try {
        final alerts = await api.setThreshold(itemId: detail.item.id, locationId: s.locationId, threshold: value);
        if (!mounted) return;
        await showStockAlerts(context, alerts);
        _reload();
      } catch (e) {
        if (mounted) showError(context, e);
      }
    }

    final value = await askNumber(
      context,
      title: 'Alert level at ${s.locationName}',
      message: 'You get a warning when ${detail.item.name} at ${s.locationName} drops to this number or below.',
      initial: s.threshold,
      resetLabel: s.usesDefault ? null : 'Use default',
      onReset: () => save(null),
    );
    if (value != null) await save(value);
  }

  Future<void> _edit(Item item) async {
    final name = TextEditingController(text: item.name);
    final sku = TextEditingController(text: item.sku ?? '');
    final unit = TextEditingController(text: item.unit);
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Edit item'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: name,
              decoration: const InputDecoration(labelText: 'Name'),
            ),
            TextField(
              controller: sku,
              decoration: const InputDecoration(labelText: 'Code / SKU (optional)'),
            ),
            TextField(
              controller: unit,
              decoration: const InputDecoration(labelText: 'Unit, e.g. pcs, kg, box'),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, 'archive'), child: const Text('Remove item')),
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, 'save'), child: const Text('Save')),
        ],
      ),
    );
    if (result == null || !mounted) return;
    final api = SessionScope.apiOf(context);
    try {
      if (result == 'archive') {
        final ok = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text('Remove ${item.name}?'),
            content: const Text('The item is hidden from the app. Its history is kept.'),
            actions: [
              TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
              FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Remove')),
            ],
          ),
        );
        if (ok != true) return;
        await api.updateItem(item.id, archived: true);
        if (mounted) Navigator.pop(context, true);
        return;
      }
      await api.updateItem(item.id, name: name.text.trim(), sku: sku.text.trim(), unit: unit.text.trim());
      _reload();
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope<bool>(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) Navigator.pop(context, _changed);
      },
      child: Scaffold(
        appBar: AppBar(title: const Text('Item')),
        body: Loader<_Detail>(key: _loader, load: _load, builder: (context, data, _) => _body(context, data)),
      ),
    );
  }

  Widget _body(BuildContext context, _Detail data) {
    final theme = Theme.of(context);
    final detail = data.item;
    final item = detail.item;
    return ListView(
      padding: const EdgeInsets.only(bottom: 32),
      children: [
        ListTile(
          title: Text(item.name, style: theme.textTheme.titleLarge),
          subtitle: Text([if (item.sku != null) item.sku!, 'Unit: ${item.unit}'].join(' · ')),
          trailing: IconButton(tooltip: 'Edit', icon: const Icon(Icons.edit_outlined), onPressed: () => _edit(item)),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              ActionChip(
                avatar: const Icon(Icons.add_box_outlined),
                label: const Text('Add stock'),
                onPressed: () => _action(StockAction.receive),
              ),
              ActionChip(
                avatar: const Icon(Icons.local_shipping_outlined),
                label: const Text('Move'),
                onPressed: () => _action(StockAction.transfer),
              ),
              ActionChip(
                avatar: const Icon(Icons.point_of_sale),
                label: const Text('Sale'),
                onPressed: () => _action(StockAction.sale),
              ),
              ActionChip(
                avatar: const Icon(Icons.fact_check_outlined),
                label: const Text('Correct count'),
                onPressed: () => _action(StockAction.adjust),
              ),
            ],
          ),
        ),
        _Header('Stock by location (tap to change the alert level)'),
        for (final s in detail.stock)
          ListTile(
            leading: Icon(s.isMain ? Icons.storefront : Icons.store_mall_directory_outlined),
            title: Text(s.locationName),
            subtitle: Text('Alert at ${s.threshold}${s.usesDefault ? ' (default)' : ''}'),
            trailing: QuantityBadge(quantity: s.quantity, low: s.low),
            onTap: () => _editThreshold(detail, s),
          ),
        ListTile(
          title: const Text('Total'),
          trailing: Text(
            '${detail.stock.fold<int>(0, (sum, s) => sum + s.quantity)} ${item.unit}',
            style: theme.textTheme.titleMedium,
          ),
        ),
        _Header('Recent changes'),
        if (data.movements.isEmpty) const ListTile(title: Text('No changes yet')),
        for (final m in data.movements)
          ListTile(
            dense: true,
            title: Text(m.description),
            subtitle: Text([formatDate(m.createdAt), if (m.note != null) m.note!].join(' · ')),
          ),
      ],
    );
  }
}

class _Header extends StatelessWidget {
  const _Header(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
    child: Text(
      text,
      style: Theme.of(context).textTheme.titleSmall?.copyWith(color: Theme.of(context).colorScheme.primary),
    ),
  );
}
