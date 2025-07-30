import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:privastead_flutter/constants.dart';
import 'package:privastead_flutter/keys.dart';
import 'package:privastead_flutter/src/rust/api.dart';
import 'package:privastead_flutter/utilities/http_entities.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'result.dart';
import 'logger.dart';

// Entity used to return from download()
class DownloadResult {
  final File? file;
  final Uint8List? data;

  DownloadResult({this.file, this.data});
}

class _SilentException implements Exception {
  final String message;
  _SilentException(this.message);
  @override
  String toString() => message;
}

class HttpClientService {
  HttpClientService._();
  static final HttpClientService instance = HttpClientService._();

  /// bulk check the list of camera names against the server to check for updates
  /// returns list of corresponding cameras that have available videos for download
  Future<Result<List<String>>> bulkCheckAvailableCameras() => _wrap(() async {
    final pref = await SharedPreferences.getInstance();
    if (!pref.containsKey(PrefKeys.cameraSet)) {
      return [];
    }

    final cameraNames = pref.getStringList(PrefKeys.cameraSet)!;
    if (cameraNames.isEmpty) {
      return [];
    }

    final creds = await _getValidatedCredentials();

    var associatedNameToGroup = {};
    List<MotionPair> convertedCameraList = [];
    for (final cameraName in cameraNames) {
      final motionGroup = await _groupName(cameraName, Group.motion);
      if (motionGroup == "Error") {
        continue;
      }

      final SharedPreferencesAsync sharedPreferencesAsync =
          SharedPreferencesAsync();
      final int epoch =
          (await sharedPreferencesAsync.getInt("epoch$cameraName")) ?? 2;

      convertedCameraList.add(MotionPair(motionGroup, epoch));
      associatedNameToGroup[motionGroup] = cameraName;
    }
    Log.d("Association map: $associatedNameToGroup");

    var jsonContent = jsonEncode(MotionPairs(convertedCameraList));
    Log.d("JSON content: $jsonContent");
    final url = _buildUrl(creds.serverIp, ['bulkCheck']);
    final headers = await _basicAuthHeaders(
      creds.username,
      creds.password,
      jsonContent: true,
    );

    // Bulk check fetch action
    final response = await http.post(url, headers: headers, body: jsonContent);
    final responseBody =
        response
            .body; // Format is comma separated strings representing the associated motion groups
    Log.d("Server response: $responseBody");

    final List<String> listBody = responseBody.split(",");
    final List<String> convertedToGroups = [];
    if (responseBody.isNotEmpty) {
      for (final groupName in listBody) {
        if (groupName.isNotEmpty) {
          Log.d("Iterating $groupName");
          convertedToGroups.add(associatedNameToGroup[groupName]);
        }
      }
    }
    Log.d("Response from function: $convertedToGroups");

    return convertedToGroups;
  });

  /// POST /pair — waits for camera to join pairing
  Future<Result<String>> waitForPairingStatus({
    required String pairingToken,
  }) => _wrap(() async {
    final url = _buildUrl((await _getValidatedCredentials()).serverIp, [
      'pair',
    ]);
    final headers = await _basicAuthHeaders(
      (await _getValidatedCredentials()).username,
      (await _getValidatedCredentials()).password,
      jsonContent: true,
    );

    final request = PairingRequest(pairingToken, 'phone');
    final body = jsonEncode(request);

    Log.d("Pairing body: $body");

    final response = await http.post(url, headers: headers, body: body);

    Log.d("Response code: ${response.statusCode}");

    if (response.statusCode != 200) {
      throw Exception(
        'Failed to check pairing status: ${response.statusCode} ${response.reasonPhrase}',
      );
    }

    final decoded = jsonDecode(response.body);
    Log.d("Pairing response: $decoded");
    final status = decoded['status'] as String?;
    if (status == null) throw Exception('Missing status in response');

    return status;
  });

  Future<void> uploadSettings(
    String cameraName,
    ClientSettingsMessage message,
  ) => _wrap(() async {
    final creds = await _getValidatedCredentials();
    final configGroup = await _groupName(cameraName, Group.config);

    var jsonContent = jsonEncode(message);
    var encodedContent = utf8.encode(jsonContent);
    var encryptedMessage = await encryptSettingsMessage(
      cameraName: cameraName,
      data: encodedContent,
    );
    final url = _buildUrl(creds.serverIp, [configGroup, 'app']);
    final headers = await _basicAuthHeaders(creds.username, creds.password);

    return await http.post(url, headers: headers, body: encryptedMessage);
  });

