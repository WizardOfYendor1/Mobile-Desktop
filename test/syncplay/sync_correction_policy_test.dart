import 'package:flutter_test/flutter_test.dart';
import 'package:moonfin/syncplay/sync_correction_policy.dart';

const _defaultSettings = SyncCorrectionSettings(
  useSkipToSync: true,
  useSpeedToSync: true,
  minDelaySkipToSyncMs: 2000,
  minDelaySpeedToSyncMs: 100,
  maxDelaySpeedToSyncMs: 5000,
  speedToSyncDurationMs: 1000,
);

/// A client whose seeks take [seekLatencyMs] to render: after a skip the
/// position freezes for that long, then advances with the wall clock again.
class _FakeClient {
  final int seekLatencyMs;

  int nowMs = 0;
  int positionMs = 0;
  int stalledUntilMs = 0;
  int baselineMs = 0;

  _FakeClient({required this.seekLatencyMs});

  bool get isBuffering => nowMs < stalledUntilMs;
  bool get isPlaying => !isBuffering;

  int get driftMs => positionMs - nowMs;

  void advance(int ms) {
    final end = nowMs + ms;
    final resumedAt = stalledUntilMs > nowMs
        ? (stalledUntilMs < end ? stalledUntilMs : end)
        : nowMs;
    positionMs += end - resumedAt;
    nowMs = end;
  }

  void stall(int ms) => stalledUntilMs = nowMs + ms;

  void seekTo(int target) {
    positionMs = target;
    stalledUntilMs = nowMs + seekLatencyMs;
  }
}

/// Ticks at the manager's 2s cadence, applying decisions the way
/// `SyncPlayManager._performDriftCorrection` does.
List<SyncCorrectionDecision> _run(
  SyncCorrectionPolicy policy,
  _FakeClient client, {
  required int ticks,
  SyncCorrectionSettings settings = _defaultSettings,
}) {
  final decisions = <SyncCorrectionDecision>[];
  for (var i = 0; i < ticks; i++) {
    client.advance(2000);
    final decision = policy.evaluate(
      nowMs: client.nowMs,
      serverNowMs: client.nowMs,
      currentPositionMs: client.positionMs,
      lastSyncPositionMs: client.baselineMs,
      lastSyncTimeMs: 0,
      isBuffering: client.isBuffering,
      isPlaying: client.isPlaying,
      clockJitterMs: 0,
      settings: settings,
    );
    decisions.add(decision);
    if (decision.action == SyncCorrectionAction.skip) {
      client.seekTo(decision.targetPositionMs);
    } else if (decision.action == SyncCorrectionAction.rebaseline) {
      client.baselineMs += decision.measuredDelayMs;
    }
  }
  return decisions;
}

int _countOf(List<SyncCorrectionDecision> decisions, SyncCorrectionAction a) =>
    decisions.where((d) => d.action == a).length;

