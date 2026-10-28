import 'dart:async';
import 'package:flutter_bloc/flutter_bloc.dart';
import '../services/wallet_service.dart';
import '../services/node_service.dart';
import '../services/ble_service.dart';
import 'core_event.dart';
import 'core_state.dart';

class CoreBloc extends Bloc<CoreEvent, CoreState> {
  final WalletService walletService;
  final NodeService   nodeService;
  final BleService    bleService;

  CoreBloc({
    required this.walletService,
    required this.nodeService,
    required this.bleService,
  }) : super(const CoreState()) {
    on<AppStarted>     (_onStarted);
    on<NodeConnected>  (_onNodeConnected);
    on<NodeDisconnected>(_onNodeDisconnected);
    on<NodeRemoved>    (_onNodeRemoved);
    on<WalletImported>(_onWalletImported);
  }

  // Portfel NIE jest tworzony przy starcie — powstaje/odzyskiwany przy dodaniu
  // noda. welcome = brak nodów; ready = ≥1 node (portfel wtedy już istnieje).
  Future<void> _onStarted(AppStarted e, Emitter<CoreState> emit) async {
    final wallet = await walletService.exists()
        ? await walletService.load() : null;
    final node = await nodeService.loadSaved(bleService: bleService);
    // W srodku jestes gdy masz WALLET albo lokalny node — sam wallet wystarcza
    // (widok mapy, Twoje nody z BE po wallecie, portfel). Welcome tylko gdy nic.
    emit(state.copyWith(
        phase: (node == null && wallet == null) ? AppPhase.welcome : AppPhase.ready,
        wallet: wallet));
  }

  // Po dodaniu noda portfel już istnieje (utworzony/odzyskany w setupie) — wczytaj
  Future<void> _onNodeConnected(NodeConnected e, Emitter<CoreState> emit) async {
    final wallet = await walletService.load();
    emit(state.copyWith(phase: AppPhase.ready, wallet: wallet));
  }

  Future<void> _onNodeDisconnected(NodeDisconnected e, Emitter<CoreState> emit) async {
    await nodeService.disconnect();
    emit(state.copyWith(phase: AppPhase.welcome));
  }

  Future<void> _onWalletImported(WalletImported e, Emitter<CoreState> emit) async {
    emit(state.copyWith(phase: AppPhase.ready, wallet: await walletService.load()));
  }

  Future<void> _onNodeRemoved(NodeRemoved e, Emitter<CoreState> emit) async {
    await nodeService.removeNode(e.deviceId);
    final hasWallet = await walletService.exists();
    emit(state.copyWith(
        phase: (nodeService.nodes.isEmpty && !hasWallet) ? AppPhase.welcome : AppPhase.ready));
  }
}
