import 'package:PiliPlus/services/remote/remote_control_service.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';

class RemoteConnectionIndicator extends StatelessWidget {
  const RemoteConnectionIndicator({super.key});

  @override
  Widget build(BuildContext context) => Obx(() {
    final service = RemoteControlService.instance;
    if (!service.isController) return const SizedBox.shrink();
    return IconButton(
      tooltip: service.connected.value ? '遥控模式 · 已连接 Pad' : '遥控模式 · 连接已断开',
      onPressed: () => Get.toNamed('/remoteMode'),
      icon: Icon(service.connected.value ? Icons.cast_connected : Icons.cast),
    );
  });
}
