import 'dart:io';

enum RemoteRole { none, controller, receiver }

/// The remote device resolves media using its own Bilibili account.
class RemoteVideo {
  const RemoteVideo({
    required this.aid,
    required this.bvid,
    required this.cid,
    this.type = 'ugc',
    this.seasonId,
    this.epId,
    this.pgcType,
    this.title = '',
    this.cover = '',
    this.progress,
    this.autoplay = true,
  });

  final int aid;
  final String bvid;
  final int cid;
  final String type;
  final int? seasonId;
  final int? epId;
  final int? pgcType;
  final String title;
  final String cover;
  final int? progress;
  final bool autoplay;

  factory RemoteVideo.fromJson(Map<String, dynamic> json) {
    final aid = json['aid'];
    final cid = json['cid'];
    final bvid = json['bvid'];
    final type = json['type'];
    if (aid is! int ||
        aid <= 0 ||
        cid is! int ||
        cid <= 0 ||
        bvid is! String ||
        !RegExp(r'^BV[0-9A-Za-z]{10}$').hasMatch(bvid) ||
        (type != 'ugc' && type != 'pgc' && type != 'pugv') ||
        json['autoplay'] is! bool) {
      throw const FormatException('视频信息无效');
    }
    for (final key in ['seasonId', 'epId', 'pgcType', 'progress']) {
      final value = json[key];
      if (value != null && (value is! int || value < 0)) {
        throw const FormatException('视频参数无效');
      }
    }
    for (final key in ['title', 'cover']) {
      if (json[key] != null && json[key] is! String) {
        throw const FormatException('视频参数无效');
      }
    }
    return RemoteVideo(
      aid: aid,
      bvid: bvid,
      cid: cid,
      type: type as String,
      seasonId: json['seasonId'] as int?,
      epId: json['epId'] as int?,
      pgcType: json['pgcType'] as int?,
      title: json['title'] as String? ?? '',
      cover: json['cover'] as String? ?? '',
      progress: json['progress'] as int?,
      autoplay: json['autoplay'] as bool,
    );
  }

  Map<String, dynamic> toJson() => {
    'aid': aid,
    'bvid': bvid,
    'cid': cid,
    'type': type,
    'seasonId': seasonId,
    'epId': epId,
    'pgcType': pgcType,
    'title': title,
    'cover': cover,
    'progress': progress,
    'autoplay': autoplay,
  };
}

/// No hostnames or public Internet destinations: this feature is LAN-only.
bool isRemoteLanAddress(InternetAddress address) {
  if (address.type != InternetAddressType.IPv4) return false;
  final bytes = address.rawAddress;
  return address.isLoopback ||
      bytes[0] == 10 ||
      (bytes[0] == 172 && bytes[1] >= 16 && bytes[1] <= 31) ||
      (bytes[0] == 192 && bytes[1] == 168) ||
      (bytes[0] == 169 && bytes[1] == 254);
}

void validateRemoteState(Map<String, dynamic> state) {
  for (final key in [
    'selection',
    'cid',
    'position',
    'duration',
    'volume',
    'speed',
  ]) {
    final value = state[key];
    if (value != null && (value is! num || !value.isFinite || value < 0)) {
      throw const FormatException('播放状态无效');
    }
  }
  for (final key in ['ready', 'playing', 'danmaku']) {
    if (state[key] != null && state[key] is! bool) {
      throw const FormatException('播放状态无效');
    }
  }
  for (final key in ['title', 'bvid', 'error']) {
    if (state[key] != null && state[key] is! String) {
      throw const FormatException('播放状态无效');
    }
  }
}
