import 'dart:io';

import 'package:PiliPlus/common/widgets/scaffold/simple_scaffold.dart';
import 'package:PiliPlus/services/remote/remote_control_service.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';

class RemoteModePage extends StatefulWidget {
  const RemoteModePage({super.key});

  @override
  State<RemoteModePage> createState() => _RemoteModePageState();
}

class _RemoteModePageState extends State<RemoteModePage> {
  final _service = RemoteControlService.instance;
  final _address = TextEditingController();
  final _code = TextEditingController();
  bool _busy = false;
  String? _error;

  Future<void> _exit() async {
    await _service.stop();
    if (mounted) Get.until((route) => route.isFirst);
  }

  Future<void> _run(Future<void> Function() action) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } catch (exception) {
      if (mounted) {
        setState(
          () => _error = switch (exception) {
            StateError() => exception.message,
            FormatException() => exception.message,
            WebSocketException(httpStatusCode: 401) =>
              '配对码错误或已过期，请在 Pad 上刷新配对码。',
            WebSocketException(httpStatusCode: 409) =>
              'Pad 已连接另一台遥控设备，请先断开原连接。',
            WebSocketException(httpStatusCode: 429) => '配对尝试过于频繁，请三十秒后重试。',
            _ => '连接失败，请检查地址和配对码，确认两台设备在同一局域网且允许互访。',
          },
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    _address.dispose();
    _code.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Obx(() {
    if (_service.isReceiver && _service.connected.value) {
      return PopScope(
        onPopInvokedWithResult: (didPop, _) {
          if (didPop) _service.stop();
        },
        child: const Scaffold(
          backgroundColor: Colors.black,
          body: RemoteReceiverWaiting(),
        ),
      );
    }
    return SimpleScaffold(
      appBar: AppBar(title: const Text('遥控模式')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          const Text('两台设备连接同一 Wi-Fi 或热点。在 Pad 上开启被控模式，再在手机上输入配对信息。'),
          const SizedBox(height: 20),
          if (_service.isReceiver) ...[
            const Text('等待遥控端配对', style: TextStyle(fontSize: 20)),
            const SizedBox(height: 12),
            for (final address in _service.addresses)
              ListTile(
                title: SelectableText('$address:${_service.transport.port}'),
                subtitle: const Text('在遥控端输入此地址'),
                trailing: IconButton(
                  tooltip: '复制地址',
                  icon: const Icon(Icons.copy),
                  onPressed: () => Clipboard.setData(
                    ClipboardData(text: '$address:${_service.transport.port}'),
                  ),
                ),
              ),
            SelectableText(
              '配对码：${_service.transport.pairingCode}',
              style: const TextStyle(fontSize: 24),
            ),
            const Text('配对码十分钟内有效。配对后 Pad 只显示等待提示和视频，按返回键退出。'),
            const SizedBox(height: 16),
            OutlinedButton(
              onPressed: _busy ? null : () => _run(_service.startReceiver),
              child: const Text('刷新配对码'),
            ),
          ] else if (_service.isController) ...[
            Text(
              _service.connected.value ? '已连接被控端' : '遥控连接已断开',
              style: const TextStyle(fontSize: 20),
            ),
            const SizedBox(height: 12),
            const Text('返回主页正常选片；详情页中的视频区域会变成遥控面板，评论、简介和选集保持原样。'),
            if (_service.connected.value)
              FilledButton(
                onPressed: Get.back,
                child: const Text('开始选片'),
              ),
          ] else ...[
            FilledButton.icon(
              onPressed: _busy ? null : () => _run(_service.startReceiver),
              icon: const Icon(Icons.tablet),
              label: const Text('作为被控端（Pad）'),
            ),
          ],
          if (!_service.isReceiver && !_service.connected.value) ...[
            const SizedBox(height: 24),
            const Text('作为遥控端（手机）', style: TextStyle(fontSize: 20)),
            const SizedBox(height: 12),
            TextField(
              controller: _address,
              decoration: const InputDecoration(
                labelText: 'Pad 地址',
                hintText: '192.168.1.20:12345',
              ),
              autocorrect: false,
            ),
            TextField(
              controller: _code,
              decoration: const InputDecoration(labelText: '六位配对码'),
              keyboardType: TextInputType.number,
              maxLength: 6,
            ),
            FilledButton(
              onPressed: _busy
                  ? null
                  : () =>
                        _run(() => _service.connect(_address.text, _code.text)),
              child: const Text('连接 Pad'),
            ),
          ],
          if (_service.isReceiver || _service.isController) ...[
            const SizedBox(height: 12),
            OutlinedButton(
              onPressed: _busy ? null : () => _run(_exit),
              child: const Text('退出遥控模式'),
            ),
          ],
          if (_busy) const LinearProgressIndicator(),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(_error!),
            ),
        ],
      ),
    );
  });
}

class RemoteReceiverWaiting extends StatelessWidget {
  const RemoteReceiverWaiting({super.key, this.message});
  final String? message;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Text(
        message ?? '正处于被控状态，请在遥控端选择视频并播放。',
        textAlign: TextAlign.center,
        style: const TextStyle(color: Colors.white70, fontSize: 20),
      ),
    ),
  );
}