  /// Downloads file and saves as [fileName]
  Future<Result<DownloadResult>> download({
    String? destinationFile,
    required String cameraName,
    required String type, // As dictated in constants.dart
    required String serverFile, // This is epoch in motion
  }) => _wrap(() async {
    final creds = await _getValidatedCredentials();
    final group = await _groupName(cameraName, type);
    Log.d(
      "Camera Name: $cameraName, Group Type: $type, Group: $group, Server File: $serverFile",
    );
    final url = _buildUrl(creds.serverIp, [group, serverFile]);
    final headers = await _basicAuthHeaders(creds.username, creds.password);

    // Video download action
    final response = await http.get(url, headers: headers);
    if (response.statusCode != 200) {
      if (response.statusCode == 404) {
        throw _SilentException(
          'Failed to download file: ${response.statusCode} ${response.reasonPhrase}',
        );
      } else {
        throw Exception(
          'Failed to download file: ${response.statusCode} ${response.reasonPhrase}',
        );
      }      
    }

    File? file;
    if (destinationFile != null) {
      final dir = await _ensureCameraDir(cameraName);
      file = File('${dir.path}/$destinationFile');
      if (await file.exists()) {
        Log.d("File name $destinationFile existed already");
        await file.delete();
      }
      await file.writeAsBytes(response.bodyBytes);
    }

    Log.d("Success downloading $serverFile for camera $cameraName");
    if (destinationFile == null) {
      return DownloadResult(
        data: response.bodyBytes,
      );
    } else {
      return DownloadResult(file: file);
    }
  });

  /// Deletes file at URL
  Future<Result<void>> delete({
    String? destinationFile,
    required String cameraName,
    required String type, // As dictated in constants.dart
    required String serverFile, // This is epoch in motion
  }) => _wrap(() async {
    final creds = await _getValidatedCredentials();
    final group = await _groupName(cameraName, type);
    Log.d(
      "Camera Name: $cameraName, Group Type: $type, Group: $group, Server File: $serverFile",
    );
    final url = _buildUrl(creds.serverIp, [group, serverFile]);
    final headers = await _basicAuthHeaders(creds.username, creds.password);

    // Delete action TODO: Should we retry if fail?
    final delResponse = await http.delete(url, headers: headers);
    if (delResponse.statusCode != 200) {
      if (delResponse.statusCode == 404) {
        throw _SilentException(
          'Failed to delete video from server: ${delResponse.statusCode} ${delResponse.reasonPhrase}',
        );
      } else {
        throw Exception(
          'Failed to delete video from server: ${delResponse.statusCode} ${delResponse.reasonPhrase}',
        );
      }
    }
    Log.d("Successfully deleted $serverFile from server");
  });

  /// POST /fcm_token
  Future<Result<void>> uploadFcmToken(String token) => _wrap(() async {
    final creds = await _getValidatedCredentials();

    final url = _buildUrl(creds.serverIp, ['fcm_token']);
    final headers = await _basicAuthHeaders(creds.username, creds.password);

    final response = await http.post(url, headers: headers, body: token);

    if (response.statusCode != 200) {
      throw Exception(
        'Failed to send data: ${response.statusCode} ${response.reasonPhrase}',
      );
    } else {
      Log.d("Successfully sent data");
    }
  });

  /// POST /livestream/<group>
  Future<Result<void>> livestreamStart(String cameraName) => _wrap(() async {
    final creds = await _getValidatedCredentials();

    final group = await _groupName(cameraName, Group.livestream);
    final url = _buildUrl(creds.serverIp, ['livestream', group]);
    final headers = await _basicAuthHeaders(creds.username, creds.password);

    final response = await http.post(url, headers: headers);
    if (response.statusCode != 200) {
      throw Exception(
        'Failed to send data: ${response.statusCode} ${response.reasonPhrase}',
      );
    }
  });

  /// GET /livestream/<group>/<chunkNumber> then deletes the file
  /// using /<group>/<chunkNumber>
  Future<Result<Uint8List>> livestreamRetrieve({
    required String cameraName,
    required int chunkNumber,
  }) => _wrap(() async {
    final creds = await _getValidatedCredentials();

    final group = await _groupName(cameraName, Group.livestream);
    final url = _buildUrl(creds.serverIp, ['livestream', group, chunkNumber]);
    final headers = await _basicAuthHeaders(creds.username, creds.password);

    final response = await http.get(url, headers: headers);
    if (response.statusCode != 200) {
      throw Exception(
        'Failed to fetch data: ${response.statusCode} ${response.reasonPhrase}',
      );
    }

    // Delete action
    final delUrl = _buildUrl(creds.serverIp, [group, chunkNumber]);
    final delResponse = await http.delete(delUrl, headers: headers);
    if (delResponse.statusCode != 200) {
      throw Exception(
        'Failed to delete video from server: ${delResponse.statusCode} ${delResponse.reasonPhrase}',
      );
    }

    return response.bodyBytes;
  });

