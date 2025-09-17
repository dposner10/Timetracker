import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:shared_preferences/shared_preferences.dart';

class PomodoroAudioTask extends BaseAudioHandler with SeekHandler {
  Duration _remainingTime = const Duration(minutes: 25);
  final _audioPlayer = AudioPlayer();
  DateTime? _endTime;

  // Durations
  Duration _workDuration = const Duration(minutes: 25);
  Duration _shortBreakDuration = const Duration(minutes: 5);
  Duration _longBreakDuration = const Duration(minutes: 15);

  // State
  bool _isBreak = false;
  int _sessionPomodoros = 0;
  int _completedPomodoros = 0;

  PomodoroAudioTask() {
    _loadDurations();
  }

  Future<void> _loadDurations() async {
    final prefs = await SharedPreferences.getInstance();
    _workDuration = Duration(minutes: prefs.getInt('workDuration') ?? 25);
    _shortBreakDuration =
        Duration(minutes: prefs.getInt('shortBreakDuration') ?? 5);
    _longBreakDuration =
        Duration(minutes: prefs.getInt('longBreakDuration') ?? 15);
    _reset();
  }

  @override
  Future<void> play() async {
    if (playbackState.value.playing) return;

    playbackState.add(playbackState.value.copyWith(
      playing: true,
      controls: [pauseControl, stopControl],
    ));
    _endTime = DateTime.now().add(_remainingTime);
    _runTimerLoop();
  }

  Future<void> _runTimerLoop() async {
    while (playbackState.value.playing) {
      final now = DateTime.now();
      if (_endTime != null && now.isAfter(_endTime!)) {
        _remainingTime = Duration.zero;
      } else if (_endTime != null) {
        _remainingTime = _endTime!.difference(now);
      } else {
        break;
      }

      if (_remainingTime.inSeconds > 0) {
        _broadcastState();
        await Future.delayed(const Duration(seconds: 1));
      } else {
        await _handleTimerCompletion();
      }
    }
  }

  Future<void> _handleTimerCompletion() async {
    await _playSound();
    if (_isBreak) {
      _isBreak = false;
      _remainingTime = _workDuration;
    } else {
      customEvent.add(
          {'type': 'work_session_completed', 'duration': _workDuration.inSeconds});
      _completedPomodoros++;
      _sessionPomodoros++;
      _isBreak = true;
      _remainingTime = _getCurrentBreakDuration();
    }
    _broadcastState();
    await pause();
  }

  @override
  Future<void> pause() async {
    playbackState.add(playbackState.value.copyWith(
      playing: false,
      controls: [playControl, stopControl],
    ));
  }

  @override
  Future<void> stop() async {
    playbackState.add(playbackState.value.copyWith(playing: false));
    _reset();
    await super.stop();
  }

  @override
  Future<void> customAction(String name, [Map<String, dynamic>? extras]) async {
    if (name == 'set_durations') {
      _workDuration = Duration(minutes: extras!['work'] as int);
      _shortBreakDuration = Duration(minutes: extras['short'] as int);
      _longBreakDuration = Duration(minutes: extras['long'] as int);

      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt('workDuration', _workDuration.inMinutes);
      await prefs.setInt('shortBreakDuration', _shortBreakDuration.inMinutes);
      await prefs.setInt('longBreakDuration', _longBreakDuration.inMinutes);

      if (!playbackState.value.playing) {
        _reset();
      }
    } else if (name == 'reset_session') {
      _sessionPomodoros = 0;
      _broadcastState();
    }
  }

  void _reset() {
    _isBreak = false;
    _remainingTime = _workDuration;
    _broadcastState();
  }

  Duration _getCurrentBreakDuration() {
    return (_sessionPomodoros % 4 == 0 && _sessionPomodoros > 0)
        ? _longBreakDuration
        : _shortBreakDuration;
  }

  void _broadcastState() {
    final currentDuration =
        _isBreak ? _getCurrentBreakDuration() : _workDuration;
    final elapsedTime = currentDuration - _remainingTime;

    final mediaItem = MediaItem(
      id: 'pomodoro',
      title: _isBreak ? 'Pause' : 'Arbeitszeit',
      duration: currentDuration,
      extras: {
        'isBreak': _isBreak,
        'completedPomodoros': _completedPomodoros,
        'sessionPomodoros': _sessionPomodoros,
        'remainingTime': _remainingTime.inSeconds,
      },
    );
    this.mediaItem.add(mediaItem);

    playbackState.add(playbackState.value.copyWith(
      controls: [
        if (playbackState.value.playing) pauseControl else playControl,
        stopControl
      ],
      processingState: AudioProcessingState.ready,
      updatePosition: elapsedTime,
    ));
  }

  Future<void> _playSound() async {
    try {
      await _audioPlayer.play(AssetSource('sounds/bell-sound-370341.mp3'));
    } catch (e) {
      // Don't do anything
    }
  }

  static const playControl = MediaControl(
    androidIcon: 'drawable/ic_play_arrow',
    label: 'Play',
    action: MediaAction.play,
  );
  static const pauseControl = MediaControl(
    androidIcon: 'drawable/ic_pause',
    label: 'Pause',
    action: MediaAction.pause,
  );
  static const stopControl = MediaControl(
    androidIcon: 'drawable/ic_stop',
    label: 'Stop',
    action: MediaAction.stop,
  );
}
