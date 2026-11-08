import 'package:flutter_test/flutter_test.dart';
import 'package:rive_native/rive_native.dart' as rive;

import 'src/utils.dart';

/// A file decode with [rive.Factory.flutter] waits for the images that file
/// decodes, and only those. https://github.com/rive-app/rive-flutter/issues/658
void main() {
  final png = loadFile('assets/images/customimage-2823435.png');
  final riv = loadFile('assets/hit_test_pass_through.riv');

  // The two tests below run in order and share the factory's state.
  group('a standalone decodeImage', () {
    testWidgets('started in a fake-async zone that then ends',
        (tester) async {
      // Not awaited: it needs real time, which this zone never gives it.
      rive.Factory.flutter.decodeImage(png);
    });

    testWidgets('does not block a later, unrelated file decode',
        (tester) async {
      final file = await tester.runAsync(() => rive.File.decode(
            riv,
            riveFactory: rive.Factory.flutter,
          ).timeout(const Duration(seconds: 5)));
      expect(file, isNotNull);
      file!.dispose();
    });
  });

  test('a file decode waits for images decoded by its asset loader', () async {
    var started = 0;
    var finished = 0;
    final file = await rive.File.decode(
      loadFile('assets/out_of_band.riv'),
      riveFactory: rive.Factory.flutter,
      assetLoader: (asset, bytes) {
        if (asset is rive.ImageAsset) {
          started++;
          rive.Factory.flutter.decodeImage(png).then((image) {
            finished++;
            image?.dispose();
          });
        }
        return true;
      },
    );
    expect(started, isPositive);
    expect(finished, started);
    file!.dispose();
  });
}
