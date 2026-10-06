import 'package:flutter/material.dart';

import '../models.dart';
import '../session.dart';
import '../widgets.dart';
import 'branches_screen.dart';
import 'location_stock_screen.dart';
import 'low_stock_screen.dart';
import 'settings_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _tab = 0;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // Each tab is rebuilt when opened so it always shows fresh counts.
      body: KeyedSubtree(
        key: ValueKey(_tab),
        child: const [_MainShopTab(), BranchesScreen(), LowStockScreen(), SettingsScreen()][_tab],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (i) => setState(() => _tab = i),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.storefront_outlined),
            selectedIcon: Icon(Icons.storefront),
            label: 'Main shop',
          ),
          NavigationDestination(
            icon: Icon(Icons.store_mall_directory_outlined),
            selectedIcon: Icon(Icons.store_mall_directory),
            label: 'Branches',
          ),
          NavigationDestination(
            icon: Icon(Icons.warning_amber_outlined),
            selectedIcon: Icon(Icons.warning_amber),
            label: 'Low stock',
          ),
          NavigationDestination(
            icon: Icon(Icons.settings_outlined),
            selectedIcon: Icon(Icons.settings),
            label: 'Settings',
          ),
        ],
      ),
    );
  }
}

/// Finds the main shop, then shows its stock.
class _MainShopTab extends StatelessWidget {
  const _MainShopTab();

  @override
  Widget build(BuildContext context) {
    final api = SessionScope.apiOf(context);
    return Loader<Location>(
      pullToRefresh: false,
      load: () async => (await api.locations()).firstWhere((l) => l.isMain),
      builder: (context, main, _) => LocationStockScreen(location: main),
    );
  }
}
