import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:PiliPlus/services/remote/remote_protocol.dart';

typedef RemoteCommandHandler = Future<void> Function(Map<String, dynamic>);

/// An authenticated, single-controller LAN connection. No credentials persist.
class RemoteTransport {
  RemoteTransport({this.onChanged, this.onState, this.onCommand});

  final void Function()? onChanged;
  final void Function(Map<String, dynamic>)? onState;
  final RemoteCommandHandler? onCommand;
  RemoteRole role = RemoteRole.none;
  HttpServer? _server;
  WebSocket? _socket;
  HttpClient? _client;
  bool _upgrading = false;
  String pairingCode = '';
  DateTime _codeExpiry = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _blockedUntil = DateTime.fromMillisecondsSinceEpoch(0);
  int _failedAttempts = 0;
  int _sequence = 0;
  int _generation = 0;
  Future<void> _queue = Future.value();
  final _pending = <String, Completer<void>>{};

  bool get connected => _socket != null;
  int? get port => _server?.port;

  void _newCode() {
    pairingCode = (Random.secure().nextInt(900000) + 100000).toString();
    _codeExpiry = DateTime.now().add(const Duration(minutes: 10));
  }

  Future<void> startReceiver({InternetAddress? address}) async {
    await stop();
    _server = await HttpServer.bind(address ?? InternetAddress.anyIPv4, 0);
    role = RemoteRole.receiver;
    _failedAttempts = 0;
    _blockedUntil = DateTime.fromMillisecondsSinceEpoch(0);
    _newCode();
    _server!.listen(_accept);
    onChanged?.call();
  }

  Future<void> _reject(HttpRequest request, int status) async {
    request.response.statusCode = status;
    await request.response.close();
  }

  Future<void> _accept(HttpRequest request) async {
    if (request.uri.path != '/remote' ||
        !WebSocketTransformer.isUpgradeRequest(request)) {
      return _reject(request, HttpStatus.notFound);
    }
    final peer = request.connectionInfo?.remoteAddress;
    if (peer == null || !isRemoteLanAddress(peer)) {
      return _reject(request, HttpStatus.forbidden);
    }
    if (DateTime.now().isBefore(_blockedUntil)) {
      return _reject(request, HttpStatus.tooManyRequests);
    }
    if (request.headers.value('X-PiliPlus-Pairing') != pairingCode ||
        DateTime.now().isAfter(_codeExpiry)) {
      if (++_failedAttempts >= 5) {
        _blockedUntil = DateTime.now().add(const Duration(seconds: 30));
        _failedAttempts = 0;
      }
      return _reject(request, HttpStatus.unauthorized);
    }
    if (connected || _upgrading) return _reject(request, HttpStatus.conflict);
    _upgrading = true;
    final generation = _generation;
    try {
      final socket = await WebSocketTransformer.upgrade(request);
      if (generation != _generation) {
        await socket.close();
        return;
      }
      _failedAttempts = 0;
      _attach(socket);
    } catch (_) {
      // The request may have been cancelled while upgrading.
    } finally {
      _upgrading = false;
    }
  }

