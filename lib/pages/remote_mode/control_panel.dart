import 'package:PiliPlus/pages/remote_mode/view.dart';
import 'package:PiliPlus/services/remote/remote_control_service.dart';
import 'package:material_ui/material_ui.dart';
import 'package:get/get.dart';

class RemoteControlPanel extends StatefulWidget {
  const RemoteControlPanel({super.key, required this.onPlayVideo});
  final Future<void> Function() onPlayVideo;

  @override
  State<RemoteControlPanel> createState() => _RemoteControlPanelState();
}

class _RemoteControlPanelState extends State<RemoteControlPanel> {
  double? _seek;
  double? _volume;

  static String _time(num seconds) {
    final value = seconds.toInt();
    return '${value ~/ 60}:${(value % 60).toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final service = RemoteControlService.instance;
    return ColoredBox(
      color: Theme.of(context).colorScheme.surfaceContainer,
      child: Obx(() {
        final state = service.state;
        final connected = service.connected.value;
        final ready = connected && state['ready'] == true;
        final playing = state['playing'] == true;
        final duration = (state['duration'] as num? ?? 0).toDouble().clamp(
          0.0,
          double.maxFinite,
        );
        final position = (_seek ?? (state['position'] as num? ?? 0).toDouble())
            .clamp(
              0.0,
              duration,
            );
        final volume = (_volume ?? (state['volume'] as num? ?? 0).toDouble())
            .clamp(
              0.0,
              1.0,
            );
        final error = service.error.value.isNotEmpty
            ? service.error.value
            : state['error'] as String? ?? '';
        return SingleChildScrollView(
          padding: const EdgeInsets.all(12),
          child: Column(
            children: [
              Row(
                children: [
                  Icon(connected ? Icons.cast_connected : Icons.cast),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      connected
                          ? '遥控模式 · ${ready ? (playing ? 'Pad 正在播放' : '已暂停') : '等待播放'}'
                          : '遥控连接已断开',
                    ),
                  ),
                  IconButton(
                    tooltip: '管理遥控连接',
                    onPressed: () => Get.to(() => const RemoteModePage()),
                    icon: const Icon(Icons.settings_remote),
                  ),
                ],
              ),
              if (error.isNotEmpty)
                Text(
                  error,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              Text(
                state['title'] as String? ?? '视频在 Pad 上播放',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              Row(
                children: [
                  Text(_time(position)),
                  Expanded(
                    child: Slider(
                      value: position,
                      max: duration > 0 ? duration : 1,
                      onChanged: ready && duration > 0
                          ? (value) => setState(() => _seek = value)
                          : null,
                      onChangeEnd: ready && duration > 0
                          ? (value) async {
                              await service.send('seek', value);
                              if (mounted) setState(() => _seek = null);
                            }
                          : null,
                    ),
                  ),
                  Text(_time(duration)),
                ],
              ),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  IconButton(
                    tooltip: '快退 10 秒',
                    onPressed: ready
                        ? () => service.send(
                            'seek',
                            (position - 10).clamp(0.0, duration),
                          )
                        : null,
                    icon: const Icon(Icons.replay_10),
                  ),
                  IconButton(
                    tooltip: playing ? '暂停' : '播放',
                    onPressed: connected
                        ? () {
                            if (ready) {
                              service.send(playing ? 'pause' : 'play');
                            } else {
                              widget.onPlayVideo();
                            }
                          }
                        : null,
                    icon: Icon(
                      playing ? Icons.pause_circle : Icons.play_circle,
                    ),
                    iconSize: 38,
                  ),
                  IconButton(
                    tooltip: '快进 10 秒',
                    onPressed: ready
                        ? () => service.send(
                            'seek',
                            (position + 10).clamp(0.0, duration),
                          )
                        : null,
                    icon: const Icon(Icons.forward_10),
                  ),
                  const SizedBox(width: 12),
                  const Text('弹幕'),
                  Switch(
                    value: state['danmaku'] == true,
                    onChanged: ready
                        ? (value) => service.send('danmaku', value)
                        : null,
                  ),
                ],
              ),
              Row(
                children: [
                  const Icon(Icons.volume_up),
                  Expanded(
                    child: Slider(
                      value: volume,
                      onChanged: ready
                          ? (value) => setState(() => _volume = value)
                          : null,
                      onChangeEnd: ready
                          ? (value) async {
                              await service.send('volume', value);
                              if (mounted) setState(() => _volume = null);
                            }
                          : null,
                    ),
                  ),
                  Text('${(volume * 100).round()}%'),
                  const SizedBox(width: 12),
                  PopupMenuButton<double>(
                    enabled: ready,
                    tooltip: '播放速度',
                    onSelected: (value) => service.send('speed', value),
                    itemBuilder: (_) => [
                      for (final value in [0.5, 1.0, 1.25, 1.5, 2.0, 3.0])
                        PopupMenuItem(value: value, child: Text('${value}x')),
                    ],
                    child: Padding(
                      padding: const EdgeInsets.all(8),
                      child: Text('${state['speed'] ?? 1}x'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        );
      }),
    );
  }
}
