import 'dart:async';
import 'dart:convert';

import 'package:audioplayers/audioplayers.dart';
import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_redux/flutter_redux.dart';

import '../flet_app_services.dart';
import '../flet_server.dart';
import '../models/app_state.dart';
import '../models/control.dart';
import '../models/page_args_model.dart';
import '../utils/images.dart';
import 'error.dart';

class AudioControl extends StatefulWidget {
  final Control? parent;
  final Control control;
  final dynamic dispatch;
  final Widget? nextChild;

  const AudioControl(
      {Key? key,
      required this.parent,
      required this.control,
      required this.dispatch,
      required this.nextChild})
      : super(key: key);

  @override
  State<AudioControl> createState() => _AudioControlState();
}

class _AudioControlState extends State<AudioControl> {
  AudioPlayer? player;
  void Function(Duration)? _onDurationChanged;
  void Function(PlayerState)? _onStateChanged;
  void Function(int)? _onPositionChanged;
  Duration? _duration;
  int _position = -1;
  void Function()? _onSeekComplete;
  StreamSubscription? _onDurationChangedSubscription;
  StreamSubscription? _onStateChangedSubscription;
  StreamSubscription? _onPositionChangedSubscription;
  StreamSubscription? _onSeekCompleteSubscription;
  FletServer? _server;

  @override
  void initState() {
    debugPrint("Audio.initState($hashCode)");
    player = widget.control.state["player"];
    if (player == null) {
      player = AudioPlayer();
      player = widget.control.state["player"] = player;
    }
    _onDurationChangedSubscription =
        player?.onDurationChanged.listen((duration) {
      _onDurationChanged?.call(duration);
      _duration = duration;
    });
    _onStateChangedSubscription = player?.onPlayerStateChanged.listen((state) {
      _onStateChanged?.call(state);
    });
    _onPositionChangedSubscription =
        player?.onPositionChanged.listen((position) {
      int posMs = (position.inMilliseconds / 1000).round() * 1000;
      if (posMs != _position) {
        _position = posMs;
      } else if (position.inMilliseconds == _duration?.inMilliseconds) {
        _position = _duration!.inMilliseconds;
      } else {
        return;
      }
      _onPositionChanged?.call(_position);
    });
    _onSeekCompleteSubscription = player?.onSeekComplete.listen((event) {
      _onSeekComplete?.call();
    });

    widget.control.onRemove.clear();
    widget.control.onRemove.add(_onRemove);
    super.initState();
  }

  void _onRemove() {
    debugPrint("Audio.remove($hashCode)");
    widget.control.state["player"]?.dispose();
    _server?.controlInvokeMethods.remove(widget.control.id);
  }

  @override
  void deactivate() {
    debugPrint("Audio.deactivate($hashCode)");
    _onDurationChangedSubscription?.cancel();
    _onStateChangedSubscription?.cancel();
    _onPositionChangedSubscription?.cancel();
    _onSeekCompleteSubscription?.cancel();
    super.deactivate();
  }