  Future<void> connect(String endpoint, String code) async {
    final uri = Uri.tryParse('ws://$endpoint/remote');
    final address = uri == null ? null : InternetAddress.tryParse(uri.host);
    if (uri == null ||
        address == null ||
        !isRemoteLanAddress(address) ||
        uri.userInfo.isNotEmpty ||
        uri.path != '/remote' ||
        uri.hasQuery ||
        uri.hasFragment ||
        !uri.hasPort ||
        uri.port < 1 ||
        uri.port > 65535 ||
        !RegExp(r'^\d{6}$').hasMatch(code)) {
      throw const FormatException('请输入局域网 IPv4 地址:端口和六位配对码');
    }
    await stop();
    role = RemoteRole.controller;
    onChanged?.call();
    final generation = _generation;
    final client = _client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 8)
      // LAN requests must not use an application's outbound HTTP proxy.
      ..findProxy = (_) => 'DIRECT';
    late WebSocket socket;
    try {
      socket = await WebSocket.connect(
        uri.toString(),
        headers: {'X-PiliPlus-Pairing': code},
        customClient: client,
      ).timeout(const Duration(seconds: 8));
    } catch (_) {
      client.close(force: true);
      if (identical(_client, client)) _client = null;
      rethrow;
    }
    if (generation != _generation) {
      await socket.close();
      return;
    }
    _attach(socket);
  }

  void _attach(WebSocket socket) {
    _socket = socket;
    socket.pingInterval = const Duration(seconds: 5);
    _queue = Future.value();
    socket.listen(
      (data) {
        _queue = _queue.then((_) => _receive(socket, data));
      },
      onDone: () => _lost(socket),
      onError: (Object _) => _lost(socket),
    );
    onChanged?.call();
  }

  Future<void> _receive(WebSocket socket, dynamic data) async {
    if (!identical(socket, _socket)) return;
    String? id;
    try {
      if (data is! String || data.length > 16384) {
        throw const FormatException('遥控消息无效');
      }
      final decoded = jsonDecode(data);
      if (decoded is! Map<String, dynamic> || decoded['version'] != 1) {
        throw const FormatException('遥控协议版本不兼容');
      }
      id = decoded['id'] as String?;
      switch (decoded['kind']) {
        case 'reply':
          if (role != RemoteRole.controller) return;
          final pending = _pending.remove(id);
          if (decoded['error'] is String) {
            pending?.completeError(StateError(decoded['error'] as String));
          } else {
            pending?.complete();
          }
        case 'state':
          if (role == RemoteRole.controller &&
              decoded['state'] is Map<String, dynamic>) {
            final state = decoded['state'] as Map<String, dynamic>;
            validateRemoteState(state);
            onState?.call(state);
          }
        case 'command':
          if (role != RemoteRole.receiver || id == null || onCommand == null) {
            throw const FormatException('遥控指令无效');
          }
          await onCommand!(decoded);
          if (identical(socket, _socket)) _send({'kind': 'reply', 'id': id});
        default:
          throw const FormatException('未知遥控消息');
      }
    } catch (error) {
      if (id != null &&
          role == RemoteRole.receiver &&
          identical(socket, _socket)) {
        _send({'kind': 'reply', 'id': id, 'error': error.toString()});
      } else {
        await socket.close(WebSocketStatus.policyViolation, 'Invalid message');
        _lost(socket);
      }
    }
  }

  void _send(Map<String, dynamic> message) {
    final socket = _socket;
    if (socket == null) throw StateError('遥控连接已断开');
    socket.add(jsonEncode({'version': 1, ...message}));
  }

  Future<void> command(
    String command, [
    Map<String, dynamic> payload = const {},
  ]) async {
    if (role != RemoteRole.controller || !connected) {
      throw StateError('遥控连接已断开，请重新配对');
    }
    final id = (++_sequence).toString();
    final pending = Completer<void>();
    _pending[id] = pending;
    try {
      _send({
        'kind': 'command',
        'id': id,
        'command': command,
        'payload': payload,
      });
      await pending.future.timeout(const Duration(seconds: 8));
    } finally {
      _pending.remove(id);
    }
  }

  void publish(Map<String, dynamic> state) {
    if (role == RemoteRole.receiver && connected) {
      _send({'kind': 'state', 'state': state});
    }
  }

  void _lost(WebSocket socket) {
    if (!identical(socket, _socket)) return;
    _socket = null;
    for (final pending in _pending.values) {
      pending.completeError(StateError('遥控连接已断开'));
    }
    _pending.clear();
    if (role == RemoteRole.receiver) _newCode();
    onChanged?.call();
  }

  Future<void> stop() async {
    ++_generation;
    final socket = _socket;
    if (socket != null) _lost(socket);
    _socket = null;
    role = RemoteRole.none;
    final server = _server;
    _server = null;
    await socket?.close();
    await server?.close(force: true);
    _client?.close(force: true);
    _client = null;
    onChanged?.call();
  }
}
