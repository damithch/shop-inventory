import 'package:flutter/material.dart';

import 'models.dart';

/// Loads data with [load] and shows a spinner, an error with a retry button,
/// or [builder]'s result. Pull down to reload.
class Loader<T> extends StatefulWidget {
  const Loader({super.key, required this.load, required this.builder, this.pullToRefresh = true});

  final Future<T> Function() load;
  final bool pullToRefresh;
  final Widget Function(BuildContext context, T data, Future<void> Function() reload) builder;

  @override
  State<Loader<T>> createState() => LoaderState<T>();
}

class LoaderState<T> extends State<Loader<T>> {
  T? _data;
  Object? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    reload();
  }

  Future<void> reload() async {
    setState(() {
      _loading = _data == null;
      _error = null;
    });
    try {
      final data = await widget.load();
      if (!mounted) return;
      setState(() {
        _data = data;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e;
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null && _data == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('$_error', textAlign: TextAlign.center),
              const SizedBox(height: 12),
              FilledButton.tonal(onPressed: reload, child: const Text('Try again')),
            ],
          ),
        ),
      );
    }
    final child = widget.builder(context, _data as T, reload);
    return widget.pullToRefresh ? RefreshIndicator(onRefresh: reload, child: child) : child;
  }
}

void showError(BuildContext context, Object error) {
  final scheme = Theme.of(context).colorScheme;
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        behavior: SnackBarBehavior.floating,
        backgroundColor: scheme.error,
        content: Row(
          children: [
            Icon(Icons.error_outline, color: scheme.onError),
            const SizedBox(width: 12),
            Expanded(
              child: Text('$error', style: TextStyle(color: scheme.onError)),
            ),
          ],
        ),
      ),
    );
}

/// A short confirmation at the bottom of the screen that something worked.
void showMessage(BuildContext context, String message) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 3),
        content: Row(
          children: [
            const Icon(Icons.check_circle_outline, color: Colors.lightGreenAccent),
            const SizedBox(width: 12),
            Expanded(child: Text(message)),
          ],
        ),
      ),
    );
}

/// Shows the low-stock alerts a stock change just raised, if any.
Future<void> showStockAlerts(BuildContext context, List<StockAlert> alerts) async {
  if (alerts.isEmpty) return;
  await showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      icon: const Icon(Icons.warning_amber_rounded),
      title: const Text('Low stock'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [for (final a in alerts) Padding(padding: const EdgeInsets.only(bottom: 8), child: Text(a.message))],
      ),
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('OK'))],
    ),
  );
}

/// The quantity on the right of a stock row, red when at or below the alert level.
class QuantityBadge extends StatelessWidget {
  const QuantityBadge({super.key, required this.quantity, required this.low, this.unit});

  final int quantity;
  final bool low;
  final String? unit;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: low ? scheme.errorContainer : scheme.secondaryContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        unit == null ? '$quantity' : '$quantity $unit',
        style: TextStyle(
          fontWeight: FontWeight.w600,
          color: low ? scheme.onErrorContainer : scheme.onSecondaryContainer,
        ),
      ),
    );
  }
}

/// Asks for a whole number. Returns null if cancelled.
Future<int?> askNumber(
  BuildContext context, {
  required String title,
  String? message,
  int? initial,
  int min = 0,
  String? resetLabel,
  VoidCallback? onReset,
}) {
  final controller = TextEditingController(text: initial?.toString() ?? '');
  final formKey = GlobalKey<FormState>();
  return showDialog<int>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: Form(
        key: formKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (message != null) Padding(padding: const EdgeInsets.only(bottom: 12), child: Text(message)),
            TextFormField(
              controller: controller,
              autofocus: true,
              keyboardType: TextInputType.number,
              validator: (v) => validateWholeNumber(v, min: min),
            ),
          ],
        ),
      ),
      actions: [
        if (resetLabel != null)
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              onReset?.call();
            },
            child: Text(resetLabel),
          ),
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          onPressed: () {
            if (formKey.currentState!.validate()) Navigator.pop(context, int.parse(controller.text.trim()));
          },
          child: const Text('Save'),
        ),
      ],
    ),
  );
}

String? validateWholeNumber(String? value, {int min = 1}) {
  final n = int.tryParse(value?.trim() ?? '');
  if (n == null) return 'Enter a whole number';
  if (n < min) return min == 1 ? 'Must be at least 1' : 'Must be $min or more';
  return null;
}

String formatDate(DateTime? d) {
  if (d == null) return '';
  String two(int n) => n.toString().padLeft(2, '0');
  return '${d.year}-${two(d.month)}-${two(d.day)} ${two(d.hour)}:${two(d.minute)}';
}
