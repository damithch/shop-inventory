import 'package:flutter/material.dart';

import '../models.dart';
import '../session.dart';
import '../widgets.dart';

enum StockAction {
  receive('Add stock', 'Add'),
  transfer('Move stock', 'Move'),
  sale('Record sale', 'Record sale'),
  adjust('Correct a count', 'Save count');

  const StockAction(this.title, this.button);

  final String title;
  final String button;
}

/// One form for every stock change: add, move, sell, or correct a count.
class StockActionScreen extends StatefulWidget {
  const StockActionScreen({super.key, required this.action, this.locationId, this.toLocationId, this.itemId});

  final StockAction action;

  /// The location the user came from. For a move it is where stock leaves.
  final int? locationId;

  /// For a move, where the stock goes.
  final int? toLocationId;
  final int? itemId;

  @override
  State<StockActionScreen> createState() => _StockActionScreenState();
}

class _Data {
  _Data(this.items, this.locations);

  final List<Item> items;
  final List<Location> locations;
}

class _StockActionScreenState extends State<StockActionScreen> {
  final _formKey = GlobalKey<FormState>();
  final _quantity = TextEditingController();
  final _note = TextEditingController();
  final _itemController = TextEditingController();

  int? _itemId;
  int? _locationId; // receive, sale, adjust: where. transfer: from.
  int? _toLocationId;
  ItemDetail? _itemDetail;
  bool _busy = false;
  bool _initialised = false;

  StockAction get action => widget.action;

  Future<_Data> _load() async {
    final api = SessionScope.apiOf(context);
    final results = await Future.wait([api.items(), api.locations()]);
    return _Data(results[0] as List<Item>, results[1] as List<Location>);
  }

  void _initFrom(_Data data) {
    if (_initialised) return;
    _initialised = true;
    final main = data.locations.firstWhere((l) => l.isMain, orElse: () => data.locations.first);
    _locationId = widget.locationId ?? main.id;
    if (action == StockAction.transfer) {
      final others = data.locations.where((l) => l.id != _locationId).toList();
      // From the main shop, suggest the first branch; from a branch, suggest sending back to main.
      _toLocationId =
          widget.toLocationId ?? (others.isEmpty ? null : (others.any((l) => l.isMain) ? main.id : others.first.id));
    }
    if (widget.itemId != null) {
      final match = data.items.where((i) => i.id == widget.itemId);
      if (match.isNotEmpty) {
        _itemId = match.first.id;
        _itemController.text = match.first.name;
        WidgetsBinding.instance.addPostFrameCallback((_) => _loadDetail(match.first));
      }
    }
  }

  void _selectItem(Item item) {
    setState(() {
      _itemId = item.id;
      _itemController.text = item.name;
      _itemDetail = null;
    });
    _loadDetail(item);
  }

  Future<void> _loadDetail(Item item) async {
    try {
      final detail = await SessionScope.apiOf(context).item(item.id);
      if (mounted && _itemId == item.id) setState(() => _itemDetail = detail);
    } catch (_) {
      // The counts are only a hint; the form still works without them.
    }
  }

  int? _countAt(int? locationId) {
    final match = _itemDetail?.stock.where((s) => s.locationId == locationId);
    return (match == null || match.isEmpty) ? null : match.first.quantity;
  }

