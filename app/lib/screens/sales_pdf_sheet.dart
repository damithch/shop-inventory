import 'package:flutter/material.dart';

import '../models.dart';
import '../session.dart';
import '../widgets.dart';
import 'export_screen.dart' show saveExport, shareExport;

/// Opens a sheet to share or save one day's sales report as a PDF, for one
/// place or all of them. [date] is YYYY-MM-DD; null means today.
Future<void> showSalesPdfSheet(BuildContext context, {String? date, int? locationId, String? title}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (_) => SalesPdfSheet(date: date, locationId: locationId, title: title),
  );
}

class SalesPdfSheet extends StatefulWidget {
  const SalesPdfSheet({super.key, this.date, this.locationId, this.title});

  final String? date;
  final int? locationId;

  /// Shown at the top, e.g. "Saved: 6 sold".
  final String? title;

  @override
  State<SalesPdfSheet> createState() => _SalesPdfSheetState();
}

class _SalesPdfSheetState extends State<SalesPdfSheet> {
  late int? _location = widget.locationId;
  bool _busy = false;

  Future<void> _go({required bool share}) async {
    final api = SessionScope.apiOf(context);
    setState(() => _busy = true);
    try {
      final file = await api.salesPdf(date: widget.date, locationId: _location);
      if (share) {
        await shareExport(file);
      } else if (await saveExport(file)) {
        if (mounted) showMessage(context, 'Saved ${file.name}');
      }
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final api = SessionScope.apiOf(context);
    final theme = Theme.of(context);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
        child: Loader<List<Location>>(
          pullToRefresh: false,
          load: api.locations,
          builder: (context, locations, _) => Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (widget.title != null) ...[
                Text(widget.title!, style: theme.textTheme.titleMedium),
                const SizedBox(height: 12),
              ],
              Text('Sales report PDF', style: theme.textTheme.titleLarge),
              Text(widget.date ?? 'Today', style: theme.textTheme.bodyMedium),
              const SizedBox(height: 16),
              DropdownButtonFormField<int?>(
                initialValue: locations.any((l) => l.id == _location) ? _location : null,
                decoration: const InputDecoration(labelText: 'Place', border: OutlineInputBorder()),
                items: [
                  const DropdownMenuItem<int?>(value: null, child: Text('All places')),
                  for (final l in locations.where((l) => !l.archived))
                    DropdownMenuItem<int?>(value: l.id, child: Text(l.name)),
                ],
                onChanged: _busy ? null : (id) => setState(() => _location = id),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _busy ? null : () => _go(share: false),
                      icon: const Icon(Icons.download_outlined),
                      label: const Text('Save PDF'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: _busy ? null : () => _go(share: true),
                      icon: const Icon(Icons.share_outlined),
                      label: const Text('Share PDF'),
                    ),
                  ),
                ],
              ),
              if (_busy)
                const Padding(
                  padding: EdgeInsets.only(top: 16),
                  child: Center(child: CircularProgressIndicator()),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
