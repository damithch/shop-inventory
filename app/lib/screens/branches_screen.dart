import 'package:flutter/material.dart';

import '../models.dart';
import '../session.dart';
import '../widgets.dart';
import 'location_stock_screen.dart';

class BranchesScreen extends StatefulWidget {
  const BranchesScreen({super.key});

  @override
  State<BranchesScreen> createState() => _BranchesScreenState();
}

class _BranchesScreenState extends State<BranchesScreen> {
  final _loader = GlobalKey<LoaderState<List<Location>>>();

  Future<void> _addBranch() async {
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('New branch'),
        content: TextField(
          controller: controller,
          autofocus: true,
          textCapitalization: TextCapitalization.words,
          decoration: const InputDecoration(labelText: 'Branch name'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, controller.text.trim()), child: const Text('Add')),
        ],
      ),
    );
    if (name == null || name.isEmpty || !mounted) return;
    try {
      await SessionScope.apiOf(context).addBranch(name);
      if (mounted) showMessage(context, '$name added');
      _loader.currentState?.reload();
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final api = SessionScope.apiOf(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Branches'),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            onPressed: () => _loader.currentState?.reload(),
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        heroTag: null,
        onPressed: _addBranch,
        icon: const Icon(Icons.add),
        label: const Text('Branch'),
      ),
      body: Loader<List<Location>>(
        key: _loader,
        load: () async => (await api.locations()).where((l) => !l.isMain).toList(),
        builder: (context, branches, reload) {
          if (branches.isEmpty) {
            return ListView(
              padding: const EdgeInsets.all(32),
              children: const [Text('No branches yet. Tap Branch to add one.', textAlign: TextAlign.center)],
            );
          }
          return ListView.separated(
            padding: const EdgeInsets.only(bottom: 96),
            itemCount: branches.length,
            separatorBuilder: (_, _) => const Divider(height: 1),
            itemBuilder: (context, i) {
              final b = branches[i];
              return ListTile(
                leading: const Icon(Icons.store_mall_directory_outlined),
                title: Text(b.name),
                subtitle: Text('${b.itemCount} items · ${b.totalUnits} units'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () async {
                  await Navigator.push<bool>(
                    context,
                    MaterialPageRoute(builder: (_) => LocationStockScreen(location: b)),
                  );
                  reload();
                },
              );
            },
          );
        },
      ),
    );
  }
}
