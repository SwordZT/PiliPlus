import 'dart:async';
import 'dart:io';

import 'package:PiliPlus/models/common/video/video_type.dart';
import 'package:PiliPlus/plugin/pl_player/controller.dart';
import 'package:PiliPlus/services/remote/remote_protocol.dart';
import 'package:PiliPlus/services/remote/remote_transport.dart';
import 'package:PiliPlus/utils/page_utils.dart';
import 'package:get/get.dart';
import 'package:flutter/services.dart';
import 'package:PiliPlus/utils/platform_utils.dart';
import 'package:PiliPlus/utils/device_utils.dart';
import 'package:PiliPlus/utils/permission_handler.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

class RemotePlaybackTarget {
  const RemotePlaybackTarget({
    required this.selection,
    required this.snapshot,
    required this.command,
  });
  final int selection;
  final Map<String, dynamic> Function() snapshot;
  final Future<void> Function(String, dynamic) command;
}

class RemoteControlService {
  RemoteControlService._() {
    transport = RemoteTransport(
      onChanged: _connectionChanged,
      onState: (value) => state.value = value,
      onCommand: _receiveCommand,
    );
  }

  static final instance = RemoteControlService._();
  late final RemoteTransport transport;
  final role = RemoteRole.none.obs;
  final connected = false.obs;
  final state = <String, dynamic>{}.obs;
  final error = ''.obs;
  final addresses = <String>[].obs;
  Timer? _ticker;
  RemotePlaybackTarget? _target;
  RemoteVideo? _video;
  int selection = 0;
  int _openGeneration = 0;

  bool get isController => role.value == RemoteRole.controller;
  bool get isReceiver => role.value == RemoteRole.receiver;
  bool get hasSelectedVideo => _video != null;

  Future<void> _requestLanPermission() async {
    if (Platform.isAndroid && DeviceUtils.sdkInt >= 37) {
      final permission = await Permission.accessLocalNetwork.request();
      if (!permission.isGranted) throw StateError('请允许 PiliPlus 访问本地网络');
    }
  }

  void _connectionChanged() {
    final wasConnected = connected.value;
    role.value = transport.role;
    connected.value = transport.connected;
    if (wasConnected && !transport.connected) {
      error.value = '遥控连接已断开，请重新配对';
      if (isReceiver) {
        ++selection;
        _target = null;
        _video = null;
        unawaited(PlPlayerController.pauseIfExists() ?? Future.value());
      }
    }
    if (transport.connected) {
      error.value = '';
      if (isReceiver && PlatformUtils.isMobile) {
        unawaited(
          SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky),
        );
      }
    }
  }

  Future<void> startReceiver() async {
    await _requestLanPermission();
    await stop();
    final interfaces = await NetworkInterface.list(
      type: InternetAddressType.IPv4,
    );
    addresses.assignAll([
      for (final interface in interfaces)
        for (final address in interface.addresses)
          if (isRemoteLanAddress(address) && !address.isLoopback)
            address.address,
    ]);
    if (addresses.isEmpty) throw StateError('未找到局域网地址，请先连接 Wi-Fi 或热点');
    await PlPlayerController.pauseIfExists();
    await transport.startReceiver();
    if (PlatformUtils.isMobile) await WakelockPlus.enable();
    _ticker = Timer.periodic(
      const Duration(milliseconds: 500),
      (_) => _publish(),
    );
  }

  Future<void> connect(String address, String code) async {
    await _requestLanPermission();
    await stop();
    await PlPlayerController.pauseIfExists();
    await transport.connect(address.trim(), code.trim());
  }

  Future<void> openVideo(RemoteVideo video) async {
    final generation = ++_openGeneration;
    // A new detail page requests playback from initState. Existing panels on
    // earlier routes must not be notified while Flutter is building that page.
    await Future<void>.delayed(Duration.zero);
    if (generation != _openGeneration) return;
    error.value = '';
    state.value = <String, dynamic>{};
    try {
      await transport.command('open', video.toJson());
    } catch (_) {
      if (generation == _openGeneration) {
        error.value = connected.value ? '被控端未能打开视频，请重试' : '遥控连接已断开，请重新配对';
      }
      rethrow;
    }
  }

  Future<void> send(String command, [dynamic value]) async {
    error.value = '';
    try {
      await transport.command(command, {
        'value': value,
        'selection': state['selection'],
      });
    } catch (exception) {
      error.value = connected.value ? '遥控操作失败：$exception' : '遥控连接已断开，请重新配对';
    }
  }

  Future<void> _receiveCommand(Map<String, dynamic> message) async {
    final payload = message['payload'];
    if (payload is! Map<String, dynamic>) throw const FormatException('遥控参数无效');
    final command = message['command'];
    if (command == 'open') {
      final video = RemoteVideo.fromJson(payload);
      _video = video;
      ++selection;
      error.value = '';
      _target = null;
      PageUtils.toVideoPage(
        aid: video.aid,
        bvid: video.bvid,
        cid: video.cid,
        videoType: VideoType.values.byName(video.type),
        seasonId: video.seasonId,
        epId: video.epId,
        pgcType: video.pgcType,
        title: video.title,
        cover: video.cover,
        progress: video.progress,
        off: Get.currentRoute == '/videoV',
        extraArguments: {
          'remoteReceiver': true,
          'remoteSelection': selection,
          'remoteAutoplay': video.autoplay,
        },
      );
      _publish();
      return;
    }
    final target = _target;
    if (target == null ||
        target.selection != selection ||
        payload['selection'] != selection) {
      throw StateError('视频已切换或正在准备，请稍后重试');
    }
    if (command is! String ||
        ![
          'play',
          'pause',
          'seek',
          'volume',
          'danmaku',
          'speed',
        ].contains(command)) {
      throw const FormatException('未知遥控操作');
    }
    final value = payload['value'];
    if (command == 'danmaku') {
      if (value is! bool) throw const FormatException('弹幕参数无效');
    } else if (command != 'play' && command != 'pause') {
      if (value is! num ||
          !value.isFinite ||
          (command == 'seek' && value < 0) ||
          (command == 'volume' && (value < 0 || value > 1)) ||
          (command == 'speed' && (value < 0.25 || value > 4))) {
        throw const FormatException('遥控参数超出范围');
      }
    }
    // Native player calls can stall while a media source is unavailable. Keep
    // later commands (especially selecting another video) from being blocked.
    await target.command(command, value).timeout(const Duration(seconds: 5));
    _publish();
  }

  void attach(RemotePlaybackTarget target) {
    if (target.selection == selection) _target = target;
  }

  void detach(RemotePlaybackTarget target) {
    if (identical(_target, target)) _target = null;
  }

  void playbackError(int requestSelection, String message) {
    if (isReceiver && requestSelection == selection) {
      error.value = message;
      _publish();
    }
  }

  void _publish() {
    if (!isReceiver || !connected.value) return;
    final video = _video;
    transport.publish({
      'selection': selection,
      'bvid': video?.bvid,
      'cid': video?.cid,
      'title': video?.title,
      'ready': false,
      ...?_target?.snapshot(),
      'error': error.value,
    });
  }

  Future<void> stop() async {
    ++_openGeneration;
    _ticker?.cancel();
    _ticker = null;
    if (isReceiver) {
      await PlPlayerController.pauseIfExists();
      if (PlatformUtils.isMobile) await WakelockPlus.disable();
      if (PlatformUtils.isMobile) {
        await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
      }
    }
    ++selection;
    _target = null;
    _video = null;
    await transport.stop();
    state.clear();
    error.value = '';
  }
}
