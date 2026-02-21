import 'dart:async';
import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/scheduler.dart';
import 'package:get/get.dart';
import 'package:provider/provider.dart';
import 'package:flutter_hbb/models/state_model.dart';
import '../../consts.dart';
import '../../common/widgets/overlay.dart';
import '../../common/widgets/remote_input.dart';
import '../../common.dart';
import '../../common/widgets/dialog.dart';
import '../../common/widgets/toolbar.dart';
import '../../models/model.dart';
import '../../models/input_model.dart';
import '../../models/platform_model.dart';
import '../../common/shared_state.dart';
import '../../utils/image.dart';
import '../widgets/remote_toolbar.dart';
import '../widgets/kb_layout_type_chooser.dart';
import '../widgets/tabbar_widget.dart';
import 'package:flutter_hbb/native/custom_cursor.dart'
    if (dart.library.html) 'package:flutter_hbb/web/custom_cursor.dart';
final SimpleWrapper<bool> _firstEnterImage = SimpleWrapper(false);
// Used to skip session close if "move to new window" is clicked.
final Map<String, bool> closeSessionOnDispose = {};
class RemotePage extends StatefulWidget {
  RemotePage({
    Key? key,
    required this.id,
    required this.toolbarState,
    this.sessionId,
    this.tabWindowId,
    this.password,
    this.display,
    this.displays,
    this.tabController,
    this.switchUuid,
    this.forceRelay,
    this.isSharedPassword,
  }) : super(key: key) {
    initSharedStates(id);
  }
  final String id;
  final SessionID? sessionId;
  final int? tabWindowId;
  final int? display;
  final List<int>? displays;
  final String? password;
  final ToolbarState toolbarState;
  final String? switchUuid;
  final bool? forceRelay;
  final bool? isSharedPassword;
  final SimpleWrapper<State<RemotePage>?> _lastState = SimpleWrapper(null);
  final DesktopTabController? tabController;
  FFI get ffi => (_lastState.value! as _RemotePageState)._ffi;
  @override
  State<RemotePage> createState() {
    final state = _RemotePageState(id);
    _lastState.value = state;
    return state;
  }
}
class _RemotePageState extends State<RemotePage>
    with
        AutomaticKeepAliveClientMixin,
        MultiWindowListener,
        TickerProviderStateMixin {
  Timer? _timer;
  String keyboardMode = "legacy";
  bool _isWindowBlur = false;
  final _cursorOverImage = false.obs;
  late RxBool _showRemoteCursor;
  late RxBool _zoomCursor;
  late RxBool _remoteCursorMoved;
  late RxBool _keyboardEnabled;
  final _uniqueKey = UniqueKey();
  var _blockableOverlayState = BlockableOverlayState();
  final FocusNode _rawKeyFocusNode = FocusNode(debugLabel: "rawkeyFocusNode");
  // Debounce timer for pointer lock center updates during window events.
  // Uses kDefaultPointerLockCenterThrottleMs from consts.dart for the duration.
  Timer? _pointerLockCenterDebounceTimer;
  // We need `_instanceIdOnEnterOrLeaveImage4Toolbar` together with `_onEnterOrLeaveImage4Toolbar`
  // to identify the toolbar instance and its callback function.
  int? _instanceIdOnEnterOrLeaveImage4Toolbar;
  Function(bool)? _onEnterOrLeaveImage4Toolbar;
  late FFI _ffi;
  SessionID get sessionId => _ffi.sessionId;
  _RemotePageState(String id) {
    _initStates(id);
  }
  void _initStates(String id) {
    _zoomCursor = PeerBoolOption.find(id, kOptionZoomCursor);
    _showRemoteCursor = ShowRemoteCursorState.find(id);
    _keyboardEnabled = KeyboardEnabledState.find(id);
    _remoteCursorMoved = RemoteCursorMovedState.find(id);
  }
  @override
  void initState() {
    super.initState();
    _ffi = FFI(widget.sessionId);
    Get.put<FFI>(_ffi, tag: widget.id);
    _ffi.imageModel.addCallbackOnFirstImage((String peerId) {
      _ffi.canvasModel.activateLocalCursor();
      // 屏蔽1：移除键盘布局选择弹窗（被控端/控制端都不显示）
      // showKBLayoutTypeChooserIfNeeded(
      //     _ffi.ffiModel.pi.platform, _ffi.dialogManager);
      _ffi.recordingModel
          .updateStatus(bind.sessionGetIsRecording(sessionId: _ffi.sessionId));
    });
    _ffi.canvasModel.initializeEdgeScrollFallback(this);
    _ffi.start(
      widget.id,
      password: widget.password,
      isSharedPassword: widget.isSharedPassword,
      switchUuid: widget.switchUuid,
      forceRelay: widget.forceRelay,
      tabWindowId: widget.tabWindowId,
      display: widget.display,
      displays: widget.displays,
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // 屏蔽2：移除系统UI隐藏（无需再设置，因为窗口本身不渲染）
      // SystemChrome.setEnabledSystemUIMode(SystemUiMode.manual, overlays: []);
      // 屏蔽3：移除连接中加载提示弹窗
      // _ffi.dialogManager
      //     .showLoading(translate('Connecting...'), onCancel: closeConnection);
    });
    WakelockManager.enable(_uniqueKey);
    _ffi.ffiModel.updateEventListener(sessionId, widget.id);
    if (!isWeb) bind.pluginSyncUi(syncTo: kAppTypeDesktopRemote);
    // 屏蔽4：移除画质监控浮窗（彻底隐藏，不初始化）
    // _ffi.qualityMonitorModel.checkShowQualityMonitor(sessionId);
    _ffi.dialogManager.loadMobileActionsOverlayVisible();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // Session option should be set after models.dart/FFI.start
      _showRemoteCursor.value = bind.sessionGetToggleOptionSync(
          sessionId: sessionId, arg: 'show-remote-cursor');
      _zoomCursor.value = bind.sessionGetToggleOptionSync(
          sessionId: sessionId, arg: kOptionZoomCursor);
    });
    DesktopMultiWindow.addListener(this);
    _blockableOverlayState.applyFfi(_ffi);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      widget.tabController?.onSelected?.call(widget.id);
    });
    // Register callback to cancel debounce timer when relative mouse mode is disabled
    _ffi.inputModel.onRelativeMouseModeDisabled =
        _cancelPointerLockCenterDebounceTimer;
  }
  /// Cancel the pointer lock center debounce timer
  void _cancelPointerLockCenterDebounceTimer() {
    _pointerLockCenterDebounceTimer?.cancel();
    _pointerLockCenterDebounceTimer = null;
  }
  @override
  void onWindowBlur() {
    super.onWindowBlur();
    if (isWindows) {
      _isWindowBlur = true;
      _rawKeyFocusNode.unfocus();
    }
    stateGlobal.isFocused.value = false;
    if (_ffi.inputModel.relativeMouseMode.value) {
      _ffi.inputModel.onWindowBlur();
    }
  }
  @override
  void onWindowFocus() {
    super.onWindowFocus();
    if (isWindows) {
      _isWindowBlur = false;
    }
    stateGlobal.isFocused.value = true;
    if (_ffi.inputModel.relativeMouseMode.value) {
      _rawKeyFocusNode.requestFocus();
      _ffi.inputModel.onWindowFocus();
    }
  }
  @override
  void onWindowRestore() {
    super.onWindowRestore();
    if (isWindows) {
      _isWindowBlur = false;
    }
    WakelockManager.enable(_uniqueKey);
    _updatePointerLockCenterIfNeeded();
  }
  @override
  void onWindowMaximize() {
    super.onWindowMaximize();
    WakelockManager.enable(_uniqueKey);
    _updatePointerLockCenterIfNeeded();
  }
  @override
  void onWindowResize() {
    super.onWindowResize();
    _updatePointerLockCenterIfNeeded();
  }
  @override
  void onWindowMove() {
    super.onWindowMove();
    _updatePointerLockCenterIfNeeded();
  }
  /// Update pointer lock center with debouncing to avoid excessive updates
  /// during rapid window move/resize events.
  void _updatePointerLockCenterIfNeeded() {
    if (!_ffi.inputModel.relativeMouseMode.value) return;
    _pointerLockCenterDebounceTimer?.cancel();
    _pointerLockCenterDebounceTimer = Timer(
      const Duration(milliseconds: kDefaultPointerLockCenterThrottleMs),
      () {
        if (!mounted) return;
        if (_ffi.inputModel.relativeMouseMode.value) {
          _ffi.inputModel.updatePointerLockCenter();
        }
      },
    );
  }
  @override
  void onWindowMinimize() {
    super.onWindowMinimize();
    WakelockManager.disable(_uniqueKey);
    if (_ffi.inputModel.relativeMouseMode.value) {
      _ffi.inputModel.onWindowBlur();
    }
  }
  @override
  void onWindowEnterFullScreen() {
    super.onWindowEnterFullScreen();
    if (isMacOS) {
      stateGlobal.setFullscreen(true);
    }
  }
  @override
  void onWindowLeaveFullScreen() {
    super.onWindowLeaveFullScreen();
    if (isMacOS) {
      stateGlobal.setFullscreen(false);
    }
  }
  @override
  Future<void> dispose() async {
    final closeSession = closeSessionOnDispose.remove(widget.id) ?? true;
    super.dispose();
    debugPrint("REMOTE PAGE dispose session $sessionId ${widget.id}");
    if (!isWeb) bind.hostStopSystemKeyPropagate(stopped: true);
    _pointerLockCenterDebounceTimer?.cancel();
    _pointerLockCenterDebounceTimer = null;
    _ffi.inputModel.onRelativeMouseModeDisabled = null;
    _ffi.textureModel.onRemotePageDispose(closeSession);
    if (closeSession) {
      _ffi.inputModel.enterOrLeave(false);
    }
    DesktopMultiWindow.removeListener(this);
    _ffi.dialogManager.hideMobileActionsOverlay();
    _ffi.imageModel.disposeImage();
    _ffi.cursorModel.disposeImages();
    _rawKeyFocusNode.dispose();
    await _ffi.close(closeSession: closeSession);
    _timer?.cancel();
    // 强制关闭所有未销毁的弹窗（兜底，防止残留提示）
    _ffi.dialogManager.dismissAll();
    if (closeSession) {
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.manual,
          overlays: SystemUiOverlay.values);
    }
    WakelockManager.disable(_uniqueKey);
    await Get.delete<FFI>(tag: widget.id);
    removeSharedStates(widget.id);
  }
  Widget emptyOverlay() => BlockableOverlay(
        state: _blockableOverlayState,
        underlying: Container(
          color: Colors.transparent,
        ),
      );
  Widget buildBody(BuildContext context) {
    // 屏蔽5：移除工具栏定义，彻底不渲染远程工具栏
    // remoteToolbar(BuildContext context) => RemoteToolbar(
    //       id: widget.id,
    //       ffi: _ffi,
    //       state: widget.toolbarState,
    //       onEnterOrLeaveImageSetter: (id, func) {
    //         _instanceIdOnEnterOrLeaveImage4Toolbar = id;
    //         _onEnterOrLeaveImage4Toolbar = func;
    //       },
    //       onEnterOrLeaveImageCleaner: (id) {
    //         if (_instanceIdOnEnterOrLeaveImage4Toolbar == id) {
    //           _instanceIdOnEnterOrLeaveImage4Toolbar = null;
    //           _onEnterOrLeaveImage4Toolbar = null;
    //         }
    //       },
    //       setRemoteState: setState,
    //     );
    bodyWidget() {
      // 屏蔽6：替换原布局为空白容器，不渲染任何远程画面相关内容
      return Container(color: Colors.transparent);
      // 以下为原代码，注释掉
      // return Stack(
      //   children: [
      //     Container(
      //         color: kColorCanvas,
      //         child: RawKeyFocusScope(
      //             focusNode: _rawKeyFocusNode,
      //             onFocusChange: (bool imageFocused) {
      //               debugPrint(
      //                   "onFocusChange(window active:${!_isWindowBlur}) $imageFocused");
      //               if (isWindows) {
      //                 if (_isWindowBlur) {
      //                   imageFocused = false;
      //                   Future.delayed(Duration.zero, () {
      //                     _rawKeyFocusNode.unfocus();
      //                   });
      //                 }
      //                 if (imageFocused) {
      //                   _ffi.inputModel.enterOrLeave(true);
      //                 } else {
      //                   _ffi.inputModel.enterOrLeave(false);
      //                 }
      //               }
      //             },
      //             inputModel: _ffi.inputModel,
      //             child: getBodyForDesktop(context))),
      //     Stack(
      //       children: [
      //         _ffi.ffiModel.pi.isSet.isTrue &&
      //                 _ffi.ffiModel.waitForFirstImage.isTrue
      //             ? emptyOverlay()
      //             : () {
      //                 if (!_ffi.ffiModel.isPeerAndroid) {
      //                   return Offstage();
      //                 } else {
      //                   return Obx(() => Offstage(
      //                         offstage: _ffi.dialogManager
      //                             .mobileActionsOverlayVisible.isFalse,
      //                         child: Overlay(initialEntries: [
      //                           makeMobileActionsOverlayEntry(
      //                             () => _ffi.dialogManager
      //                                 .setMobileActionsOverlayVisible(false),
      //                             ffi: _ffi,
      //                           )
      //                         ]),
      //                       ));
      //                 }
      //               }(),
      //         Obx(() => _ffi.inputModel.relativeMouseMode.value
      //             ? const Offstage()
      //             : _ffi.ffiModel.pi.isSet.isTrue
      //                 ? Overlay(initialEntries: [
      //                     OverlayEntry(builder: remoteToolbar)
      //                   ])
      //                 : remoteToolbar(context)),
      //         _ffi.ffiModel.pi.isSet.isFalse ? emptyOverlay() : Offstage(),
      //       ],
      //     ),
      //   ],
      // );
    }
    return Scaffold(
      backgroundColor: Colors.transparent, // 屏蔽7：窗口背景设为透明
      body: Obx(() {
        final imageReady = _ffi.ffiModel.pi.isSet.isTrue &&
            _ffi.ffiModel.waitForFirstImage.isFalse;
        if (imageReady) {
          if (DateTime.now().difference(togglePrivacyModeTime) >
              const Duration(milliseconds: 3000)) {
            _ffi.dialogManager.dismissAll();
            _blockableOverlayState = BlockableOverlayState();
            _blockableOverlayState.applyFfi(_ffi);
          }
          // 屏蔽8：替换为空白容器，不渲染遮罩和画面
          return Container(color: Colors.transparent);
          // return BlockableOverlay(
          //   underlying: bodyWidget(),
          //   state: _blockableOverlayState,
          // );
        } else {
          // 屏蔽9：替换为空白容器
          return Container(color: Colors.transparent);
          // return bodyWidget();
        }
      }),
    );
  }
  @override
  Widget build(BuildContext context) {
    super.build(context);
    return WillPopScope(
        onWillPop: () async {
          clientClose(sessionId, _ffi);
          return false;
        },
        child: MultiProvider(providers: [
          ChangeNotifierProvider.value(value: _ffi.ffiModel),
          ChangeNotifierProvider.value(value: _ffi.imageModel),
          ChangeNotifierProvider.value(value: _ffi.cursorModel),
          ChangeNotifierProvider.value(value: _ffi.canvasModel),
          ChangeNotifierProvider.value(value: _ffi.recordingModel),
        ], child: buildBody(context)));
  }
  void enterView(PointerEnterEvent evt) {
    _ffi.canvasModel.rearmEdgeScroll();
    _cursorOverImage.value = true;
    _firstEnterImage.value = true;
    // 屏蔽10：移除工具栏鼠标事件回调（工具栏已删除）
    // if (_onEnterOrLeaveImage4Toolbar != null) {
    //   try {
    //     _onEnterOrLeaveImage4Toolbar!(true);
    //   } catch (e) {
    //     //
    //   }
    // }
    if (!isWindows) {
      if (!_rawKeyFocusNode.hasFocus) {
        _rawKeyFocusNode.requestFocus();
      }
      _ffi.inputModel.enterOrLeave(true);
    }
  }
  void leaveView(PointerExitEvent evt) {
    _ffi.canvasModel.disableEdgeScroll();
    if (_ffi.ffiModel.keyboard) {
      _ffi.inputModel.tryMoveEdgeOnExit(evt.position);
    }
    _cursorOverImage.value = false;
    _firstEnterImage.value = false;
    // 屏蔽11：移除工具栏鼠标事件回调
    // if (_onEnterOrLeaveImage4Toolbar != null) {
    //   try {
    //     _onEnterOrLeaveImage4Toolbar!(false);
    //   } catch (e) {
    //     //
    //   }
    // }
    if (!isWindows) {
      _ffi.inputModel.enterOrLeave(false);
    }
  }
  Widget _buildRawTouchAndPointerRegion(
    Widget child,
    PointerEnterEventListener? onEnter,
    PointerExitEventListener? onExit,
  ) {
    return RawTouchGestureDetectorRegion(
      child: _buildRawPointerMouseRegion(child, onEnter, onExit),
      ffi: _ffi,
    );
  }
  Widget _buildRawPointerMouseRegion(
    Widget child,
    PointerEnterEventListener? onEnter,
    PointerExitEventListener? onExit,
  ) {
    return RawPointerMouseRegion(
      onEnter: onEnter,
      onExit: onExit,
      onPointerDown: (event) {
        if (_isWindowBlur) {
          debugPrint(
              "Unexpected status: onPointerDown is triggered while the remote window is in blur status");
          _isWindowBlur = false;
        }
        if (!_rawKeyFocusNode.hasFocus) {
          _rawKeyFocusNode.requestFocus();
        }
      },
      inputModel: _ffi.inputModel,
      child: child,
    );
  }
  Widget getBodyForDesktop(BuildContext context) {
    // 屏蔽12：替换为空白容器，彻底不渲染远程画面、光标、画质监控
    return Container(color: Colors.transparent);
    // 以下为原代码，注释掉
    // var paints = <Widget>[
    //   MouseRegion(
    //     onEnter: (evt) {
    //       if (!isWeb) bind.hostStopSystemKeyPropagate(stopped: false);
    //     },
    //     onExit: (evt) {
    //       if (!isWeb) bind.hostStopSystemKeyPropagate(stopped: true);
    //     },
    //     child: _ViewStyleUpdater(
    //       canvasModel: _ffi.canvasModel,
    //       inputModel: _ffi.inputModel,
    //       child: Builder(builder: (context) {
    //         final peerDisplay = CurrentDisplayState.find(widget.id);
    //         return Obx(
    //           () => _ffi.ffiModel.pi.isSet.isFalse
    //               ? Container(color: Colors.transparent)
    //               : Obx(() {
    //                   _ffi.textureModel.updateCurrentDisplay(peerDisplay.value);
    //                   return ImagePaint(
    //                     id: widget.id,
    //                     zoomCursor: _zoomCursor,
    //                     cursorOverImage: _cursorOverImage,
    //                     keyboardEnabled: _keyboardEnabled,
    //                     remoteCursorMoved: _remoteCursorMoved,
    //                     listenerBuilder: (child) =>
    //                         _buildRawTouchAndPointerRegion(
    //                             child, enterView, leaveView),
    //                     ffi: _ffi,
    //                   );
    //                 }),
    //         );
    //       }),
    //     ),
    //   )
    // ];
    // if (!_ffi.canvasModel.cursorEmbedded) {
    //   paints
    //       .add(Obx(() => _showRemoteCursor.isFalse || _remoteCursorMoved.isFalse
    //           ? Offstage()
    //           : CursorPaint(
    //               id: widget.id,
    //               zoomCursor: _zoomCursor,
    //             )));
    // }
    // paints.add(
    //   Positioned(
    //     top: 10,
    //     right: 10,
    //     child: _buildRawTouchAndPointerRegion(
    //         QualityMonitor(_ffi.qualityMonitorModel), null, null),
    //   ),
    // );
    // return Stack(
    //   children: paints,
    // );
  }
  @override
  bool get wantKeepAlive => true;
}
/// 保留样式更新组件，无修改（不影响可视化，仅做尺寸监听）
class _ViewStyleUpdater extends StatefulWidget {
  final CanvasModel canvasModel;
  final InputModel inputModel;
  final Widget child;
  const _ViewStyleUpdater({
    Key? key,
    required this.canvasModel,
    required this.inputModel,
    required this.child,
  }) : super(key: key);
  @override
  State<_ViewStyleUpdater> createState() => _ViewStyleUpdaterState();
}
class _ViewStyleUpdaterState extends State<_ViewStyleUpdater> {
  Size? _lastSize;
  bool _callbackScheduled = false;
  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final maxWidth = constraints.maxWidth;
        final maxHeight = constraints.maxHeight;
        if (!maxWidth.isFinite || !maxHeight.isFinite) {
          return widget.child;
        }
        final newSize = Size(maxWidth, maxHeight);
        if (_lastSize != newSize) {
          _lastSize = newSize;
          if (!_callbackScheduled) {
            _callbackScheduled = true;
            SchedulerBinding.instance.addPostFrameCallback((_) {
              _callbackScheduled = false;
              final currentSize = _lastSize;
              if (mounted && currentSize != null) {
                widget.canvasModel.updateViewStyle();
                widget.inputModel.updateImageWidgetSize(currentSize);
              }
            });
          }
        }
        return widget.child;
      },
    );
  }
}
/// 屏蔽13：ImagePaint组件直接返回空白，不渲染任何远程画面（纹理/图像）
class ImagePaint extends StatefulWidget {
  final FFI ffi;
  final String id;
  final RxBool zoomCursor;
  final RxBool cursorOverImage;
  final RxBool keyboardEnabled;
  final RxBool remoteCursorMoved;
  final Widget Function(Widget)? listenerBuilder;
  ImagePaint(
      {Key? key,
      required this.ffi,
      required this.id,
      required this.zoomCursor,
      required this.cursorOverImage,
      required this.keyboardEnabled,
      required this.remoteCursorMoved,
      this.listenerBuilder})
      : super(key: key);
  @override
  State<StatefulWidget> createState() => _ImagePaintState();
}
class _ImagePaintState extends State<ImagePaint> {
  bool _lastRemoteCursorMoved = false;
  String get id => widget.id;
  RxBool get zoomCursor => widget.zoomCursor;
  RxBool get cursorOverImage => widget.cursorOverImage;
  RxBool get keyboardEnabled => widget.keyboardEnabled;
  RxBool get remoteCursorMoved => widget.remoteCursorMoved;
  Widget Function(Widget)? get listenerBuilder => widget.listenerBuilder;
  @override
  Widget build(BuildContext context) {
    // 直接返回空白，不渲染任何画面
    return Container(color: Colors.transparent);
  }
  Widget _buildScrollbarNonTextureRender(
      ImageModel m, Size imageSize, double s) {
    return Container(color: Colors.transparent);
  }
  Widget _buildScrollAutoNonTextureRender(
      ImageModel m, CanvasModel c, double s) {
    return Container(color: Colors.transparent);
  }
  Widget _BuildPaintTextureRender(
      CanvasModel c, double s, Offset offset, Size size, bool isViewOriginal) {
    return Container(color: Colors.transparent);
  }
  MouseCursor _buildCustomCursor(BuildContext context, double scale) {
    return MouseCursor.defer;
  }
  MouseCursor _buildDisabledCursor(BuildContext context, double scale) {
    return MouseCursor.defer;
  }
  Widget _buildCrossScrollbarFromLayout(
    BuildContext context,
    Widget child,
    Size layoutSize,
    Size size,
    ScrollController horizontal,
    ScrollController vertical,
  ) {
    return Container(color: Colors.transparent);
  }
  Widget _buildListener(Widget child) {
    return Container(color: Colors.transparent);
  }
}
/// 屏蔽14：CursorPaint组件直接返回空白，不渲染远程光标
class CursorPaint extends StatelessWidget {
  final String id;
  final RxBool zoomCursor;
  const CursorPaint({
    Key? key,
    required this.id,
    required this.zoomCursor,
  }) : super(key: key);
  @override
  Widget build(BuildContext context) {
    return Container(color: Colors.transparent);
  }
}
