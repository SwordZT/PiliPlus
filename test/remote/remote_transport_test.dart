import 'dart:async';
import 'dart:io';

import 'package:PiliPlus/services/remote/remote_protocol.dart';
import 'package:PiliPlus/services/remote/remote_transport.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late RemoteTransport receiver;
  late RemoteTransport controller;

  Future<void> pair() async {
    await receiver.startReceiver(address: InternetAddress.loopbackIPv4);
    await controller.connect(
      '127.0.0.1:${receiver.port}',
      receiver.pairingCode,
    );
  }

  setUp(() {
    receiver = RemoteTransport();
    controller = RemoteTransport();
  });
  tearDown(() async {
    await controller.stop();
    await receiver.stop();
  });

  test('pairing authenticates before allowing a controller, and rejects a second controller', () async {
    await receiver.startReceiver(address: InternetAddress.loopbackIPv4);
    await expectLater(
      controller.connect('127.0.0.1:${receiver.port}', '000000'),
      throwsA(isA<WebSocketException>()),
    );
    expect(receiver.connected, isFalse);
    await controller.connect(
      '127.0.0.1:${receiver.port}',
      receiver.pairingCode,
    );
    expect(receiver.connected, isTrue);
    final second = RemoteTransport();
    try {
      await expectLater(
        second.connect('127.0.0.1:${receiver.port}', receiver.pairingCode),
        throwsA(isA<WebSocketException>()),
      );
      expect(controller.connected, isTrue);
    } finally {
      await second.stop();
    }
  });

  test('commands execute in order and playback status travels back to the controller', () async {
    final commands = <String>[];
    receiver = RemoteTransport(
      onCommand: (message) async {
        final command = message['command'] as String;
        if (command == 'open') {
          RemoteVideo.fromJson(message['payload'] as Map<String, dynamic>);
        }
        commands.add(command);
      },
    );
    final reported = Completer<Map<String, dynamic>>();
    controller = RemoteTransport(onState: reported.complete);
    await pair();
    const video = RemoteVideo(aid: 1, bvid: 'BV1xx411c7mD', cid: 2);
    await controller.command('open', video.toJson());
    await controller.command('pause');
    await controller.command('seek', {'value': 42});
    receiver.publish({
      'ready': true,
      'playing': false,
      'position': 42,
      'duration': 100,
      'volume': 0.5,
    });
    expect(commands, ['open', 'pause', 'seek']);
    expect(
      (await reported.future.timeout(const Duration(seconds: 2)))['position'],
      42,
    );
  });

  test(
    'receiver errors reach the sender and a later command can still succeed',
    () async {
      receiver = RemoteTransport(
        onCommand: (message) async {
          if (message['command'] == 'seek') throw StateError('video changed');
        },
      );
      await pair();
      await expectLater(controller.command('seek'), throwsA(isA<StateError>()));
      await controller.command('pause');
      expect(controller.connected, isTrue);
    },
  );

  test(
    'disconnect fails an in-flight command rather than acknowledging playback',
    () async {
      final started = Completer<void>();
      final finish = Completer<void>();
      receiver = RemoteTransport(
        onCommand: (_) async {
          started.complete();
          await finish.future;
        },
      );
      await pair();
      final result = expectLater(
        controller.command('play'),
        throwsA(isA<StateError>()),
      );
      await started.future;
      await receiver.stop();
      finish.complete();
      await result;
    },
  );

  test('pairing attempts are rate limited', () async {
    await receiver.startReceiver(address: InternetAddress.loopbackIPv4);
    for (var attempt = 0; attempt < 5; attempt++) {
      await expectLater(
        controller.connect('127.0.0.1:${receiver.port}', '000000'),
        throwsA(isA<WebSocketException>()),
      );
    }
    await expectLater(
      controller.connect('127.0.0.1:${receiver.port}', receiver.pairingCode),
      throwsA(
        isA<WebSocketException>().having(
          (error) => error.httpStatusCode,
          'HTTP status',
          HttpStatus.tooManyRequests,
        ),
      ),
    );
    expect(receiver.connected, isFalse);
  });

  test(
    'public destinations and malformed video/state data are rejected',
    () async {
      await expectLater(
        controller.connect('8.8.8.8:1234', '123456'),
        throwsFormatException,
      );
      await expectLater(
        controller.connect('example.com:1234', '123456'),
        throwsFormatException,
      );
      await expectLater(
        controller.connect('192.168.1.20:1234/path', '123456'),
        throwsFormatException,
      );
      expect(
        () => RemoteVideo.fromJson({
          'aid': 1,
          'cid': -1,
          'bvid': 'bad',
          'type': 'ugc',
          'autoplay': true,
        }),
        throwsFormatException,
      );
      expect(
        () => validateRemoteState({'volume': 'loud'}),
        throwsFormatException,
      );
      expect(
        () => validateRemoteState({'duration': double.infinity}),
        throwsFormatException,
      );
    },
  );
}
