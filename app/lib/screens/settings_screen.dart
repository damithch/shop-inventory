import 'package:flutter/material.dart';

import '../models.dart';
import '../session.dart';
import '../widgets.dart';
import 'export_screen.dart';
import 'reset_screen.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _loader = GlobalKey<LoaderState<int>>();

  Future<void> _editDefault(int current) async {
    final value = await askNumber(
      context,
      title: 'Default alert level',
      message:
          'You get a low-stock warning when an item drops to this number or below. '
          'Items with their own alert level keep it.',
      initial: current,
    );
    if (value == null || !mounted) return;
    try {
      await SessionScope.apiOf(context).setDefaultThreshold(value);
      if (mounted) showMessage(context, 'Default alert level set to $value');
      _loader.currentState?.reload();
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = SessionScope.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: Loader<int>(
        key: _loader,
        load: () => session.api.defaultThreshold(),
        builder: (context, threshold, _) => ListView(
          children: [
            ListTile(
              leading: const Icon(Icons.notifications_active_outlined),
              title: const Text('Default alert level'),
              subtitle: Text('Warn when $threshold or fewer are left'),
              trailing: const Icon(Icons.edit_outlined),
              onTap: () => _editDefault(threshold),
            ),
            ListTile(
              leading: const Icon(Icons.history),
              title: const Text('Alert history'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const AlertHistoryScreen())),
            ),
            ListTile(
              leading: const Icon(Icons.file_download_outlined),
              title: const Text('Export to Excel or CSV'),
              subtitle: const Text('Stock at each place, or the item list'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const ExportScreen())),
            ),
            ListTile(
              leading: const Icon(Icons.restart_alt),
              title: const Text('Reset and delete'),
              subtitle: const Text('Set stock to zero, delete items or a branch'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const ResetScreen())),
            ),
            const Divider(),
            ListTile(
              leading: const Icon(Icons.dns_outlined),
              title: const Text('Server'),
              subtitle: Text(session.baseUrl),
            ),
            ListTile(leading: const Icon(Icons.logout), title: const Text('Sign out'), onTap: session.signOut),
          ],
        ),
      ),
    );
  }
}

class AlertHistoryScreen extends StatelessWidget {
  const AlertHistoryScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final api = SessionScope.apiOf(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Alert history')),
      body: Loader<List<AlertRecord>>(
        load: () => api.alerts(limit: 100),
        builder: (context, alerts, _) {
          if (alerts.isEmpty) {
            return ListView(
              padding: const EdgeInsets.all(32),
              children: const [Text('No low-stock alerts yet.', textAlign: TextAlign.center)],
            );
          }
          return ListView.separated(
            itemCount: alerts.length,
            separatorBuilder: (_, _) => const Divider(height: 1),
            itemBuilder: (context, i) {
              final a = alerts[i];
              return ListTile(
                title: Text('${a.itemName} at ${a.locationName}'),
                subtitle: Text('${a.quantity} left, alert level ${a.threshold} · ${formatDate(a.createdAt)}'),
              );
            },
          );
        },
      ),
    );
  }
}
