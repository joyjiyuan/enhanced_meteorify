import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:enhanced_meteorify/enhanced_meteorify.dart';
import 'package:enhanced_meteorify/src/utils/utils.dart';
import 'package:mongo_dart/mongo_dart.dart';
import 'package:rxdart/rxdart.dart';

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

  final BehaviorSubject<DDPConnectionStatus> _statusSubject = BehaviorSubject();
  Stream<DDPConnectionStatus> _statusStream;

  final BehaviorSubject<bool> _loginSubject = BehaviorSubject();
  Stream<bool> _loginStream;

  final BehaviorSubject<String> _userIdSubject = BehaviorSubject();
  Stream<String> _userIdStream;

  final BehaviorSubject<Map<String, dynamic>> _userSubject = BehaviorSubject();
  Stream<Map<String, dynamic>> _userStream;

  String _userId;
  String _token;
  DateTime _tokenExpires;
  bool _loggingIn = false;

  final Map<String, SubscriptionHandler> _subscriptions = {};

  /// Meteor.collections
  final Map<String, Map<String, dynamic>> _collections = {};
  final Map<String, BehaviorSubject<Map<String, dynamic>>> _collectionsSubject = {};
  Map<String, Stream<Map<String, dynamic>>> collections = {};

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
  Future<MeteorClientLoginResult> loginWithGoogle(
      String email, String userId, Object authHeaders,
      {int delayOnLoginErrorSecond = 0}) {
    final bool googleLoginPlugin = true;
    Completer<MeteorClientLoginResult> completer = Completer();

    _loggingIn = true;
    _loginSubject.add(_loggingIn);

    call('login', [
      {
        'email': email,
        'userId': userId,
        'authHeaders': authHeaders,
        'googleLoginPlugin': googleLoginPlugin
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

  ///Login or register a new user with the Facebook Login API
  ///
  /// [userId] the unique Facebook userId. Must be fetched from the Facebook Login API
  /// [token] the token from Facebook API Login for server side validation
  /// Returns the `loginToken` after logging in.
  Future<MeteorClientLoginResult> loginWithFacebook(String userId, String token,
      {int delayOnLoginErrorSecond = 0}) {
    final bool facebookLoginPlugin = true;
    Completer<MeteorClientLoginResult> completer = Completer();

    _loggingIn = true;
    _loginSubject.add(_loggingIn);

    call('login', [
      {
        'userId': userId,
        'token': token,
        'facebookLoginPlugin': facebookLoginPlugin
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

  ///Login or register a new user with the Apple Login API
  ///
  /// [userId] the unique Apple userId. Must be fetched from the Apple Login API
  /// [jwt] the jwt from Apple API Login to get user's e-mail. (result.credential.identityToken)
  /// [givenName] user's given name. Must be fetched from the Apple Login API
  /// [lastName] user's last name. Must be fetched from the Apple Login API
  /// Returns the `loginToken` after logging in.
  Future<MeteorClientLoginResult> loginWithApple(
      String userId, List<int> jwt, String givenName, String lastName,
      {int delayOnLoginErrorSecond = 0}) {
    final bool appleLoginPlugin = true;
    Completer<MeteorClientLoginResult> completer = Completer();

    _loggingIn = true;
    _loginSubject.add(_loggingIn);

    var token = Utils.parseJwt(utf8.decode(jwt));
    call('login', [
      {
        'userId': userId,
        'email': token['email'],
        'givenName': givenName,
        'lastName': lastName,
        'appleLoginPlugin': appleLoginPlugin
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

  /// Login using a [loginToken].
  ///
  /// Returns the `loginToken` after logging in.
  Future<MeteorClientLoginResult> loginWithToken(
      {String token, DateTime tokenExpires}) {
    _token = token;
    if (tokenExpires == null) {
      _tokenExpires = DateTime.now().add(Duration(hours: 1));
    } else {
      _tokenExpires = tokenExpires;
    }
    return _loginWithExistingToken();
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

  /// Logs out the user.
  Future logout() {
    Completer completer = Completer();
    call('logout', []).then((result) {
      _userId = null;
      _token = null;
      _tokenExpires = null;
      _loggingIn = false;
      _loginSubject.add(_loggingIn);
      _userIdSubject.add(_userId);
      completer.complete();
    }).catchError((error) {
      _userId = null;
      _token = null;
      _tokenExpires = null;
      _loggingIn = false;
      _loginSubject.add(_loggingIn);
      _userIdSubject.add(_userId);
      connection.disconnect();
      Future.delayed(Duration(seconds: 2), () {
        connection.reconnect();
      });
      completer.completeError(error);
    });
    return completer.future;
  }

  /*
   * Methods associated with connection to MongoDB
   */

  /// Returns connection to a Meteor database using [dbUrl].
  ///
  /// You need to manually open the connection using `db.open()` after getting the connection.
  static Db getCustomDatabase(String dbUrl) {
    return Db(dbUrl);
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

/*
 *  Methods related to meteor ddp calls
 */

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

  // ===========================================================
  // Passwords

  /// Change the current user's password. Must be logged in.
  Future<dynamic> changePassword(String oldPassword, String newPassword) {
    return call('changePassword', [oldPassword, newPassword]);
  }

  /// Request a forgot password email.
  ///
  /// [email]
  /// The email address to send a password reset link.
  Future<dynamic> forgotPassword(String email) {
    return call('forgotPassword', [
      {'email': email}
    ]);
  }

  /// Reset the password for a user using a token received in email. Logs the user in afterwards.
  ///
  /// [token]
  /// The token retrieved from the reset password URL.
  ///
  /// [newPassword]
  /// A new password for the user. This is not sent in plain text over the wire.
  Future<dynamic> resetPassword(String token, String newPassword) {
    return call('resetPassword', [token, newPassword]);
  }
}
