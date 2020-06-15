/// https://github.com/tanutapi/dart_meteor/blob/master/lib/src/ddp_client.dart
/// @author https://github.com/tanutapi

import 'dart:convert';
import 'dart:io';
import 'dart:async';
import 'dart:math';

const debug = true;

enum DDPConnectionStatusValues {
  connected,
  connecting,
  failed,
  waiting,
  offline
}

class DDPConnectionStatus {
  bool connected;
  DDPConnectionStatusValues status;
  int retryCount;
  Duration retryTime;
  String reason;

  DDPConnectionStatus(
      {this.connected,
      this.status,
      this.retryCount,
      this.retryTime,
      this.reason});

  @override
  String toString() {
    return 'connected: $connected, status: $status, retryCount: $retryCount, retryTime: $retryTime, reason: $reason';
  }
}

class SubscriptionHandler {
  DDP ddp;
  String subId;
  StreamController<bool> readyStreamController = StreamController();
  Stream<bool> _readyStream;
  SubscriptionHandler(this.ddp, this.subId) {
    _readyStream = readyStreamController.stream.asBroadcastStream();
    readyStreamController.sink.add(false);
  }
  Stream<bool> ready() {
    return _readyStream;
  }

  void stop() {
    if (ddp != null && ddp._connectionStatus.connected) {
      ddp._sendMsgUnsub(subId);
    }
  }
}

class SubscriptionCallback {
  Function onStop;
  Function onReady;
  SubscriptionCallback({this.onStop(dynamic error), this.onReady});
}

class OnReconnectionCallback {
  DDP ddpClient;
  String id;
  Function callback;
  OnReconnectionCallback({this.ddpClient, this.id, this.callback});

  void stop() {
    if (ddpClient != null) {
      ddpClient.onReconnectCallbacks.remove(id);
    }
  }
}

class DDP {
  final int PING_SEC_INTERVAL = 20;
  final int PONG_WITHIN_SEC = 5;
  final Random _random = Random.secure();

  StreamController<DDPConnectionStatus> statusStreamController =
      StreamController();
  StreamController<dynamic> dataStreamController = StreamController();
  DDPConnectionStatus _connectionStatus;
  String _url;
  WebSocket _socket;
  int _maxRetryCount = 20;
  Map<String, OnReconnectionCallback> onReconnectCallbacks = {};
  String _sessionId;
  int _currentMethodId = 0;
  bool _flagToBeResetAtPongMsg = false;
  Timer _pingPeriodicTimer;
  Map<String, Completer<dynamic>> methodCompleters = {};
  Map<String, SubscriptionCallback> subscriptions = {};
  Map<String, SubscriptionHandler> subscriptionHandlers = {};
  bool _isTryToReconnect = true;
  Timer _scheduleReconnectTimer;

  DDP({String url, int maxRetryCount = 20}) {
    _url = url;
    _maxRetryCount = maxRetryCount;
    _connectionStatus = DDPConnectionStatus(
      connected: false,
      status: DDPConnectionStatusValues.waiting,
      retryCount: 0,
      retryTime: Duration(seconds: 0),
      reason: null,
    );
    statusStreamController.sink.add(_connectionStatus);
    _connect();
  }

  void debugger(String str) {
    if (debug) {
      print('DDP${_socket.hashCode} - ${DateTime.now()}');
      print('DDP${_socket.hashCode} - $str');
    }
  }

  /// Register a function to call as the first step of reconnecting.
  /// This function can call methods which will be executed before any other outstanding methods.
  /// For example, this can be used to re-establish the appropriate authentication context on the connection.
  /// callback:
  /// The function to call. It will be called with a single argument, the connection object that is reconnecting.
  void onReconnect(void callback(OnReconnectionCallback reconnection)) {
    String id = _generateUID(16);
    var onReconnectCallback =
        OnReconnectionCallback(ddpClient: this, id: id, callback: callback);
    onReconnectCallbacks[id] = onReconnectCallback;
  }

  String _generateUID(int numOfByte) {
    var values = List<int>.generate(numOfByte, (i) => _random.nextInt(256));
    return base64Url.encode(values);
  }

  SubscriptionHandler subscribe(String name, List<dynamic> params,
      {Function onStop(dynamic error), Function onReady}) {
    String id = name + '-' + _generateUID(16);
    subscriptions[id] = SubscriptionCallback(onStop: onStop, onReady: onReady);
    var handler = SubscriptionHandler(this, id);
    subscriptionHandlers[id] = handler;
    _sendMsgSub(id, name, params);
    return handler;
  }

  Future<dynamic> call(String method, List<dynamic> params) {
    return apply(method, params);
  }

  Future<dynamic> apply(String method, List<dynamic> params) {
    var methodCompleter = Completer<dynamic>();
    String newId = _currentMethodId.toString();
    _sendMsgMethod(method, params, newId);
    _currentMethodId++;
    methodCompleters[newId] = methodCompleter;
    return methodCompleter.future;
  }

  Stream<DDPConnectionStatus> status() {
    return statusStreamController.stream;
  }

