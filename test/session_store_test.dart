import 'package:flutter_test/flutter_test.dart';
import 'package:watbal/auth.dart';

/// In-memory [SessionValueStore] for exercising [SessionStore] without any
/// platform channels. Tracks call counts so tests can assert *where* the
/// cookie header did and didn't get written — the crux of the security fix.
class FakeValueStore implements SessionValueStore {
  FakeValueStore([this.value]);

  String? value;
  int reads = 0;
  int writes = 0;
  int deletes = 0;

  @override
  Future<String?> read() async {
    reads++;
    return value;
  }

  @override
  Future<void> write(String v) async {
    writes++;
    value = v;
  }

  @override
  Future<void> delete() async {
    deletes++;
    value = null;
  }
}

void main() {
  const header =
      '.ASPXAUTH=abc; ASP.NET_OneWebLang=en; ROUTEID=.1; '
      '__RequestVerificationToken=tok';

  group('SessionStore.save', () {
    test('writes to secure store and scrubs any legacy plaintext copy', () async {
      final secure = FakeValueStore();
      final legacy = FakeValueStore('stale-plaintext');
      final store = SessionStore(secure: secure, legacy: legacy);

      await store.save(header);

      expect(secure.value, header, reason: 'secret must land in secure store');
      expect(legacy.deletes, greaterThan(0),
          reason: 'plaintext copy must be scrubbed');
      expect(legacy.value, isNull);
    });

    test('mirrors to the app group when a mirror is provided (iOS)', () async {
      final secure = FakeValueStore();
      final legacy = FakeValueStore();
      final mirror = FakeValueStore();
      final store =
          SessionStore(secure: secure, legacy: legacy, mirror: mirror);

      await store.save(header);

      expect(mirror.value, header,
          reason: 'iOS native refresher reads the app-group copy');
    });

    test('does not mirror when no mirror is provided (Android)', () async {
      final secure = FakeValueStore();
      final legacy = FakeValueStore();
      // No mirror: on Android nothing native reads the cookie, so it must not
      // be leaked into plaintext widget prefs.
      final store = SessionStore(secure: secure, legacy: legacy);

      await store.save(header);

      expect(secure.value, header);
    });
  });

  group('SessionStore.load', () {
    test('returns the secure value without touching legacy', () async {
      final secure = FakeValueStore(header);
      final legacy = FakeValueStore();
      final store = SessionStore(secure: secure, legacy: legacy);

      expect(await store.load(), header);
      expect(legacy.reads, 0, reason: 'no migration needed when secure is set');
    });

    test('migrates a legacy plaintext session into secure storage + scrubs',
        () async {
      final secure = FakeValueStore();
      final legacy = FakeValueStore('legacy-cookie-header');
      final mirror = FakeValueStore();
      final store =
          SessionStore(secure: secure, legacy: legacy, mirror: mirror);

      final result = await store.load();

      expect(result, 'legacy-cookie-header');
      expect(secure.value, 'legacy-cookie-header',
          reason: 'migrated into secure storage');
      expect(mirror.value, 'legacy-cookie-header',
          reason: 'iOS mirror repopulated on migration');
      expect(legacy.value, isNull, reason: 'plaintext scrubbed after migrate');
      expect(legacy.deletes, greaterThan(0));
    });

    test('returns null when neither store has a session', () async {
      final store =
          SessionStore(secure: FakeValueStore(), legacy: FakeValueStore());
      expect(await store.load(), isNull);
    });

    test('treats an empty secure value as "no session" and falls through',
        () async {
      final secure = FakeValueStore('');
      final legacy = FakeValueStore('legacy');
      final store = SessionStore(secure: secure, legacy: legacy);

      expect(await store.load(), 'legacy');
    });
  });

  group('SessionStore.clear', () {
    test('deletes from secure, mirror, and legacy stores', () async {
      final secure = FakeValueStore(header);
      final legacy = FakeValueStore('legacy');
      final mirror = FakeValueStore(header);
      final store =
          SessionStore(secure: secure, legacy: legacy, mirror: mirror);

      await store.clear();

      expect(secure.value, isNull);
      expect(mirror.value, isNull);
      expect(legacy.value, isNull);
    });
  });

  group('debugSetSessionStore wiring', () {
    test('top-level saveSession/loadSession/clearSession use the injected store',
        () async {
      final secure = FakeValueStore();
      final legacy = FakeValueStore();
      debugSetSessionStore(SessionStore(secure: secure, legacy: legacy));

      await saveSession(header);
      expect(secure.value, header);
      expect(await loadSession(), header);
    });
  });
}
