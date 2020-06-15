import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:ddp/ddp.dart';
import 'package:enhanced_meteorify/enhanced_meteorify.dart';
import 'package:enhanced_meteorify/src/utils/utils.dart';
import 'package:mongo_dart/mongo_dart.dart';
import 'package:rxdart/rxdart.dart';
import 'subscribed_collection.dart';

/// An enum for describing the [ConnectionStatus].
enum ConnectionStatus { CONNECTED, DISCONNECTED }

/// A listener for the current connection status.
typedef MeteorConnectionListener = void Function(
    ConnectionStatus connectionStatus);

class MeteorClientLoginResult {
  String userId;
  String token;
  DateTime tokenExpires;
  MeteorClientLoginResult({this.userId, this.token, this.tokenExpires});
}

class MeteorError extends Error {
  String details;
  int error;
  String errorType;
  bool isClientSafe;
  String message;
  String reason;
  String stack;

  MeteorError.parse(Map<String, dynamic> object) {
    try {
      details = object['details']?.toString();
      error = object['error'] is String
          ? int.parse(object['error'])
          : object['error'];
      errorType = object['errorType']?.toString();
      isClientSafe = object['isClientSafe'] == true;
      message = object['message']?.toString();
      reason = object['reason']?.toString();
      stack = object['stack']?.toString();
    } catch (_) {}
  }

  @override
  String toString() {
    return '''
isClientSafe: $isClientSafe
errorType: $errorType
error: $error
details: $details
message: $message
reason: $reason
stack: $stack
''';
  }
}

/// Provides useful methods for interacting with the Meteor server.
///
/// Provided methods use the same syntax as of the [Meteor] class used by the Meteor framework.
class Meteor {
  DDP connection;

  BehaviorSubject<DDPConnectionStatus> _statusSubject = BehaviorSubject();
  Stream<DDPConnectionStatus> _statusStream;

  BehaviorSubject<bool> _loginSubject = BehaviorSubject();
  Stream<bool> _loginStream;

  BehaviorSubject<String> _userIdSubject = BehaviorSubject();
  Stream<String> _userIdStream;

  BehaviorSubject<Map<String, dynamic>> _userSubject = BehaviorSubject();
  Stream<Map<String, dynamic>> _userStream;

  String _userId;
  String _token;
  DateTime _tokenExpires;
  bool _loggingIn = false;

  Map<String, SubscriptionHandler> _subscriptions = {};

  /// Meteor.collections
  Map<String, Map<String, dynamic>> _collections = {};
  Map<String, BehaviorSubject<Map<String, dynamic>>> _collectionsSubject = {};
  Map<String, Stream<Map<String, dynamic>>> collections = {};

  /// The client used to interact with DDP framework.
  static DdpClient _client;

  /// Get the [_client].
  static DdpClient get client => _client;

  /// A listener for the connection status.
  static MeteorConnectionListener _connectionListener;

  /// Set the [_connectionListener]
  static set connectionListener(MeteorConnectionListener listener) =>
      _connectionListener = listener;

  /// Connection url of the Meteor server.
  static String _connectionUrl;

  /// A boolean to check the connection status.
  static bool isConnected = false;

  /// The [_currentUserId] of the logged in user.
  static String _currentUserId;

  /// Get the [_currentUserId].
  static String get currentUserId => _currentUserId;

  /// The status listener used to listen for connection status updates.
  static StatusListener _statusListener;

  /// The session token used to store the currently logged in user's login token.
  static String _sessionToken;

  static Db db;

  static int mongoDbPort;

