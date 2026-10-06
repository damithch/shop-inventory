import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shop_inventory/api/api_client.dart';
import 'package:shop_inventory/main.dart';
import 'package:shop_inventory/push.dart';
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
