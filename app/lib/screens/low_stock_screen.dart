import 'package:flutter/material.dart';

import '../models.dart';
import '../session.dart';
import '../widgets.dart';
import 'item_detail_screen.dart';
import 'stock_action_screen.dart';

/// Everything at or below its alert level, across the main shop and branches.
class LowStockScreen extends StatefulWidget {
  const LowStockScreen({super.key});

  @override
  State<LowStockScreen> createState() => _LowStockScreenState();
}

class _LowStockScreenState extends State<LowStockScreen> {
  final _loader = GlobalKey<LoaderState<List<LowStockEntry>>>();

  Future<void> _push(Widget screen) async {
    await Navigator.push<bool>(context, MaterialPageRoute(builder: (_) => screen));
    _loader.currentState?.reload();
  }

  @override
  Widget build(BuildContext context) {
    final api = SessionScope.apiOf(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Low stock'),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            onPressed: () => _loader.currentState?.reload(),
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: Loader<List<LowStockEntry>>(
        key: _loader,
        load: () => api.lowStock(),
        builder: (context, entries, _) {
          if (entries.isEmpty) {
            return ListView(
              padding: const EdgeInsets.all(32),
              children: const [Text('Nothing is running low.', textAlign: TextAlign.center)],
            );
          }
          return ListView.separated(
            itemCount: entries.length,
            separatorBuilder: (_, _) => const Divider(height: 1),
            itemBuilder: (context, i) {
              final e = entries[i];
              final isMain = e.locationType == 'main';
              return ListTile(
                leading: Icon(isMain ? Icons.storefront : Icons.store_mall_directory_outlined),
                title: Text(e.itemName),
                subtitle: Text('${e.locationName} · alert at ${e.threshold}'),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    QuantityBadge(quantity: e.quantity, low: true, unit: e.unit),
                    IconButton(
                      tooltip: isMain ? 'Add stock' : 'Refill from the main shop',
                      icon: Icon(isMain ? Icons.add_box_outlined : Icons.local_shipping_outlined),
                      onPressed: () => _push(
                        isMain
                            ? StockActionScreen(action: StockAction.receive, itemId: e.itemId, locationId: e.locationId)
                            : StockActionScreen(
                                action: StockAction.transfer,
                                itemId: e.itemId,
                                toLocationId: e.locationId,
                              ),
                      ),
                    ),
                  ],
                ),
                onTap: () => _push(ItemDetailScreen(itemId: e.itemId)),
              );
            },
          );
        },
      ),
    );
  }
}