  void reconnect() {
    print('reconnect... ${_connectionStatus}');
    if (_connectionStatus.status != DDPConnectionStatusValues.connected &&
        _connectionStatus.status != DDPConnectionStatusValues.connecting) {
      if (_scheduleReconnectTimer != null) {
        if (_scheduleReconnectTimer.isActive) {
          _scheduleReconnectTimer.cancel();
          _scheduleReconnectTimer = null;
        }
      }
      _connect();
    }
  }

  void disconnect() {
    debugger('init disconnect()');
    _isTryToReconnect = false;
    if (_socket != null) {
      _socket.close().then((value) {
        _socket = null;
      }).catchError((err) {
        debugger(err);
        _socket = null;
      });
    }
    // Cancel ping-pong timer
    if (_pingPeriodicTimer != null) {
      _pingPeriodicTimer.cancel();
      _pingPeriodicTimer = null;
    }

    // Reset ping-pong flag
    _flagToBeResetAtPongMsg = false;

    _sessionId = null;
    _connectionStatus.connected = false;
    _connectionStatus.status = DDPConnectionStatusValues.offline;
    _connectionStatus.retryCount = 0;
    _connectionStatus.reason = null;
    statusStreamController.sink.add(_connectionStatus);
    debugger('end disconnect()');
  }

  void _connect() async {
    if (_connectionStatus.status != DDPConnectionStatusValues.connected &&
        _connectionStatus.status != DDPConnectionStatusValues.connecting) {
      _isTryToReconnect = true;
      _connectionStatus.status = DDPConnectionStatusValues.connecting;
      _connectionStatus.reason = null;
      statusStreamController.sink.add(_connectionStatus);
      try {
        WebSocket socket =
            await WebSocket.connect(_url).timeout(Duration(seconds: 5));
        _connectionStatus.retryCount = 0;
        _connectionStatus.retryTime = Duration(seconds: 1);
        _socket = socket;
        _socket.listen(_onData,
            onDone: _onDone, onError: _onError, cancelOnError: true);
      } catch (err) {
        print(err);
        _connectionStatus.status = DDPConnectionStatusValues.failed;
        _connectionStatus.reason = err.toString();
        statusStreamController.sink.add(_connectionStatus);
        _socket = null;
        debugger(
            'Reconnecting due to websocket exception while trying to connect');
        _scheduleReconnect();
      }
      ;
    }
  }

  void _scheduleReconnect() {
    if (_connectionStatus.status == DDPConnectionStatusValues.offline ||
        _connectionStatus.status == DDPConnectionStatusValues.failed) {
      _connectionStatus.retryCount++;
      if (_connectionStatus.retryCount <= _maxRetryCount) {
        _connectionStatus.connected = false;
        _connectionStatus.status = DDPConnectionStatusValues.waiting;
        _connectionStatus.retryTime =
            Duration(seconds: min(5 * (_connectionStatus.retryCount - 1), 30));
        _connectionStatus.reason = null;
        statusStreamController.sink.add(_connectionStatus);
        debugger('Retry to connect in ${_connectionStatus.retryTime}');

        if (_scheduleReconnectTimer != null) {
          if (_scheduleReconnectTimer.isActive) {
            _scheduleReconnectTimer.cancel();
            _scheduleReconnectTimer = null;
          }
        }
        _scheduleReconnectTimer = Timer(_connectionStatus.retryTime, () {
          debugger('Retry connect: ${_connectionStatus.retryCount}');
          _connect();
        });
      } else {
        _connectionStatus.connected = false;
        _connectionStatus.status = DDPConnectionStatusValues.failed;
        _connectionStatus.reason = 'DDP reach max retry attempt';
        statusStreamController.sink.add(_connectionStatus);
      }
    }
  }

  void _sendMsgConnect() {
    if (_socket != null) {
      var data = {
        'msg': 'connect',
        'version': '1',
        'support': ['1'],
      };
      if (_sessionId != null) {
        data['session'] = _sessionId;
      }
      var msg = json.encode(data);
      debugger('Send: $msg');
      _socket.add(msg);
    }
  }

  void _sendMsgPing() {
    if (_socket != null) {
      var msg = json.encode({'msg': 'ping'});
      debugger('Send: $msg');
      _socket.add(msg);
      DateTime sentTime = DateTime.now();
      _flagToBeResetAtPongMsg = true;
      Future.delayed(Duration(seconds: PONG_WITHIN_SEC), () {
        if (_flagToBeResetAtPongMsg == true) {
          debugger('');
          debugger('Disconnect due to not receive PONG');
          debugger('PING was sent since $sentTime');
          debugger('Current time is ${DateTime.now()}');
          debugger(
              'Diff since PING sent is ${DateTime.now().difference(sentTime)}');
          disconnect();
        }
      });
    }
  }

  void _sendMsgPong() {
    if (_socket != null) {
      var msg = json.encode({'msg': 'pong'});
      debugger('Send: $msg');
      _socket.add(msg);
    }
  }

  void _sendMsgSub(String id, String name, List<dynamic> params) {
    if (_socket != null) {
      var data = {
        'msg': 'sub',
        'name': name,
        'params': params,
        'id': id,
      };
      var msg = json.encode(data);
      debugger('Send: $msg');
      _socket.add(msg);
    }
  }