  /// POST /livestream_end/<group>
  Future<Result<void>> livestreamEnd(String cameraName) => _wrap(() async {
    final creds = await _getValidatedCredentials();
    final group = await _groupName(cameraName, Group.livestream);
    final url = _buildUrl(creds.serverIp, ['livestream_end', group]);
    final headers = await _basicAuthHeaders(creds.username, creds.password);

    final response = await http.post(url, headers: headers);
    if (response.statusCode != 200) {
      throw Exception(
        'Failed to send data: ${response.statusCode} ${response.reasonPhrase}',
      );
    }
  });

  /// POST /config/<group>
  Future<Result<void>> configCommand({required String cameraName, required Object command}) => _wrap(() async {
    final creds = await _getValidatedCredentials();
    final group = await _groupName(cameraName, Group.config);
    final url = _buildUrl(creds.serverIp, ['config', group]);
    final headers = await _basicAuthHeaders(creds.username, creds.password);

    final response = await http.post(url, headers: headers, body: command);

    if (response.statusCode != 200) {
      throw Exception(
        'Failed to send config command: ${response.statusCode} ${response.reasonPhrase}',
      );
    } else {
      Log.d("Successfully sent config command");
    }
  });

  /// GET /config_response/<group>
  Future<Result<Uint8List>> fetchConfigResponse({
    required String cameraName,
  }) => _wrap(() async {
    final creds = await _getValidatedCredentials();

    final group = await _groupName(cameraName, Group.config);
    final url = _buildUrl(creds.serverIp, ['config_response', group]);
    final headers = await _basicAuthHeaders(creds.username, creds.password);

    final response = await http.get(url, headers: headers);
    if (response.statusCode != 200) {
      if (response.statusCode == 404) {
        throw _SilentException(
          'Failed to fetch config response: ${response.statusCode} ${response.reasonPhrase}',
        );
      } else {
        throw Exception(
          'Failed to fetch config response: ${response.statusCode} ${response.reasonPhrase}',
        );
      }
    } else {
      Log.d("Successfully fetched config response");
    }

    return response.bodyBytes;
  });

  /// Utility methods below

  Future<Result<T>> _wrap<T>(Future<T> Function() block) async {
    try {
      return Result.success(await block());
    } catch (e, st) {
      if (e is _SilentException) {
        Log.d("HttpClientService error: $e");
      } else {
        Log.e("HttpClientService error: $e\n$st");
      }
      return Result.failure(Exception(e.toString()));
    }
  }

  Future<String?> _pref(String key) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(key);
  }

  Uri _buildUrl(String serverIp, List<dynamic> segments) {
    final path = segments.join('/');
    return Uri.parse('http://$serverIp:8080/$path');
  }

  Future<Map<String, String>> _basicAuthHeaders(
    String username,
    String password, {
    bool jsonContent = false,
  }) async {
    final credentials = base64Encode(utf8.encode('$username:$password'));
    if (jsonContent) {
      return {
        HttpHeaders.authorizationHeader: 'Basic $credentials',
        HttpHeaders.contentTypeHeader: 'application/json',
      };
    } else {
      return {HttpHeaders.authorizationHeader: 'Basic $credentials'};
    }
  }

  Future<Directory> _ensureCameraDir(String cameraName) async {
    final base = await getApplicationDocumentsDirectory();
    final dir = Directory('${base.path}/camera_dir_$cameraName');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  Future<({String serverIp, String username, String password})>
  _getValidatedCredentials() async {
    final serverIp = await _pref(PrefKeys.savedIp);
    final username = await _pref(PrefKeys.serverUsername);
    final password = await _pref(PrefKeys.serverPassword);

    if ([serverIp, username, password].contains(null)) {
      throw Exception('Missing server credentials');
    }

    return (serverIp: serverIp!, username: username!, password: password!);
  }

  Future<String> _groupName(String cameraName, String clientTag) async {
    final String groupName = await getGroupName(
      clientTag: clientTag,
      cameraName: cameraName,
    );
    if (groupName == "Error") {
      throw Exception('Incorrect clientTag or invalid camera');
    }

    return groupName;
  }
}