  Meteor.connect({String url}) {
    url = url.replaceFirst(RegExp(r'^http'), 'ws');
    if (!url.endsWith('websocket')) {
      url = url.replaceFirst(RegExp(r'/$'), 'to') + '/websocket';
    }
    print('connecting to $url');
    connection = DDP(url: url);

    connection.status().listen((status) {
      _statusSubject.add(status);
    })
      ..onError((dynamic error) {
        _statusSubject.addError(error);
      })
      ..onDone(() {
        _statusSubject.close();
      });
    _statusStream = _statusSubject.stream;

    _loginStream = _loginSubject.stream;
    _userIdStream = _userIdSubject.stream;
    _userStream = _userSubject.stream;

    createCollection('users');

    connection.dataStreamController.stream.listen((data) {
      String collection = data['collection'];
      String id = data['id'];
      dynamic fields = data['fields'];

      if (fields != null) {
        fields['_id'] = id;
      }

      if (_collections[collection] == null) {
        _collections[collection] = {};
        _collectionsSubject[collection] =
            BehaviorSubject<Map<String, dynamic>>();
        collections[collection] = _collectionsSubject[collection].stream;
      }

      if (data['msg'] == 'removed') {
        _collections[collection].remove(id);
      } else if (data['msg'] == 'added') {
        if (fields != null) {
          _collections[collection][id] = fields;
        }
      } else if (data['msg'] == 'changed') {
        if (fields != null) {
          fields.forEach((k, v) {
            if (_collections[collection][id] != null &&
                _collections[collection][id] is Map) {
              _collections[collection][id][k] = v;
            }
          });
        } else if (data['cleared'] != null && data['cleared'] is List) {
          List<dynamic> clearList = data['cleared'];
          if (_collections[collection][id] != null &&
              _collections[collection][id] is Map) {
            clearList.forEach((k) {
              _collections[collection][id].remove(k);
            });
          }
        }
      }

      _collectionsSubject[collection].add(_collections[collection]);
      if (collection == 'users' && id == _userId) {
        _userSubject.add(_collections['users'][_userId]);
      }
    })
      ..onError((dynamic error) {})
      ..onDone(() {});

    connection.onReconnect((OnReconnectionCallback reconnectionCallback) {
      print('reconnecting');
      _loginWithExistingToken().catchError((error) {});
    });

    userId().listen((userId) {
      _userSubject.add(_collections['users'][userId]);
    });
  }

  void createCollection(String collection) {
    if (_collections[collection] == null) {
      _collections[collection] = {};
      var subject = _collectionsSubject[collection] =
          BehaviorSubject<Map<String, dynamic>>();
      collections[collection] = subject.stream;
    }
  }

  Stream<Map<String, dynamic>> user() {
    return _userStream;
  }

  Map<String, dynamic> userCurrentValue() {
    return _userSubject.value;
  }

  /// Get the current user id, or null if no user is logged in. A reactive data source.
  Stream<String> userId() {
    return _userIdStream;
  }

  String userIdCurrentValue() {
    return _userIdSubject.value;
  }

  /// A Map containing user documents.
  Stream<Map<String, dynamic>> get users => collections['users'];

  /// True if a login method (such as Meteor.loginWithPassword, Meteor.loginWithFacebook, or Accounts.createUser) is currently in progress.
  /// A reactive data source.
  Stream<bool> loggingIn() {
    return _loginStream;
  }

/*
 * Methods associated with authentication
 */

  /// Returns `true` if user is logged in.
  static bool isLoggedIn() {
    return _currentUserId != null;
  }

  Future<MeteorClientLoginResult> loginWithPassword(
      String user, String password,
      {int delayOnLoginErrorSecond = 0}) {
    Completer<MeteorClientLoginResult> completer = Completer();
    _loggingIn = true;
    _loginSubject.add(_loggingIn);

    var selector;
    if (!user.contains('@')) {
      selector = {'username': user};
    } else {
      selector = {'email': user};
    }

    call('login', [
      {
        'user': selector,
        'password': {
          'digest': sha256.convert(utf8.encode(password)).toString(),
          'algorithm': 'sha-256'
        },
      }
    ]).then((result) {
      _userId = result['id'];
      _token = result['token'];
      _tokenExpires =
          DateTime.fromMillisecondsSinceEpoch(result['tokenExpires']['\$date']);
      _loggingIn = false;
      _loginSubject.add(_loggingIn);
      _userIdSubject.add(_userId);
      completer.complete(MeteorClientLoginResult(
        userId: _userId,
        token: _token,
        tokenExpires: _tokenExpires,
      ));
    }).catchError((error) {
      Future.delayed(Duration(seconds: delayOnLoginErrorSecond), () {
        _userId = null;
        _token = null;
        _tokenExpires = null;
        _loggingIn = false;
        _loginSubject.add(_loggingIn);
        _userIdSubject.add(_userId);
        completer.completeError(error);
      });
    });
    return completer.future;
  }

  /// Login or register a new user with de Google oAuth API
  ///
  /// [email] the email to register with. Must be fetched from the Google oAuth API
  /// [userId] the unique Google userId. Must be fetched from the Google oAuth API
  /// [authHeaders] the authHeaders from Google oAuth API for server side validation
  /// Returns the `loginToken` after logging in.
  static Future<String> loginWithGoogle(
      String email, String userId, Object authHeaders) async {
    final bool googleLoginPlugin = true;
    Completer completer = Completer<String>();
    if (isConnected) {
      var result = await _client.call('login', [
        {
          'email': email,
          'userId': userId,
          'authHeaders': authHeaders,
          'googleLoginPlugin': googleLoginPlugin
        }
      ]);
      print(result.reply);
      _notifyLoginResult(result, completer);
      return completer.future;
    }
    completer.completeError('Not connected to server');
    return completer.future;
  }

