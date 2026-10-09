import 'package:PiliPlus/pages/remote_mode/control_panel.dart';
import 'package:PiliPlus/pages/remote_mode/view.dart';
import 'package:PiliPlus/services/remote/remote_control_service.dart';
import 'package:PiliPlus/services/remote/remote_protocol.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  final service = RemoteControlService.instance;
  tearDown(() {
    service.role.value = RemoteRole.none;
    service.connected.value = false;
    service.state.clear();
    service.error.value = '';
  });

  testWidgets(
    'remote panel fits a phone player area and reflects received playback state',
    (tester) async {
      service.role.value = RemoteRole.controller;
      service.connected.value = true;
      service.state.value = {
        'ready': true,
        'playing': true,
        'position': 42,
        'duration': 100,
        'volume': 0.35,
        'danmaku': true,
        'speed': 1.5,
        'title': 'Pad 上的视频',
      };
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 360,
                height: 220,
                child: RemoteControlPanel(onPlayVideo: () async {}),
              ),
            ),
          ),
        ),
      );
      expect(find.text('0:42'), findsOneWidget);
      expect(find.text('1:40'), findsOneWidget);
      expect(find.text('Pad 上的视频'), findsOneWidget);
      expect(find.byTooltip('暂停'), findsOneWidget);
      expect(tester.takeException(), isNull);
      service.connected.value = false;
      await tester.pump();
      expect(find.text('遥控连接已断开'), findsOneWidget);
      final play = tester.widget<IconButton>(
        find.byWidgetPredicate(
          (widget) => widget is IconButton && widget.tooltip == '暂停',
        ),
      );
      expect(play.onPressed, isNull);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'manual playback opens the selected remote video without a local player',
    (tester) async {
      service.role.value = RemoteRole.controller;
      service.connected.value = true;
      var requested = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 360,
              height: 240,
              child: RemoteControlPanel(
                onPlayVideo: () async {
                  requested++;
                },
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.byTooltip('播放'));
      await tester.pump();
      expect(requested, 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'selecting from a new page does not refresh an older panel during build',
    (tester) async {
      service.state.value = {'title': '上一视频', 'ready': true};
      Future<void>? result;
      await tester.pumpWidget(
        MaterialApp(
          home: Material(
            child: Column(
              children: [
                SizedBox(
                  width: 360,
                  height: 240,
                  child: RemoteControlPanel(onPlayVideo: () async {}),
                ),
                Builder(
                  builder: (_) {
                    result ??= expectLater(
                      service.openVideo(
                        const RemoteVideo(
                          aid: 2,
                          bvid: 'BV1xx411c7mD',
                          cid: 62131,
                        ),
                      ),
                      throwsA(isA<StateError>()), // No connection in this test.
                    );
                    return const SizedBox.shrink();
                  },
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 1));
      await result;
      expect(tester.takeException(), isNull);
      expect(service.state, isEmpty);
    },
  );

  testWidgets(
    'paired receiver waiting screen contains only the waiting message',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: RemoteReceiverWaiting())),
      );
      expect(find.text('正处于被控状态，请在遥控端选择视频并播放。'), findsOneWidget);
      expect(find.byType(IconButton), findsNothing);
      expect(find.byType(Slider), findsNothing);
    },
  );
}
