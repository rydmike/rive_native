import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:rive_native/rive_native.dart' as rive;
import 'package:rive_native/rive_deferred.dart' as rive_deferred;

/// Plays a .riv through the default (deferred) pipeline and measures it: after
/// a warmup it averages UI-thread frame cost (FrameTiming build), raster cost,
/// fps, and the native record and replay microseconds per frame. Results show
/// on screen and print as JSON to the console.
class ExampleDeferred extends StatefulWidget {
  const ExampleDeferred({super.key});

  @override
  State<ExampleDeferred> createState() => _ExampleDeferredState();
}

class _ExampleDeferredState extends State<ExampleDeferred> {
  rive.File? _file;
  rive.Artboard? _artboard;
  rive.StateMachinePainter? _smPainter;
  rive.ArtboardWidgetPainter? _texturePainter;
  rive.RenderTexture? _texture;
  String? _error;
  String _status = 'starting...';

  static const _warmup = Duration(seconds: 3);
  static const _measure = Duration(seconds: 10);

  final List<FrameTiming> _timings = [];
  TimingsCallback? _timingsCb;

  @override
  void initState() {
    super.initState();
    _timingsCb = (timings) => _timings.addAll(timings);
    SchedulerBinding.instance.addTimingsCallback(_timingsCb!);
    // Release mode swallows uncaught async errors; surface them on screen.
    _bench().catchError((Object e, StackTrace st) {
      setState(() => _error = '$e\n$st');
    });
  }

  Future<bool> _buildScene() async {
    // The default decode path: the file records into the render context's own
    // session, every artboard instanced from it records into that same
    // session, and the render box attaches it. No wiring here.
    final file = await rive.File.asset(
      'assets/tiger.riv',
      riveFactory: rive.Factory.rive,
    );
    if (file == null) {
      setState(() => _error = 'Failed to decode .riv.');
      return false;
    }
    _file = file;
    _artboard = file.artboardAt(0)!;

    final smPainter = rive.RivePainter.stateMachine(
      fit: rive.Fit.contain,
      alignment: Alignment.center,
    );
    smPainter.artboardChanged(_artboard!);
    _smPainter = smPainter;
    _texturePainter = rive.ArtboardWidgetPainter(smPainter);
    _texture = rive.RiveNative.instance.makeRenderTexture();
    setState(() {});
    return true;
  }

  Future<void> _bench() async {
    setState(() => _status = 'warming up...');
    if (!await _buildScene()) {
      return;
    }
    await Future.delayed(_warmup);
    // One session per render context, and the artboard reports it.
    rive_deferred.deferredThreadStats(_artboard!.riveFactory!); // zero counters
    _timings.clear();
    setState(() => _status = 'measuring...');
    final sw = Stopwatch()..start();
    await Future.delayed(_measure);
    final elapsedUs = sw.elapsedMicroseconds;

    final builds = _timings.map((t) => t.buildDuration.inMicroseconds).toList()
      ..sort();
    final rasters =
        _timings.map((t) => t.rasterDuration.inMicroseconds).toList()..sort();
    num med(List<int> l) => l.isEmpty ? 0 : l[l.length ~/ 2];
    num avg(List<int> l) =>
        l.isEmpty ? 0 : l.reduce((a, b) => a + b) / l.length;
    final s = rive_deferred.deferredThreadStats(_artboard!.riveFactory!);
    final results = <String, dynamic>{
      'frames': _timings.length,
      'fps': (_timings.length * 1e6 / elapsedUs),
      'buildAvgUs': avg(builds),
      'buildMedianUs': med(builds),
      'rasterAvgUs': avg(rasters),
      'rasterMedianUs': med(rasters),
      'replayFrames': s.frames,
      'recordUsPerFrame': s.frames > 0 ? s.recordUs / s.frames : 0,
      'replayUsPerFrame': s.frames > 0 ? s.replayUs / s.frames : 0,
    };

    debugPrint(
        'rive_bench: ${const JsonEncoder.withIndent('  ').convert(results)}');

    setState(() {
      _status = 'DONE deferred: '
          'fps=${(results['fps'] as num).toStringAsFixed(1)} '
          'build=${(results['buildAvgUs'] as num).round()}us '
          'raster=${(results['rasterAvgUs'] as num).round()}us '
          'rec=${(results['recordUsPerFrame'] as num).round()}us '
          'rep=${(results['replayUsPerFrame'] as num).round()}us '
          'replayFrames=${results['replayFrames']}';
    });
  }

  @override
  void dispose() {
    if (_timingsCb != null) {
      SchedulerBinding.instance.removeTimingsCallback(_timingsCb!);
    }
    _texture?.removeAllTextureChangedListeners();
    _texture?.dispose();
    _texturePainter?.dispose();
    _smPainter?.dispose();
    _artboard?.dispose();
    // Last: the file detaches and disposes its recording session.
    _file?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return Center(
        child: Text('DEFERRED ERROR:\n$_error',
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.redAccent, fontSize: 20)),
      );
    }
    final texture = _texture;
    final painter = _texturePainter;
    return Stack(
      children: [
        if (texture != null && painter != null)
          Positioned.fill(child: texture.widget(painter: painter)),
        Positioned(
          left: 12,
          top: 60,
          right: 12,
          child: Text(_status,
              style: const TextStyle(color: Colors.greenAccent, fontSize: 14)),
        ),
      ],
    );
  }
}
