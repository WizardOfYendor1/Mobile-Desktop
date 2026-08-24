import 'package:flutter_test/flutter_test.dart';
import 'package:jellyfin_preference/jellyfin_preference.dart';
import 'package:moonfin/data/services/log_service.dart';
import 'package:moonfin/data/services/media_server_client_factory.dart';
import 'package:moonfin/preference/user_preferences.dart';
import 'package:server_core/server_core.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeClientFactory extends Fake implements MediaServerClientFactory {}

const _device = DeviceInfo(
  id: 'dev-1',
  name: 'Test Device',
  appName: 'Moonfin',
  appVersion: '0.0.0',
);

Future<LogService> _service({bool loggingEnabled = false}) async {
  SharedPreferences.setMockInitialValues(<String, Object>{
    if (loggingEnabled) 'pref_diagnostic_logging_enabled': true,
  });
  final store = PreferenceStore();
  await store.init();
  return LogService(UserPreferences(store), _FakeClientFactory(), _device);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a crash is recorded even while diagnostic logging is off', () async {
    final logs = await _service();

    logs.log(LogCategory.general, 'routine chatter');
    expect(logs.entryCount, 0, reason: 'ordinary logging stays gated');

    logs.logCrash('Uncaught: boom', 'boom\n#0 main (main.dart:1)');
    expect(logs.entryCount, 1);
    expect(logs.entries.single.level, LogLevel.error);
  });

  test('crash entries are redacted like everything else', () async {
    final logs = await _service();

    logs.logCrash(
      'Uncaught: bad response',
      'DioException for https://myserver.example:8096/Items',
    );

    final text = logs.exportText();
    expect(text, isNot(contains('myserver.example')));
    expect(text, contains('https://[REDACTED]'));
  });

  test('exportText can be bounded to the newest entries', () async {
    final logs = await _service(loggingEnabled: true);
    for (var i = 0; i < 10; i++) {
      logs.log(LogCategory.general, 'entry $i');
    }

    final text = logs.exportText(maxEntries: 3);
    expect(text, contains('entry 9'));
    expect(text, contains('entry 7'));
    expect(text, isNot(contains('entry 6')));
    expect(text, contains('Entries: 3'));
  });
}
