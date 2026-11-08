import 'package:flutter_test/flutter_test.dart';
import 'package:rive_native/rive_native.dart' as rive;

class _CountingFile extends rive.File {
  int boundaries = 0;
  final List<String>? log;

  _CountingFile([this.log]);

  @override
  String? frameBoundary() {
    boundaries++;
    log?.add('boundary');
    return null;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}

void main() {
  testWidgets('every live file gets one frame boundary per frame',
      (tester) async {
    final first = _CountingFile();
    final second = _CountingFile();
    for (var i = 0; i < 3; i++) {
      tester.binding.scheduleFrame();
      await tester.pump();
    }
    expect(first.boundaries, 3);
    expect(second.boundaries, 3);
  });

  testWidgets('the boundary runs after draws registered later than the file',
      (tester) async {
    final log = <String>[];
    final file = _CountingFile(log);
    tester.binding.addPersistentFrameCallback((_) => log.add('draw'));
    tester.binding.scheduleFrame();
    await tester.pump();
    expect(log, ['draw', 'boundary']);
    expect(file.boundaries, 1);
  });
}