  void _sendMsgUnsub(String id) {
    if (_socket != null) {
      var data = {
        'msg': 'unsub',
        'id': id,
      };
      var msg = json.encode(data);
      debugger('Send: $msg');
      _socket.add(msg);
    }
  }

  void _sendMsgMethod(String method, List<dynamic> params, String id,
      {Map<String, dynamic> randomSeed}) {
    if (_socket != null) {
      var data = {
        'msg': 'method',
        'method': method,
        'params': params,
        'id': id,
      };
      if (randomSeed != null) {
        data['randomSeed'] = randomSeed;
      }
      var msg = json.encode(data);
      debugger('Send: $msg');
      _socket.add(msg);
    }
  }

  void _onData(dynamic data) {
    debugger('Recv: $data');
    var dataMap = json.decode(data) ?? {};
    var msg = dataMap['msg'];
    if (_connectionStatus.status == DDPConnectionStatusValues.connecting) {
      if (dataMap['server_id'] != null) {
        _sendMsgConnect();
      } else if (msg == 'connected') {
        onReconnectCallbacks.values.forEach((reconnectCallback) {
          reconnectCallback.callback(reconnectCallback);
        });

        _connectionStatus.connected = true;
        _connectionStatus.status = DDPConnectionStatusValues.connected;
        _connectionStatus.reason = null;
        statusStreamController.sink.add(_connectionStatus);
        _sessionId = dataMap['session'];

        // Cancel ping-pong timer
        if (_pingPeriodicTimer != null) {
          _pingPeriodicTimer.cancel();
          _pingPeriodicTimer = null;
        }

        _pingPeriodicTimer =
            Timer.periodic(Duration(seconds: PING_SEC_INTERVAL), (timer) {
          _sendMsgPing();
        });
      } else if (msg == 'failed') {
        _sessionId = null;
        _connectionStatus.connected = false;
        _connectionStatus.status = DDPConnectionStatusValues.failed;
        _connectionStatus.reason =
            'Failed connect to server. Protocol version ${dataMap['version']} is suggested!';
        statusStreamController.sink.add(_connectionStatus);
      }
    } else if (_connectionStatus.status ==
        DDPConnectionStatusValues.connected) {
      if (msg == 'ping') {
        _sendMsgPong();
      } else if (msg == 'pong') {
        _flagToBeResetAtPongMsg = false;
      } else if (msg == 'nosub') {
        if (dataMap['id'] != null) {
          String id = dataMap['id'];
          SubscriptionCallback sub = subscriptions[id];
          if (sub != null && sub.onStop != null) {
            sub.onStop(dataMap['error']);
            subscriptions.remove(id);
            sub = null;
          } else if (sub == null) {
            debugger('Unknow nosub error!');
          }
          SubscriptionHandler handler = subscriptionHandlers[id];
          if (handler != null) {
            subscriptionHandlers.remove(id);
            handler = null;
          }
        }
      } else if (msg == 'added') {
        dataStreamController.sink.add(dataMap);
      } else if (msg == 'changed') {
        dataStreamController.sink.add(dataMap);
      } else if (msg == 'removed') {
        dataStreamController.sink.add(dataMap);
      } else if (msg == 'ready') {
        // subs: array of strings (ids passed to 'sub' which have sent their initial batch of data)
        List subs = dataMap['subs'];
        if (subs != null) {
          subs.forEach((id) {
            SubscriptionCallback sub = subscriptions[id];
            if (sub != null && sub.onReady != null) {
              sub.onReady();
            }
            SubscriptionHandler handler = subscriptionHandlers[id];
            if (handler != null) {
              handler.readyStreamController.sink.add(true);
            }
          });
        }
      } else if (msg == 'addedBefore') {
      } else if (msg == 'movedBefore') {
      } else if (msg == 'result') {
        if (dataMap['id'] != null) {
          String id = dataMap['id'];
          Completer<dynamic> completer = methodCompleters[id];
          if (completer != null) {
            if (dataMap['error'] != null) {
              completer.completeError(dataMap['error']);
            } else {
              completer.complete(dataMap['result']);
            }
            methodCompleters.remove(id);
          } else {
            debugger('Unknow method completer!');
          }
        }
      } else if (msg == 'updated') {
        List methodIds = dataMap['methods'];
        debugger(methodIds.toString());
      }
    }
  }

  void _onDone() {
    _socket = null;
    if (_isTryToReconnect) {
      debugger('Disconnect due to websocket onDone');
      disconnect();
      debugger('ScheduleReconnect due to websocket onDone!');
      _scheduleReconnect();
    } else {
      disconnect();
    }
  }

  void _onError(dynamic error) {
    _socket = null;
    if (_isTryToReconnect) {
      debugger('Disconnect due to websocket onError');
      disconnect();
      debugger('ScheduleReconnect due to websocket onError!');
      _scheduleReconnect();
    } else {
      debugger('Disconnect due to websocket onError');
      disconnect();
    }
  }
}
