import 'package:flutter/material.dart';

import '../session.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _password = TextEditingController();
  late final TextEditingController _server;
  bool _busy = false;
  bool _showServer = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final session = SessionScope.read(context);
    _server = TextEditingController(text: session.baseUrl);
  }

  Future<void> _submit() async {
    if (_password.text.isEmpty) {
      setState(() => _error = 'Enter the password');
      return;
    }
    final session = SessionScope.read(context);
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await session.setBaseUrl(_server.text);
      await session.signIn(_password.text);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Icon(Icons.inventory_2_outlined, size: 64, color: theme.colorScheme.primary),
                  const SizedBox(height: 12),
                  Text('Shop Inventory', textAlign: TextAlign.center, style: theme.textTheme.headlineSmall),
                  const SizedBox(height: 32),
                  TextField(
                    controller: _password,
                    obscureText: true,
                    enabled: !_busy,
                    decoration: const InputDecoration(labelText: 'Password', border: OutlineInputBorder()),
                    onSubmitted: (_) => _submit(),
                  ),
                  if (_showServer) ...[
                    const SizedBox(height: 16),
                    TextField(
                      controller: _server,
                      enabled: !_busy,
                      keyboardType: TextInputType.url,
                      decoration: const InputDecoration(
                        labelText: 'Server address',
                        hintText: 'https://your-api.vercel.app',
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ],
                  if (_error != null) ...[
                    const SizedBox(height: 12),
                    Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
                  ],
                  const SizedBox(height: 24),
                  FilledButton(
                    onPressed: _busy ? null : _submit,
                    child: _busy
                        ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Text('Sign in'),
                  ),
                  if (_busy) ...[
                    const SizedBox(height: 12),
                    Text(
                      'The server may take up to a minute to wake up the first time.',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodySmall,
                    ),
                  ],
                  const SizedBox(height: 8),
                  TextButton(
                    onPressed: () => setState(() => _showServer = !_showServer),
                    child: Text(_showServer ? 'Hide server address' : 'Server address'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
