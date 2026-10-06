import 'package:flutter/material.dart';

import '../models.dart';
import '../session.dart';
import '../widgets.dart';
import 'item_detail_screen.dart';
import 'upload_screen.dart';

String _isoDate(DateTime d) => '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

/// What sold on a day, from sales entered in the app and uploaded stock sheets.
class SalesScreen extends StatefulWidget {
  const SalesScreen({super.key});

  @override
  State<SalesScreen> createState() => _SalesScreenState();
}

class _SalesScreenState extends State<SalesScreen> {
  final _loader = GlobalKey<LoaderState<SalesReport>>();

  /// null means today in the shop's time zone, which the server works out.
  DateTime? _day;

  /// Show only this location's sales; null shows every location.
  String? _location;

  void _setDay(DateTime? day) {
    setState(() => _day = day);
    _loader.currentState?.reload();
  }

  Future<void> _chooseDay(DateTime shown) async {
    final picked = await showDatePicker(
      context: context,
      initialDate: shown,
      firstDate: DateTime(2024),
      lastDate: DateTime.now().add(const Duration(days: 1)),
    );
    if (picked != null) _setDay(picked);
  }

  Future<void> _upload() async {
    final saved = await Navigator.push<bool>(context, MaterialPageRoute(builder: (_) => const UploadScreen()));
    if (saved == true) _loader.currentState?.reload();
  }

  @override
  Widget build(BuildContext context) {
    final api = SessionScope.apiOf(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Sales'),
        actions: [
          IconButton(
            tooltip: 'Past uploads',
            icon: const Icon(Icons.history),
            onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const UploadHistoryScreen())),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _upload,
        icon: const Icon(Icons.upload_file),
        label: const Text('Upload stock sheet'),
      ),
      body: Loader<SalesReport>(
        key: _loader,
        load: () => api.sales(date: _day == null ? null : _isoDate(_day!)),
        builder: (context, report, _) {
          final shown = DateTime.parse(report.date);
          final byLocation = <String, int>{};
          for (final s in report.items) {
            byLocation[s.locationName] = (byLocation[s.locationName] ?? 0) + s.quantity;
          }
          final location = byLocation.containsKey(_location) ? _location : null;
          final lines = report.items.where((s) => location == null || s.locationName == location).toList();
          final total = location == null ? report.total : byLocation[location]!;
          return ListView(
            padding: const EdgeInsets.only(bottom: 96),
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  IconButton(
                    tooltip: 'Day before',
                    icon: const Icon(Icons.chevron_left),
                    onPressed: () => _setDay(shown.subtract(const Duration(days: 1))),
                  ),
                  TextButton.icon(
                    onPressed: () => _chooseDay(shown),
                    icon: const Icon(Icons.calendar_today_outlined, size: 18),
                    label: Text(report.date),
                  ),
                  IconButton(
                    tooltip: 'Day after',
                    icon: const Icon(Icons.chevron_right),
                    onPressed: () => _setDay(shown.add(const Duration(days: 1))),
                  ),
                ],
              ),
              if (byLocation.length > 1)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Wrap(
                    spacing: 8,
                    children: [
                      ChoiceChip(
                        label: Text('All (${report.total})'),
                        selected: location == null,
                        onSelected: (_) => setState(() => _location = null),
                      ),
                      for (final e in byLocation.entries)
                        ChoiceChip(
                          label: Text('${e.key} (${e.value})'),
                          selected: location == e.key,
                          onSelected: (_) => setState(() => _location = e.key),
                        ),
                    ],
                  ),
                ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Text(
                  '${total == 1 ? '1 item sold' : '$total items sold'}${location == null ? '' : ' at $location'}',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ),
              if (report.items.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(32),
                  child: Text(
                    'No sales recorded for this day. Upload the end-of-day stock sheet to record them.',
                    textAlign: TextAlign.center,
                  ),
                ),
              for (final s in lines)
                ListTile(
                  title: Text(s.itemName),
                  subtitle: Text(s.locationName),
                  trailing: Text('${s.quantity} ${s.unit}', style: const TextStyle(fontWeight: FontWeight.w600)),
                  onTap: () =>
                      Navigator.push(context, MaterialPageRoute(builder: (_) => ItemDetailScreen(itemId: s.itemId))),
                ),
            ],
          );
        },
      ),
    );
  }
}

class UploadHistoryScreen extends StatelessWidget {
  const UploadHistoryScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final api = SessionScope.apiOf(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Past uploads')),
      body: Loader<List<UploadResult>>(
        load: () => api.uploads(limit: 100),
        builder: (context, uploads, _) {
          if (uploads.isEmpty) {
            return ListView(
              padding: const EdgeInsets.all(32),
              children: const [Text('No stock sheets uploaded yet.', textAlign: TextAlign.center)],
            );
          }
          return ListView.separated(
            itemCount: uploads.length,
            separatorBuilder: (_, _) => const Divider(height: 1),
            itemBuilder: (context, i) {
              final u = uploads[i];
              final s = u.summary;
              return ListTile(
                title: Text(u.filename),
                subtitle: Text(
                  '${formatDate(u.createdAt)} · ${s.newItems} new, ${s.sold} sold, ${s.received} received',
                ),
              );
            },
          );
        },
      ),
    );
  }
}
