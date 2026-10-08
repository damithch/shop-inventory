import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shop_inventory/api/api_client.dart';
import 'package:shop_inventory/main.dart';
import 'package:shop_inventory/models.dart';
import 'package:shop_inventory/push.dart';
import 'package:shop_inventory/screens/export_screen.dart';
import 'package:shop_inventory/screens/upload_screen.dart';
import 'package:shop_inventory/session.dart';

import 'fake_backend.dart';

void main() {
  late FakeBackend backend;

  setUp(() {
    backend = FakeBackend();
    SharedPreferences.setMockInitialValues({});
  });

  Future<Session> pumpApp(WidgetTester tester) async {
    final session = Session(await SharedPreferences.getInstance(), httpClient: backend.client);
    await tester.binding.setSurfaceSize(const Size(420, 900));
    await tester.pumpWidget(ShopInventoryApp(session: session));
    await tester.pumpAndSettle();
    return session;
  }

  Future<void> signIn(WidgetTester tester, String password) async {
    await tester.enterText(find.widgetWithText(TextField, 'Password'), password);
    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();
  }

  group('ApiClient', () {
    test('shows the API error message and signs out on 401', () async {
      var signedOut = false;
      final api = ApiClient(
        baseUrl: 'http://x/',
        token: 'expired',
        httpClient: backend.client,
        onUnauthorized: () => signedOut = true,
      );
      await expectLater(
        api.locations(),
        throwsA(isA<ApiException>().having((e) => e.message, 'message', 'Sign in required')),
      );
      expect(signedOut, isTrue);
    });

    test('parses stock and a transfer that raises an alert', () async {
      final api = ApiClient(baseUrl: 'http://x', token: 'tok', httpClient: backend.client);
      final main = await api.locationStock(1);
      expect(main.location.isMain, isTrue);
      expect(main.items.single.quantity, 8);

      final result = await api.transfer(itemId: 10, toLocationId: 2, quantity: 6);
      expect(result.alerts.single.message, 'Rice 5kg is low at Main Shop: 2 left (alert level 3)');
      expect(backend.stock['10:2'], 10);
    });
  });

  test('registers the phone for push alerts while signed in', () async {
    final push = FakePush('phone-1');
    final session = Session(await SharedPreferences.getInstance(), httpClient: backend.client, push: push);
    await session.signIn('secret');
    await pumpEventQueue();
    expect(backend.devices, {'phone-1'});

    // Firebase hands out a new token.
    push.refresh.add('phone-2');
    await pumpEventQueue();
    expect(backend.devices, containsAll(['phone-2']));

    await session.signOut();
    await pumpEventQueue();
    expect(backend.devices, isNot(contains('phone-2')));

    // Starting the app signed in registers again.
    await session.signIn('secret');
    await pumpEventQueue();
    backend.devices.clear();
    Session(await SharedPreferences.getInstance(), httpClient: backend.client, push: FakePush('phone-2'));
    await pumpEventQueue();
    expect(backend.devices, {'phone-2'});
  });

  testWidgets('wrong password shows the error and stays on sign in', (tester) async {
    await pumpApp(tester);
    await signIn(tester, 'nope');
    expect(find.text('Wrong password'), findsOneWidget);
    expect(find.text('Sign in'), findsOneWidget);
  });

  testWidgets('signs in and shows main shop stock', (tester) async {
    final session = await pumpApp(tester);
    await signIn(tester, 'secret');
    expect(session.signedIn, isTrue);
    expect(find.text('Main Shop'), findsWidgets);
    expect(find.text('Rice 5kg'), findsOneWidget);
    expect(find.text('8 bag'), findsOneWidget);
  });

  testWidgets('moves stock to a branch and shows the low-stock alert', (tester) async {
    await pumpApp(tester);
    await signIn(tester, 'secret');

    await tester.tap(find.text('Rice 5kg'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Move'));
    await tester.pumpAndSettle();

    expect(find.text('In stock there now: 8'), findsOneWidget);
    await tester.enterText(find.widgetWithText(TextFormField, 'Quantity'), '9');
    await tester.tap(find.widgetWithText(FilledButton, 'Move'));
    await tester.pumpAndSettle();
    expect(find.text('Only 8 in stock there'), findsOneWidget);

    await tester.enterText(find.widgetWithText(TextFormField, 'Quantity'), '6');
    await tester.tap(find.widgetWithText(FilledButton, 'Move'));
    await tester.pumpAndSettle();

    expect(find.text('Low stock'), findsWidgets);
    expect(find.text('Rice 5kg is low at Main Shop: 2 left (alert level 3)'), findsOneWidget);
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();

    expect(backend.stock['10:1'], 2);
    expect(backend.stock['10:2'], 10);
    // Back on the item page, which reloaded with the new counts.
    expect(find.text('Kandy'), findsOneWidget);
    expect(find.text('10'), findsOneWidget);
  });

  testWidgets('records a sale at a branch and lists it under low stock', (tester) async {
    await pumpApp(tester);
    await signIn(tester, 'secret');

    await tester.tap(find.text('Branches'));
    await tester.pumpAndSettle();
    expect(find.text('1 items · 4 units'), findsOneWidget);
    await tester.tap(find.text('Kandy'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Stock'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Record sale'));
    await tester.pumpAndSettle();

    // Pick the item from the searchable list.
    await tester.tap(find.widgetWithText(TextField, 'Item'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Rice 5kg (R5)').last);
    await tester.pumpAndSettle();

    await tester.enterText(find.widgetWithText(TextFormField, 'Quantity'), '2');
    await tester.tap(find.widgetWithText(FilledButton, 'Record sale'));
    await tester.pumpAndSettle();

    expect(find.text('Rice 5kg is low at Kandy: 2 left (alert level 3)'), findsOneWidget);
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    expect(find.text('2 bag'), findsOneWidget);

    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.tap(find.text('Low stock').last);
    await tester.pumpAndSettle();
    expect(find.text('Kandy · alert at 3'), findsOneWidget);
  });

  testWidgets('uploads an end-of-day sheet and shows what sold', (tester) async {
    pickSheet = () async => PickedSheet('evening.csv', utf8.encode('Item,Qty\nRice 5kg,5\nRice,7\n'));
    await pumpApp(tester);
    await signIn(tester, 'secret');
    await tester.tap(find.text('Sales'));
    await tester.pumpAndSettle();
    expect(find.text('0 items sold'), findsOneWidget);

    await tester.tap(find.text('Add list'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Upload stock sheet'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Choose file'));
    await tester.pumpAndSettle();

    // Preview: Rice 5kg went from 8 to 5, and "Rice" is new but looks like Rice 5kg.
    expect(find.text('3 sold'), findsOneWidget);
    expect(find.text('1 new items (7 in stock)'), findsOneWidget);
    expect(find.textContaining('1 new items look like items already in the app'), findsOneWidget);
    expect(backend.stock['10:1'], 8);

    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(backend.stock['10:1'], 5);
    expect(backend.uploads.single['filename'], 'evening.csv');

    // Back on the sales screen, reloaded.
    expect(find.text('3 items sold'), findsOneWidget);
    expect(find.text('3 bag'), findsOneWidget);

    // A sale at the Kandy branch: the day shows each place's sales separately.
    backend.sales.add((item: 10, loc: 2, qty: 1, price: null));
    await tester.tap(find.text('Low stock').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Sales'));
    await tester.pumpAndSettle();
    expect(find.text('4 items sold'), findsOneWidget);
    await tester.tap(find.text('Kandy (1)'));
    await tester.pumpAndSettle();
    expect(find.text('1 item sold at Kandy'), findsOneWidget);
    expect(find.text('Main Shop'), findsNothing);
  });

  testWidgets('a new name on a sheet can be matched to an existing item', (tester) async {
    pickSheet = () async => PickedSheet('home.csv', utf8.encode('Item,Qty\nRice,6\n'));
    await pumpApp(tester);
    await signIn(tester, 'secret');
    await tester.tap(find.text('Sales'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add list'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Upload stock sheet'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Choose file'));
    await tester.pumpAndSettle();
    expect(find.text('1 new items (6 in stock)'), findsOneWidget);

    // "Rice" on the sheet is Rice 5kg: then it's 2 sold, not a new item.
    await tester.ensureVisible(find.text('Rice'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Rice'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Rice 5kg').last);
    await tester.pumpAndSettle();
    expect(find.text('0 new items (0 in stock)'), findsOneWidget);
    expect(find.text('2 sold'), findsOneWidget);
    expect(find.text('is Rice 5kg'), findsOneWidget);
    expect(backend.requests.last, 'POST /uploads/preview');

    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(backend.stock['10:1'], 6);
    expect(backend.items.length, 1);
    expect(backend.aliases, {'Rice': 10});
  });

  testWidgets('pastes a transfer to a branch and then a sale there', (tester) async {
    await pumpApp(tester);
    await signIn(tester, 'secret');
    await tester.tap(find.text('Sales'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Add list'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Paste list'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Transfer'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Rice 5kg 4\nSugar 2');
    await tester.pump();
    await tester.tap(find.text('Check list'));
    await tester.pumpAndSettle();

    expect(find.text('4 moved from Main Shop to Kandy'), findsOneWidget);
    expect(find.text('Line 2: Sugar 2'), findsOneWidget);
    expect(find.text('not in the app'), findsOneWidget);
    expect(backend.stock['10:1'], 8);

    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(backend.stock['10:1'], 4);
    expect(backend.stock['10:2'], 8);

    // Let the "Saved" message go so it doesn't cover the button.
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add list'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Paste list'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Sale'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Rice 5kg 2');
    await tester.pump();
    await tester.tap(find.text('Check list'));
    await tester.pumpAndSettle();
    expect(find.text('2 sold at Kandy'), findsOneWidget);
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(backend.stock['10:2'], 6);
    expect(find.text('2 items sold'), findsOneWidget);
  });

  testWidgets('enters a branch\'s end-of-day sales with prices and shares the PDF', (tester) async {
    final shared = <ExportFile>[];
    shareExport = (file) async => shared.add(file);
    addTearDown(() => shareExport = shareFileFromPhone);
    backend.items.add({'id': 11, 'name': 'Sugar 1kg', 'sku': null, 'unit': 'pcs', 'archived': false, 'price': 350});
    backend.stock['11:2'] = 10;

    await pumpApp(tester);
    await signIn(tester, 'secret');
    await tester.tap(find.text('Sales'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add list'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('End of day sales'));
    await tester.pumpAndSettle();

    expect(find.text('Branch'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'Rice 5kg 2\nSugar 1kg 3');
    await tester.pump();
    await tester.tap(find.text('Check list'));
    await tester.pumpAndSettle();
    expect(find.text('5 sold at Kandy'), findsOneWidget);
    // Sugar has a saved price; rice doesn't yet.
    expect(find.text('Total LKR 1,050.00'), findsOneWidget);
    expect(find.text('2 units have no price and are not in the total'), findsOneWidget);

    await tester.tap(find.text('−2 · Add price'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextFormField, 'Price for one (LKR)'), '2,450');
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    expect(find.text('−2 × 2,450.00'), findsOneWidget);
    expect(find.text('Total LKR 5,950.00'), findsOneWidget);

    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(backend.stock['10:2'], 2);
    expect(backend.items.first['price'], 2450);
    // Rice is now low at Kandy.
    expect(find.text('Low stock'), findsOneWidget);
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    expect(find.text('Saved: 5 sold'), findsOneWidget);

    await tester.tap(find.text('Share PDF'));
    await tester.pumpAndSettle();
    expect(shared.single.name, 'sales-2-2026-10-06.pdf');
    expect(shared.single.mimeType, 'application/pdf');
    expect(backend.pdfs.single['location_id'], '2');

    // Back on the sales screen, the day shows in rupees, and a past day's PDF
    // can be made for any place.
    Navigator.of(tester.element(find.text('Share PDF'))).pop();
    await tester.pumpAndSettle();
    expect(find.text('5 items sold'), findsOneWidget);
    expect(find.text('LKR 5,950.00'), findsOneWidget);
    await tester.tap(find.byTooltip('Day before'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('PDF report'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Share PDF'));
    await tester.pumpAndSettle();
    expect(backend.pdfs.last['date'], '2026-10-05');
    expect(backend.pdfs.last['location_id'], isNull);
  });

  testWidgets('keeping a look-alike as a new item clears its warning', (tester) async {
    pickSheet = () async => PickedSheet('home.csv', utf8.encode('Item,Qty\nRice,6\n'));
    await pumpApp(tester);
    await signIn(tester, 'secret');
    await tester.tap(find.text('Sales'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add list'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Upload stock sheet'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Choose file'));
    await tester.pumpAndSettle();
    expect(find.textContaining('1 new items look like'), findsOneWidget);

    await tester.ensureVisible(find.text('Rice'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Rice'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Keep as a new item'));
    await tester.pump();
    expect(find.text('"Rice" will be added as a new item'), findsOneWidget);
    expect(find.text('New item: your choice'), findsOneWidget);
    expect(find.textContaining('1 new items look like'), findsNothing);
    expect(find.textContaining('Looks like:'), findsNothing);
  });

  testWidgets('moves a list of items from the main shop to the branch it names', (tester) async {
    backend.locations.add({'id': 3, 'name': 'Galle', 'type': 'branch', 'archived': false});
    await pumpApp(tester);
    await signIn(tester, 'secret');
    await tester.tap(find.text('Stock'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Move a list of items'));
    await tester.pumpAndSettle();

    // The first line names the branch; "Rice" is part of only Rice 5kg's name.
    await tester.enterText(find.byType(TextField), 'Kandy\nRice 3');
    await tester.pump();
    await tester.tap(find.text('Check list'));
    await tester.pumpAndSettle();
    expect(find.text('3 moved from Main Shop to Kandy'), findsOneWidget);
    expect(find.textContaining('1 short names were matched'), findsOneWidget);
    expect(find.text('Matched from "Rice". Tap to change'), findsOneWidget);

    // Saying it isn't that item leaves the line out.
    await tester.ensureVisible(find.text('Rice 5kg'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Rice 5kg'));
    await tester.pumpAndSettle();
    expect(find.text('Which item is "Rice" in the list?'), findsOneWidget);
    await tester.tap(find.text('Leave it out'));
    await tester.pumpAndSettle();
    expect(find.text('0 moved from Main Shop to Kandy'), findsOneWidget);
    expect(find.text('Left out: your choice'), findsOneWidget);

    // Picking it again makes it the user's own match, remembered on save.
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Line 2: Rice 3'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Line 2: Rice 3'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Rice 5kg'));
    await tester.pumpAndSettle();
    expect(find.text('3 moved from Main Shop to Kandy'), findsOneWidget);
    expect(find.text('Matched by you (1)'), findsOneWidget);

    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(backend.stock['10:1'], 5);
    expect(backend.stock['10:2'], 7);
    expect(backend.aliases, {'Rice': 10});
  });

  testWidgets('changes the default alert level', (tester) async {
    await pumpApp(tester);
    await signIn(tester, 'secret');
    await tester.tap(find.text('Settings'));
    await tester.pumpAndSettle();
    expect(find.text('Warn when 3 or fewer are left'), findsOneWidget);

    await tester.tap(find.text('Default alert level'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField), '5');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(backend.defaultThreshold, 5);
    expect(find.text('Warn when 5 or fewer are left'), findsOneWidget);
  });

  testWidgets('exports a branch as CSV and shares it, then saves the item list', (tester) async {
    final shared = <ExportFile>[];
    final saved = <ExportFile>[];
    shareExport = (file) async => shared.add(file);
    saveExport = (file) async {
      saved.add(file);
      return true;
    };
    addTearDown(() {
      shareExport = shareFileFromPhone;
      saveExport = saveFileToPhone;
    });

    await pumpApp(tester);
    await signIn(tester, 'secret');
    await tester.tap(find.text('Settings'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Export to Excel or CSV'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Stock at all places'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Stock at Kandy').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('CSV'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Share'));
    await tester.pumpAndSettle();
    expect(shared.single.name, 'stock-2.csv');
    expect(utf8.decode(shared.single.bytes), startsWith('Item name,Qty'));

    await tester.tap(find.text('Stock at Kandy'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Item list').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Excel'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save to phone'));
    await tester.pumpAndSettle();
    expect(saved.single.name, 'items.xlsx');
    expect(find.text('Saved items.xlsx'), findsOneWidget);
  });

  testWidgets('hides Export when it is turned off at the server', (tester) async {
    backend.exportsEnabled = false;
    await pumpApp(tester);
    await signIn(tester, 'secret');
    await tester.tap(find.text('Settings'));
    await tester.pumpAndSettle();
    expect(find.text('Export to Excel or CSV'), findsNothing);
    expect(find.text('Reset and delete'), findsOneWidget);
  });

  group('Reset and delete', () {
    late List<ExportFile> saved;
    late bool saveBackup;

    setUp(() {
      // The backup before a reset works even with Export turned off.
      backend.exportsEnabled = false;
      saved = [];
      saveBackup = true;
      saveExport = (file) async {
        if (saveBackup) saved.add(file);
        return saveBackup;
      };
      addTearDown(() => saveExport = saveFileToPhone);
    });

    Future<void> openReset(WidgetTester tester) async {
      await pumpApp(tester);
      await signIn(tester, 'secret');
      await tester.tap(find.text('Settings'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Reset and delete'));
      await tester.pumpAndSettle();
    }

    Finder field(String label) => find.widgetWithText(TextField, label);
    Finder go() => find.widgetWithText(FilledButton, 'Back up and continue');

    testWidgets('resets a branch only after the name, the password and a backup', (tester) async {
      await openReset(tester);
      await tester.tap(find.text('Reset Kandy'));
      await tester.pumpAndSettle();
      expect(find.text('Reset Kandy to zero?'), findsOneWidget);
      expect(find.textContaining('1 item (4 units) at Kandy go to 0'), findsOneWidget);

      // The button stays off until the name is typed and a password entered.
      await tester.enterText(field('Type Kandy to confirm'), 'Kand');
      await tester.enterText(field('Your password'), 'wrong');
      await tester.pump();
      expect(tester.widget<FilledButton>(go()).onPressed, isNull);

      await tester.enterText(field('Type Kandy to confirm'), 'kandy');
      await tester.pump();
      await tester.tap(go());
      await tester.pumpAndSettle();
      expect(find.text('The password is wrong'), findsOneWidget);
      expect(saved, isEmpty);
      expect(backend.stock['10:2'], 4);

      await tester.enterText(field('Your password'), 'secret');
      await tester.pump();
      await tester.tap(go());
      await tester.pumpAndSettle();
      expect(saved.single.name, 'stock-2.xlsx');
      expect(backend.resets, ['/reset/stock']);
      expect(backend.stock['10:2'], 0);
      expect(backend.stock['10:1'], 8);
      expect(find.text('Kandy reset: 4 units taken to zero. Backup saved as stock-2.xlsx.'), findsOneWidget);
      // Still signed in after the wrong password.
      expect(find.text('Reset and delete'), findsWidgets);
    });

    testWidgets('changes nothing when the backup is not saved', (tester) async {
      saveBackup = false;
      await openReset(tester);
      await tester.tap(find.text('Reset every place'));
      await tester.pumpAndSettle();
      await tester.enterText(field('Type RESET to confirm'), 'reset');
      await tester.enterText(field('Your password'), 'secret');
      await tester.pump();
      await tester.tap(go());
      await tester.pumpAndSettle();
      expect(find.text('No backup was saved, so nothing was changed.'), findsOneWidget);
      expect(backend.resets, isEmpty);
      expect(backend.stock['10:1'], 8);
    });

    testWidgets('deletes an item picked from the list', (tester) async {
      await openReset(tester);
      await tester.tap(find.text('Delete an item'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Rice 5kg'));
      await tester.pumpAndSettle();
      expect(find.text('Delete Rice 5kg?'), findsOneWidget);
      await tester.enterText(field('Type DELETE to confirm'), 'DELETE');
      await tester.enterText(field('Your password'), 'secret');
      await tester.pump();
      await tester.tap(go());
      await tester.pumpAndSettle();
      expect(saved.single.name, 'stock-all.xlsx');
      expect(backend.resets, ['/reset/delete-item']);
      expect(backend.items, isEmpty);
      expect(find.text('Rice 5kg deleted. Backup saved as stock-all.xlsx.'), findsOneWidget);
    });

    testWidgets('deletes a branch', (tester) async {
      await openReset(tester);
      await tester.tap(find.text('Delete Kandy'));
      await tester.pumpAndSettle();
      await tester.enterText(field('Type Kandy to confirm'), 'Kandy');
      await tester.enterText(field('Your password'), 'secret');
      await tester.pump();
      await tester.tap(go());
      await tester.pumpAndSettle();
      expect(backend.resets, ['/reset/delete-branch']);
      expect(backend.locations.map((l) => l['name']), ['Main Shop']);
      expect(find.text('Delete Kandy'), findsNothing);
    });
  });
}

class FakePush implements PushService {
  FakePush(this.token);

  final String token;
  final refresh = StreamController<String>.broadcast();

  @override
  Future<String?> getToken() async => token;

  @override
  Stream<String> get onTokenRefresh => refresh.stream;
}
