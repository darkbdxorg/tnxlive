import 'package:flutter_test/flutter_test.dart';
import 'package:tnxlive_app/main.dart';

void main() {
  testWidgets('App renders title', (tester) async {
    await tester.pumpWidget(const TNxLiveApp());
    expect(find.text('TNxLive'), findsOneWidget);
  });
}