  ///Login or register a new user with the Facebook Login API
  ///
  /// [userId] the unique Facebook userId. Must be fetched from the Facebook Login API
  /// [token] the token from Facebook API Login for server side validation
  /// Returns the `loginToken` after logging in.
  static Future<String> loginWithFacebook(String userId, String token) async {
    final bool facebookLoginPlugin = true;
    Completer completer = Completer<String>();
    if (isConnected) {
      var result = await _client.call('login', [
        {
          'userId': userId,
          'token': token,
          'facebookLoginPlugin': facebookLoginPlugin
        }
      ]);
      print(result.reply);
      _notifyLoginResult(result, completer);
      return completer.future;
    }
    completer.completeError('Not connected to server');
    return completer.future;
  }

  ///Login or register a new user with the Apple Login API
  ///
  /// [userId] the unique Apple userId. Must be fetched from the Apple Login API
  /// [jwt] the jwt from Apple API Login to get user's e-mail. (result.credential.identityToken)
  /// [givenName] user's given name. Must be fetched from the Apple Login API
  /// [lastName] user's last name. Must be fetched from the Apple Login API
  /// Returns the `loginToken` after logging in.
  static Future<String> loginWithApple(
      String userId, List<int> jwt, String givenName, String lastName) async {
    final bool appleLoginPlugin = true;
    Completer completer = Completer<String>();
    if (isConnected) {
      var token = Utils.parseJwt(utf8.decode(jwt));
      var result = await _client.call('login', [
        {
          'userId': userId,
          'email': token['email'],
          'givenName': givenName,
          'lastName': lastName,
          'appleLoginPlugin': appleLoginPlugin
        }
      ]);
      print(result.reply);
      _notifyLoginResult(result, completer);
      return completer.future;
    }
    completer.completeError('Not connected to server');
    return completer.future;
  }

  /// Login using a [loginToken].
  ///
  /// Returns the `loginToken` after logging in.
  static Future<String> loginWithToken(String loginToken) async {
    Completer completer = Completer<String>();
    if (isConnected) {
      var result = await _client.call('login', [
        {'resume': loginToken}
      ]);
      print(result.reply);
      _notifyLoginResult(result, completer);
      return completer.future;
    }
    completer.completeError('Not connected to server');
    return completer.future;
  }

  Future<MeteorClientLoginResult> _loginWithExistingToken() {
    Completer<MeteorClientLoginResult> completer = Completer();
    print('Trying to login with existing token...');
    print('Token is ${_token}');
    if (_tokenExpires != null) {
      print('Token expires ${_tokenExpires.toString()}');
      print('now is ${DateTime.now()}');
      print(
          'Token expires is after now ${_tokenExpires.isAfter(DateTime.now())}');
    }

    if (_token != null &&
        _tokenExpires != null &&
        _tokenExpires.isAfter(DateTime.now())) {
      _loggingIn = true;
      _loginSubject.add(_loggingIn);
      call('login', [
        {'resume': _token}
      ]).then((result) {
        _userId = result['id'];
        _token = result['token'];
        _tokenExpires = DateTime.fromMillisecondsSinceEpoch(
            result['tokenExpires']['\$date']);
        _loggingIn = false;
        _loginSubject.add(_loggingIn);
        _userIdSubject.add(_userId);
        completer.complete(MeteorClientLoginResult(
          userId: _userId,
          token: _token,
          tokenExpires: _tokenExpires,
        ));
      }).catchError((error) {
        _userId = null;
        _token = null;
        _tokenExpires = null;
        _loggingIn = false;
        _loginSubject.add(_loggingIn);
        _userIdSubject.add(_userId);
        completer.completeError(error);
      });
    } else {
      completer.complete(null);
    }
    return completer.future;
  }

  /// Used internally to notify the future about success/failure of login process.
  static void _notifyLoginResult(Call result, Completer completer) {
    String userId = result.reply['id'];
    String token = result.reply['token'];
    if (userId != null) {
      _currentUserId = userId;
      print('Logged in user $_currentUserId');
      if (completer != null) {
        _sessionToken = token;
        completer.complete(token);
      }
    } else {
      _notifyError(completer, result);
    }
  }

