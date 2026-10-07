import 'package:flutter/material.dart';

import '../models.dart';
import '../session.dart';
import '../widgets.dart';
import 'item_detail_screen.dart';
import 'paste_screen.dart';
import 'sales_pdf_sheet.dart';
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

  /// Paste a list (purchases, transfer, sales) or upload a stock sheet.
  Future<void> _addList() async {
    final screen = await showModalBottomSheet<Widget>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.point_of_sale),
              title: const Text('End of day sales'),
              subtitle: const Text('A branch\'s sold items from WhatsApp, with the day\'s total and a PDF'),
              onTap: () => Navigator.pop(context, const PasteScreen(endOfDay: true)),
            ),
            ListTile(
              leading: const Icon(Icons.content_paste),
              title: const Text('Paste list'),
              subtitle: const Text('Purchases, transfers or sales copied from Excel or WhatsApp'),
              onTap: () => Navigator.pop(context, const PasteScreen()),
            ),
            ListTile(
              leading: const Icon(Icons.upload_file),
              title: const Text('Upload stock sheet'),
              subtitle: const Text('An Excel or CSV stock count'),
              onTap: () => Navigator.pop(context, const UploadScreen()),
            ),
          ],
        ),
      ),
    );
    if (screen == null || !mounted) return;
    final saved = await Navigator.push<bool>(context, MaterialPageRoute(builder: (_) => screen));
    if (saved == true) _loader.currentState?.reload();
  }

  /// The last report shown, so the PDF button knows the day and place.
  SalesReport? _shown;

  void _pdf() {
    final report = _shown;
    final location = report?.items.where((s) => s.locationName == _location).firstOrNull?.locationId;
    showSalesPdfSheet(context, date: report?.date ?? (_day == null ? null : _isoDate(_day!)), locationId: location);
  }

  @override
  Widget build(BuildContext context) {
    final api = SessionScope.apiOf(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Sales'),
        actions: [
          IconButton(tooltip: 'PDF report', icon: const Icon(Icons.picture_as_pdf_outlined), onPressed: _pdf),
          IconButton(
            tooltip: 'Past uploads',
            icon: const Icon(Icons.history),
            onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const UploadHistoryScreen())),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _addList,
        icon: const Icon(Icons.playlist_add),
        label: const Text('Add list'),
      ),
      body: Loader<SalesReport>(
        key: _loader,
        load: () => api.sales(date: _day == null ? null : _isoDate(_day!)),
        builder: (context, report, _) {
          _shown = report;
          final shown = DateTime.parse(report.date);
          final byLocation = <String, int>{};
          for (final s in report.items) {
            byLocation[s.locationName] = (byLocation[s.locationName] ?? 0) + s.quantity;
          }
          final location = byLocation.containsKey(_location) ? _location : null;
          final lines = report.items.where((s) => location == null || s.locationName == location).toList();
          final total = location == null ? report.total : byLocation[location]!;
          final amount = lines.fold<double>(0, (t, s) => t + (s.amount ?? 0));
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
              if (amount > 0)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Text('LKR ${formatMoney(amount)}', style: Theme.of(context).textTheme.titleMedium),
                ),
              if (report.items.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(32),
                  child: Text(
                    'No sales recorded for this day. Paste the sales list or upload the end-of-day stock sheet to record them.',
                    textAlign: TextAlign.center,
                  ),
                ),
              for (final s in lines)
                ListTile(
                  title: Text(s.itemName),
                  subtitle: Text(s.locationName),
                  trailing: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text('${s.quantity} ${s.unit}', style: const TextStyle(fontWeight: FontWeight.w600)),
                      if (s.amount != null)
                        Text('LKR ${formatMoney(s.amount!)}', style: Theme.of(context).textTheme.bodySmall),
                    ],
                  ),
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
              children: const [Text('No stock sheets or pasted lists yet.', textAlign: TextAlign.center)],
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
                  [
                    formatDate(u.createdAt),
                    if (s.newItems > 0) '${s.newItems} new',
                    if (s.sold > 0) '${s.sold} sold',
                    if (s.received > 0) '${s.received} received',
                    if (s.transferred > 0) '${s.transferred} moved',
                  ].join(' · '),
                ),
              );
            },
          );
        },
      ),
    );
  }
}
