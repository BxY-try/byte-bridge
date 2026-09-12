import 'package:socket_io_client/socket_io_client.dart' as io;

class SocketService {
  io.Socket? _socket;
  void Function(Map<String, dynamic> data)? onMediaState;

  void connect({
    required String ip,
    required int port,
    required void Function() onConnect,
    required void Function() onDisconnect,
    required void Function(dynamic error) onError,
    void Function(Map<String, dynamic> data)? onMediaState,
  }) {
    this.onMediaState = onMediaState;
    _socket?.dispose();

    _socket = io.io(
      'http://$ip:$port',
      io.OptionBuilder()
          .setTransports(['websocket'])
          .enableAutoConnect()
          .enableReconnection()
          .setReconnectionAttempts(1000000) // Praktis unlimited selama app hidup
          .setReconnectionDelay(1000)
          .setReconnectionDelayMax(5000)
          .build(),
    );

    _socket!.onConnect((_) => onConnect());
    _socket!.onDisconnect((_) => onDisconnect());
    _socket!.onConnectError((err) => onError(err));
    _socket!.onError((err) => onError(err));

    _socket!.on('media_state', (data) {
      if (data != null && data is Map) {
        final Map<String, dynamic> map = Map<String, dynamic>.from(data);
        this.onMediaState?.call(map);
      }
    });
  }

  void sendMediaCommand(String action, [dynamic value]) {
    final Map<String, dynamic> payload = {'action': action};
    if (value != null) {
      payload['value'] = value;
    }
    _socket?.emit('media_command', payload);
  }

  void sendKey(String key) {
    _socket?.emit('keypress', {'key': key});
  }

  void sendHotkey(List<String> keys) {
    _socket?.emit('hotkey', {'keys': keys});
  }

  void sendMouseMove(double dx, double dy) {
    _socket?.emit('mouse_move', {'dx': dx, 'dy': dy});
  }

  void sendMouseClick(String button) {
    _socket?.emit('mouse_click', {'button': button});
  }

  void sendMouseScroll(int dy) {
    _socket?.emit('mouse_scroll', {'dy': dy});
  }

  void sendTextInput(String text) {
    _socket?.emit('text_input', {'text': text});
  }

  bool get isConnected => _socket?.connected ?? false;

  void disconnect() {
    _socket?.disconnect();
  }

  void dispose() {
    _socket?.dispose();
  }
}
