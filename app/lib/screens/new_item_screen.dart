import 'package:flutter/material.dart';

import '../session.dart';
import '../widgets.dart';

/// Adds a new item, optionally with its first stock in the main shop.
class NewItemScreen extends StatefulWidget {
  const NewItemScreen({super.key});

  @override
  State<NewItemScreen> createState() => _NewItemScreenState();
}

class _NewItemScreenState extends State<NewItemScreen> {
  final _formKey = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _sku = TextEditingController();
  final _unit = TextEditingController(text: 'pcs');
  final _quantity = TextEditingController();
  bool _busy = false;

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    final api = SessionScope.apiOf(context);
    setState(() => _busy = true);
    try {
      final item = await api.addItem(name: _name.text.trim(), sku: _sku.text.trim(), unit: _unit.text.trim());
      final qty = int.tryParse(_quantity.text.trim()) ?? 0;
      if (qty > 0) await api.receive(itemId: item.id, quantity: qty, note: 'Opening stock');
      if (!mounted) return;
      showMessage(context, '${item.name} added');
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
      appBar: AppBar(title: const Text('New item')),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            TextFormField(
              controller: _name,
              autofocus: true,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(labelText: 'Name', border: OutlineInputBorder()),
              validator: (v) => (v == null || v.trim().isEmpty) ? 'Enter a name' : null,
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _sku,
              decoration: const InputDecoration(labelText: 'Code / SKU (optional)', border: OutlineInputBorder()),
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _unit,
              decoration: const InputDecoration(labelText: 'Unit, e.g. pcs, kg, box', border: OutlineInputBorder()),
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _quantity,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: 'Quantity in the main shop now (optional)',
                border: OutlineInputBorder(),
              ),
              validator: (v) => (v == null || v.trim().isEmpty) ? null : validateWholeNumber(v, min: 0),
            ),
            const SizedBox(height: 24),
            FilledButton(
              onPressed: _busy ? null : _submit,
              child: _busy
                  ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Text('Add item'),
            ),
          ],
        ),
      ),
    );
  }
}