  @override
  Widget build(BuildContext context) {
    debugPrint(
        "Audio build: ${widget.control.id} (${widget.control.hashCode})");

    var src = widget.control.attrString("src", "")!;
    var srcBase64 = widget.control.attrString("srcBase64", "")!;
    if (src == "" && srcBase64 == "") {
      return const ErrorControl(
          "Audio must have either \"src\" or \"src_base64\" specified.");
    }
    bool autoplay = widget.control.attrBool("autoplay", false)!;
    double? volume = widget.control.attrDouble("volume", null);
    double? balance = widget.control.attrDouble("balance", null);
    double? playbackRate = widget.control.attrDouble("playbackRate", null);
    var releaseMode = ReleaseMode.values.firstWhereOrNull((e) =>
        e.name.toLowerCase() ==
        widget.control.attrString("releaseMode", "")!.toLowerCase());
    bool onPositionChanged =
        widget.control.attrBool("onPositionChanged", false)!;

    var server = FletAppServices.of(context).server;

    final String prevSrc = widget.control.state["src"] ?? "";
    final String prevSrcBase64 = widget.control.state["srcBase64"] ?? "";
    final ReleaseMode? prevReleaseMode = widget.control.state["releaseMode"];
    final double? prevVolume = widget.control.state["volume"];
    final double? prevBalance = widget.control.state["balance"];
    final double? prevPlaybackRate = widget.control.state["playbackRate"];

    return StoreConnector<AppState, PageArgsModel>(
        distinct: true,
        converter: (store) => PageArgsModel.fromStore(store),
        builder: (context, pageArgs) {
          _onDurationChanged = (duration) {
            server.sendPageEvent(
                eventTarget: widget.control.id,
                eventName: "duration_changed",
                eventData: duration.inMilliseconds.toString());
          };

          _onStateChanged = (state) {
            debugPrint("Audio($hashCode) - state_changed: ${state.name}");
            server.sendPageEvent(
                eventTarget: widget.control.id,
                eventName: "state_changed",
                eventData: state.name.toString());
          };

          if (onPositionChanged) {
            _onPositionChanged = (duration) {
              server.sendPageEvent(
                  eventTarget: widget.control.id,
                  eventName: "position_changed",
                  eventData: duration.toString());
            };
          }

          _onSeekComplete = () {
            server.sendPageEvent(
                eventTarget: widget.control.id,
                eventName: "seek_complete",
                eventData: "");
          };

          () async {
            debugPrint("Audio ($hashCode) src=$src, prevSrc=$prevSrc");
            debugPrint(
                "Audio ($hashCode) srcBase64=$srcBase64, prevSrcBase64=$prevSrcBase64");

            bool srcChanged = false;
            if (src != "" && src != prevSrc) {
              widget.control.state["src"] = src;
              srcChanged = true;

              // URL or file?
              var assetSrc =
                  getAssetSrc(src, pageArgs.pageUri!, pageArgs.assetsDir);
              if (assetSrc.isFile) {
                await player?.setSourceDeviceFile(assetSrc.path);
              } else {
                await player?.setSourceUrl(assetSrc.path);
              }
            } else if (srcBase64 != "" && srcBase64 != prevSrcBase64) {
              widget.control.state["srcBase64"] = srcBase64;
              srcChanged = true;
              await player?.setSourceBytes(base64Decode(srcBase64));
            }

            if (srcChanged) {
              debugPrint("Audio.srcChanged!");
              server.sendPageEvent(
                  eventTarget: widget.control.id,
                  eventName: "loaded",
                  eventData: "");
            }

            if (releaseMode != null && releaseMode != prevReleaseMode) {
              debugPrint("Audio.setReleaseMode($releaseMode)");
              widget.control.state["releaseMode"] = releaseMode;
              await player?.setReleaseMode(releaseMode);
            }

            if (volume != null &&
                volume != prevVolume &&
                volume >= 0 &&
                volume <= 1) {
              widget.control.state["volume"] = volume;
              debugPrint("Audio.setVolume($volume)");
              await player?.setVolume(volume);
            }

            if (playbackRate != null &&
                playbackRate != prevPlaybackRate &&
                playbackRate >= 0 &&
                playbackRate <= 2) {
              widget.control.state["playbackRate"] = playbackRate;
              debugPrint("Audio.setPlaybackRate($playbackRate)");
              await player?.setPlaybackRate(playbackRate);
            }

            if (!kIsWeb &&
                balance != null &&
                balance != prevBalance &&
                balance >= -1 &&
                balance <= 1) {
              widget.control.state["balance"] = balance;
              debugPrint("Audio.setBalance($balance)");
              await player?.setBalance(balance);
            }

            if (srcChanged && autoplay) {
              debugPrint("Audio.resume($srcChanged, $autoplay)");
              await player?.resume();
            }

            _server = server;
            _server?.controlInvokeMethods[widget.control.id] =
                (methodName, args) async {
              switch (methodName) {
                case "play":
                  await player?.seek(const Duration(milliseconds: 0));
                  await player?.resume();
                  break;
                case "resume":
                  await player?.resume();
                  break;
                case "pause":
                  await player?.pause();
                  break;
                case "release":
                  await player?.release();
                  break;
                case "seek":
                  await player?.seek(Duration(
                      milliseconds: int.tryParse(args["position"] ?? "") ?? 0));
                  break;
                case "get_duration":
                  return (await player?.getDuration())
                      ?.inMilliseconds
                      .toString();
                case "get_current_position":
                  return (await player?.getCurrentPosition())
                      ?.inMilliseconds
                      .toString();
              }
              return null;
            };
          }();

          return const SizedBox.shrink();
        });
  }
}