  Future<void> _submit() async {
    if (_itemId == null) {
      showError(context, 'Pick an item');
      return;
    }
    if (!_formKey.currentState!.validate()) return;
    final api = SessionScope.apiOf(context);
    final qty = int.parse(_quantity.text.trim());
    final note = _note.text.trim();
    setState(() => _busy = true);
    try {
      final StockResult result;
      switch (action) {
        case StockAction.receive:
          result = await api.receive(itemId: _itemId!, quantity: qty, locationId: _locationId, note: note);
        case StockAction.transfer:
          result = await api.transfer(
            itemId: _itemId!,
            fromLocationId: _locationId,
            toLocationId: _toLocationId!,
            quantity: qty,
            note: note,
          );
        case StockAction.sale:
          result = await api.sale(itemId: _itemId!, locationId: _locationId!, quantity: qty, note: note);
        case StockAction.adjust:
          result = await api.adjust(itemId: _itemId!, locationId: _locationId!, newQuantity: qty, note: note);
      }
      if (!mounted) return;
      setState(() => _busy = false);
      await showStockAlerts(context, result.alerts);
      if (!mounted) return;
      showMessage(context, switch (action) {
        StockAction.receive => 'Added $qty',
        StockAction.transfer => 'Moved $qty',
        StockAction.sale => 'Sale of $qty recorded',
        StockAction.adjust => 'Count set to $qty',
      });
      Navigator.pop(context, true);
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(action.title)),
      body: Loader<_Data>(
        load: _load,
        pullToRefresh: false,
        builder: (context, data, _) {
          _initFrom(data);
          return _form(context, data);
        },
      ),
    );
  }

  Widget _form(BuildContext context, _Data data) {
    final theme = Theme.of(context);
    final locationItems = [for (final l in data.locations) DropdownMenuItem(value: l.id, child: Text(l.name))];
    final fromLabel = switch (action) {
      StockAction.receive => 'Add to',
      StockAction.transfer => 'From',
      StockAction.sale => 'Sold at',
      StockAction.adjust => 'Location',
    };
    final available = _countAt(_locationId);

    return Form(
      key: _formKey,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (data.items.isEmpty)
            const Padding(
              padding: EdgeInsets.only(bottom: 16),
              child: Text('There are no items yet. Add one from the main shop first (Stock, then New item).'),
            ),
          DropdownMenu<Item>(
            controller: _itemController,
            expandedInsets: EdgeInsets.zero,
            enableFilter: true,
            requestFocusOnTap: true,
            label: const Text('Item'),
            leadingIcon: const Icon(Icons.search),
            menuHeight: 320,
            dropdownMenuEntries: [
              for (final i in data.items)
                DropdownMenuEntry(
                  value: i,
                  label: i.name,
                  labelWidget: Text(i.sku == null ? i.name : '${i.name} (${i.sku})'),
                ),
            ],
            onSelected: (item) {
              if (item != null) _selectItem(item);
            },
          ),
          const SizedBox(height: 16),
          DropdownButtonFormField<int>(
            initialValue: _locationId,
            decoration: InputDecoration(labelText: fromLabel, border: const OutlineInputBorder()),
            items: locationItems,
            onChanged: (v) => setState(() {
              _locationId = v;
              if (_toLocationId == v) _toLocationId = null;
            }),
          ),
          if (action == StockAction.transfer) ...[
            const SizedBox(height: 16),
            DropdownButtonFormField<int>(
              key: ValueKey('to-$_locationId'),
              initialValue: _toLocationId,
              decoration: const InputDecoration(labelText: 'To', border: OutlineInputBorder()),
              items: [
                for (final l in data.locations)
                  if (l.id != _locationId) DropdownMenuItem(value: l.id, child: Text(l.name)),
              ],
              validator: (v) => v == null ? 'Pick where the stock goes' : null,
              onChanged: (v) => setState(() => _toLocationId = v),
            ),
          ],
          if (available != null && action != StockAction.receive)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text('In stock there now: $available', style: theme.textTheme.bodySmall),
            ),
          const SizedBox(height: 16),
          TextFormField(
            controller: _quantity,
            keyboardType: TextInputType.number,
            decoration: InputDecoration(
              labelText: action == StockAction.adjust ? 'Counted quantity' : 'Quantity',
              border: const OutlineInputBorder(),
            ),
            validator: (v) {
              final error = validateWholeNumber(v, min: action == StockAction.adjust ? 0 : 1);
              if (error != null) return error;
              final n = int.parse(v!.trim());
              if ((action == StockAction.transfer || action == StockAction.sale) &&
                  available != null &&
                  n > available) {
                return 'Only $available in stock there';
              }
              return null;
            },
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _note,
            decoration: const InputDecoration(labelText: 'Note (optional)', border: OutlineInputBorder()),
          ),
          const SizedBox(height: 24),
          FilledButton(
            onPressed: _busy ? null : _submit,
            child: _busy
                ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2))
                : Text(action.button),
          ),
        ],
      ),
    );
  }
}