  /// Logs out the user.
  static void logout() async {
    if (isConnected) {
      var result = await _client.call('logout', []);
      _sessionToken = null;
      print(result.reply);
    }
  }

  /// Used internally to notify a future about the error returned from a ddp call.
  static void _notifyError(Completer completer, Call result) {
    completer.completeError(result.reply['reason']);
  }

  /*
   * Methods associated with connection to MongoDB
   */

  /// Returns the default Meteor database after opening a connection.
  ///
  /// This database can be accessed using the [Db] class.
  static Future<Db> getMeteorDatabase() async {
    Completer<Db> completer = Completer<Db>();
    if (db == null) {
      final uri = Uri.parse(_connectionUrl);
      String dbUrl = 'mongodb://${uri.host}:$mongoDbPort/meteor';
      print('Connecting to $dbUrl');
      db = Db(dbUrl);
      await db.open();
    }
    completer.complete(db);
    return completer.future;
  }

  /// Returns connection to a Meteor database using [dbUrl].
  ///
  /// You need to manually open the connection using `db.open()` after getting the connection.
  static Db getCustomDatabase(String dbUrl) {
    return Db(dbUrl);
  }

/*
 * Methods associated with current user
 */

  /// Returns the logged in user object as a map of properties.
  static Future<Map<String, dynamic>> userAsMap() async {
    Completer completer = Completer<Map<String, dynamic>>();
    Db db = await getMeteorDatabase();
    print(db);
    var user = await db.collection('users').findOne({'_id': _currentUserId});
    print(_currentUserId);
    print(user);
    completer.complete(user);
    return completer.future;
  }

/*
 * Methods associated with subscriptions
 */

  SubscriptionHandler subscribe(String name, List<dynamic> params,
      {Function onStop(dynamic error), Function onReady}) {
    SubscriptionHandler handler =
        connection.subscribe(name, params, onStop: onStop, onReady: onReady);
    if (_subscriptions[name] != null) {
      _subscriptions[name].stop();
    }
    _subscriptions[name] = handler;
    return handler;
  }

  /// Unsubscribe from a subscription using the [subscriptionId] returned by [subscribe].
  static Future<String> unsubscribe(String subscriptionId) async {
    Completer<String> completer = Completer<String>();
    Call result = await _client.unSub(subscriptionId);
    completer.complete(result.id);
    return completer.future;
  }

/*
 * Methods related to collections
 */

  /// Returns a [SubscribedCollection] using the [collectionName].
  ///
  /// [SubscribedCollection] supports only read operations.
  /// For more supported operations use the methods of the [Db] class from `mongo_dart` library.
  static Future<SubscribedCollection> collection(String collectionName) {
    Completer<SubscribedCollection> completer =
        Completer<SubscribedCollection>();
    Collection collection = _client.collectionByName(collectionName);
    completer.complete(SubscribedCollection(collection, collectionName));
    return completer.future;
  }

/*
 *  Methods related to meteor ddp calls
 */

  /// Makes a call to a service method exported from Meteor using the [methodName] and list of [arguments].
  ///
  /// Returns the value returned by the service method or an error using a [Future].
  // static Future<dynamic> call(
  //     String methodName, List<dynamic> arguments) async {
  //   Completer<dynamic> completer = Completer<dynamic>();
  //   var result = await _client.call(methodName, arguments);
  //   if (result.error != null) {
  //     completer.completeError(result.error);
  //   } else {
  //     completer.complete(result.reply);
  //   }
  //   return completer.future;
  // }

  /// Invoke a method passing an array of arguments.
  ///
  /// `name` Name of method to invoke
  ///
  /// `args` List of method arguments
  Future<dynamic> call(String name, List<dynamic> args) async {
    try {
      return await connection.call(name, args);
    } catch (e) {
      throw MeteorError.parse(e);
    }
  }

  /// Invoke a method passing an array of arguments.
  ///
  /// `name` Name of method to invoke
  ///
  /// `args` List of method arguments
  Future<dynamic> apply(String name, List<dynamic> args) async {
    try {
      return await connection.apply(name, args);
    } catch (e) {
      throw MeteorError.parse(e);
    }
  }

  Stream<DDPConnectionStatus> status() {
    return _statusStream;
  }

  /// Force an immediate reconnection attempt if the client is not connected to the server.
  /// This method does nothing if the client is already connected.
  void reconnect() {
    connection.reconnect();
  }

  /// Disconnect the client from the server.
  void disconnect() {
    connection.disconnect();
  }
}