void main() {
  group('drift correction convergence', () {
    test(
      'a slow-seeking client converges instead of skipping forever',
      () {
        // Every corrective skip used to land short by its own seek latency, so
        // the next check skipped again, permanently.
        final client = _FakeClient(seekLatencyMs: 3000)..stall(4000);
        final policy = SyncCorrectionPolicy();

        final decisions = _run(policy, client, ticks: 200);

        expect(
          _countOf(decisions, SyncCorrectionAction.skip),
          lessThanOrEqualTo(2),
          reason: 'each skip must fold in the latency it just measured',
        );
        expect(policy.hasGivenUp, isFalse);
        expect(policy.seekLatencyAllowanceMs, 3000);
        expect(
          client.driftMs.abs(),
          lessThanOrEqualTo(SyncCorrectionPolicy.noiseFloorMs),
          reason: 'the client should end up in sync, not just stop skipping',
        );
        expect(
          decisions.last.action,
          SyncCorrectionAction.hold,
          reason: 'a converged client keeps measuring but stops correcting',
        );
      },
    );

    test('stops correcting when it cannot converge', () {
      // Seek latency past the allowance cap can never be compensated for.
      final client = _FakeClient(seekLatencyMs: 14000)..stall(4000);
      final policy = SyncCorrectionPolicy();

      final decisions = _run(policy, client, ticks: 400);

      expect(policy.hasGivenUp, isTrue);
      expect(
        _countOf(decisions, SyncCorrectionAction.skip),
        SyncCorrectionPolicy.maxConsecutiveSkips,
      );
      expect(decisions.last.action, SyncCorrectionAction.giveUp);
    });

    test('never corrects a client that is still buffering', () {
      final client = _FakeClient(seekLatencyMs: 500)..stall(60000);
      final policy = SyncCorrectionPolicy();

      final decisions = _run(policy, client, ticks: 20);

      expect(
        decisions.every((d) => d.action == SyncCorrectionAction.defer),
        isTrue,
      );
      expect(policy.consecutiveSkips, 0);
    });

    test('never corrects a paused client', () {
      final policy = SyncCorrectionPolicy();
      final decision = policy.evaluate(
        nowMs: 30000,
        serverNowMs: 30000,
        currentPositionMs: 0,
        lastSyncPositionMs: 0,
        lastSyncTimeMs: 0,
        isBuffering: false,
        isPlaying: false,
        clockJitterMs: 0,
        settings: _defaultSettings,
      );
      expect(decision.action, SyncCorrectionAction.defer);
    });

    test('holds off re-measuring until a skip has settled', () {
      final client = _FakeClient(seekLatencyMs: 3000)..stall(4000);
      final policy = SyncCorrectionPolicy();

      final decisions = _run(policy, client, ticks: 4);
      final firstSkip = decisions.indexWhere(
        (d) => d.action == SyncCorrectionAction.skip,
      );

      expect(firstSkip, isNonNegative);
      expect(
        decisions
            .skip(firstSkip + 1)
            .every((d) => d.action == SyncCorrectionAction.defer),
        isTrue,
        reason: 'measurements inside the settle window are not usable',
      );
    });
  });

  group('measurement noise', () {
    test('ignores drift within the position sampling resolution', () {
      // A sub-sample "drift" on a 250ms position stream is quantisation noise.
      final policy = SyncCorrectionPolicy();
      final decision = policy.evaluate(
        nowMs: 30000,
        serverNowMs: 30000,
        currentPositionMs: 29750,
        lastSyncPositionMs: 0,
        lastSyncTimeMs: 0,
        isBuffering: false,
        isPlaying: true,
        clockJitterMs: 0,
        settings: _defaultSettings,
      );

      expect(decision.action, SyncCorrectionAction.hold);
      expect(decision.measuredDelayMs, -250);
    });

    test('widens the dead band when the clock offset is jittery', () {
      final policy = SyncCorrectionPolicy();
      SyncCorrectionDecision evaluate(int jitter) => policy.evaluate(
            nowMs: 30000,
            serverNowMs: 30000,
            currentPositionMs: 29400,
            lastSyncPositionMs: 0,
            lastSyncTimeMs: 0,
            isBuffering: false,
            isPlaying: true,
            clockJitterMs: jitter,
            settings: _defaultSettings,
          );

      expect(evaluate(0).action, SyncCorrectionAction.speed);
      expect(evaluate(1200).action, SyncCorrectionAction.hold);
    });
  });

  group('speed correction', () {
    SyncCorrectionDecision decisionFor(int positionMs) =>
        SyncCorrectionPolicy().evaluate(
          nowMs: 30000,
          serverNowMs: 30000,
          currentPositionMs: positionMs,
          lastSyncPositionMs: 0,
          lastSyncTimeMs: 0,
          isBuffering: false,
          isPlaying: true,
          clockJitterMs: 0,
          settings: _defaultSettings,
        );

    test('slows down when ahead of the group', () {
      final decision = decisionFor(31000);
      expect(decision.action, SyncCorrectionAction.speed);
      expect(decision.speed, lessThan(1.0));
      expect(decision.speedDurationMs, 1000);
    });

    test('speeds up when behind the group', () {
      final decision = decisionFor(29000);
      expect(decision.action, SyncCorrectionAction.speed);
      expect(decision.speed, greaterThan(1.0));
    });

    test('leaves the rate alone when speed-to-sync is off', () {
      final decision = SyncCorrectionPolicy().evaluate(
        nowMs: 30000,
        serverNowMs: 30000,
        currentPositionMs: 29000,
        lastSyncPositionMs: 0,
        lastSyncTimeMs: 0,
        isBuffering: false,
        isPlaying: true,
        clockJitterMs: 0,
        settings: const SyncCorrectionSettings(
          useSkipToSync: true,
          useSpeedToSync: false,
          minDelaySkipToSyncMs: 2000,
          minDelaySpeedToSyncMs: 100,
          maxDelaySpeedToSyncMs: 5000,
          speedToSyncDurationMs: 1000,
        ),
      );
      expect(decision.action, SyncCorrectionAction.hold);
    });
  });

  group('lifecycle', () {
    test('a new sync point clears the skip streak but keeps the latency', () {
      final client = _FakeClient(seekLatencyMs: 3000)..stall(4000);
      final policy = SyncCorrectionPolicy();
      _run(policy, client, ticks: 10);

      expect(policy.seekLatencyAllowanceMs, greaterThan(0));
      final learned = policy.seekLatencyAllowanceMs;

      policy.onSyncPointChanged(client.nowMs);

      expect(policy.consecutiveSkips, 0);
      expect(
        policy.seekLatencyAllowanceMs,
        learned,
        reason: 'seek latency is a property of the device and stream',
      );
    });

    test('a group seek is given time to land before anything is measured', () {
      final policy = SyncCorrectionPolicy();
      final client = _FakeClient(seekLatencyMs: 1200);
      client.seekTo(0);
      policy.onSyncPointChanged(client.nowMs);

      expect(_run(policy, client, ticks: 1).single.action,
          SyncCorrectionAction.defer);
    });

    test('a group seek re-anchors instead of nudging the rate', () {
      // The seek's own latency is not drift. Answering it with a rate nudge
      // inserts an mpv tempo filter mid-playback and audibly glitches.
      final policy = SyncCorrectionPolicy();
      final client = _FakeClient(seekLatencyMs: 1200);
      client.seekTo(0);
      policy.onSyncPointChanged(client.nowMs);

      final decisions = _run(policy, client, ticks: 30);

      expect(_countOf(decisions, SyncCorrectionAction.rebaseline), 1);
      expect(
        _countOf(decisions, SyncCorrectionAction.speed),
        0,
        reason: 'no rate nudge, so no tempo filter churn after a seek',
      );
      expect(_countOf(decisions, SyncCorrectionAction.skip), 0);
      expect(
        policy.seekLatencyAllowanceMs,
        1200,
        reason: 'the residual is the seek latency, worth learning',
      );
    });

    test('real drift after a re-anchored seek is still corrected', () {
      final policy = SyncCorrectionPolicy();
      final client = _FakeClient(seekLatencyMs: 1200);
      client.seekTo(0);
      policy.onSyncPointChanged(client.nowMs);
      _run(policy, client, ticks: 4);

      // A stall well after the seek is genuine drift, not seek cost.
      client.stall(5000);
      final decisions = _run(policy, client, ticks: 12);

      expect(
        _countOf(decisions, SyncCorrectionAction.skip) +
            _countOf(decisions, SyncCorrectionAction.speed),
        greaterThan(0),
        reason: 're-anchoring must not blind the policy to later drift',
      );
    });

    test('a new item clears a give-up', () {
      final client = _FakeClient(seekLatencyMs: 14000)..stall(4000);
      final policy = SyncCorrectionPolicy();
      _run(policy, client, ticks: 400);
      expect(policy.hasGivenUp, isTrue);

      policy.reset();

      expect(policy.hasGivenUp, isFalse);
      expect(policy.seekLatencyAllowanceMs, 0);
      expect(policy.consecutiveSkips, 0);
    });

    test('a give-up survives an ordinary measurement', () {
      final client = _FakeClient(seekLatencyMs: 14000)..stall(4000);
      final policy = SyncCorrectionPolicy();
      _run(policy, client, ticks: 400);

      // Even a perfectly synced measurement must not restart correcting.
      final decision = policy.evaluate(
        nowMs: 999000,
        serverNowMs: 999000,
        currentPositionMs: 999000,
        lastSyncPositionMs: 0,
        lastSyncTimeMs: 0,
        isBuffering: false,
        isPlaying: true,
        clockJitterMs: 0,
        settings: _defaultSettings,
      );
      expect(decision.action, SyncCorrectionAction.giveUp);
    });

    test('a group seek lifts a give-up', () {
      final client = _FakeClient(seekLatencyMs: 14000)..stall(4000);
      final policy = SyncCorrectionPolicy();
      _run(policy, client, ticks: 400);
      expect(policy.hasGivenUp, isTrue);

      policy.onSyncPointChanged(client.nowMs);

      expect(policy.hasGivenUp, isFalse);
      expect(policy.consecutiveSkips, 0);
      expect(
        policy.seekLatencyAllowanceMs,
        greaterThan(0),
        reason: 'the learned latency belongs to the device, not the stretch',
      );
    });

    test('a residual too large to be seek cost is corrected, not absorbed', () {
      final policy = SyncCorrectionPolicy();
      final client = _FakeClient(seekLatencyMs: 0);
      client.seekTo(0);
      policy.onSyncPointChanged(client.nowMs);
      client.stall(SyncCorrectionPolicy.maxSeekLatencyAllowanceMs + 6000);

      final decisions = _run(policy, client, ticks: 20);

      expect(_countOf(decisions, SyncCorrectionAction.rebaseline), 0);
      expect(
        _countOf(decisions, SyncCorrectionAction.skip),
        greaterThan(0),
      );
    });
  });
}
