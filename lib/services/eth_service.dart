import 'dart:convert';
import 'dart:typed_data';
import 'package:http/http.dart' as http;
import 'package:wallet/wallet.dart' show EthereumAddress, EtherAmount;
import 'package:web3dart/web3dart.dart';
import '../config.dart';

/// EthService — interakcja on-chain z kontraktem GALU na Polygon (model v9).
/// SensmosRewardPool = token ERC-20 + pula nagród w JEDNYM kontrakcie.
/// Salda (MATIC/GALU), approve, deposit, claim (cumulative). Klucz z WalletService.
class EthService {
  final Web3Client _client = Web3Client(Config.polygonRpc, http.Client());

  static const int _chainId = 137; // Polygon PoS

  EthereumAddress get _addr => EthereumAddress.fromHex(Config.rewardPool);

  DeployedContract get _rp =>
      DeployedContract(ContractAbi.fromJson(_rpAbi, 'SensmosRewardPool'), _addr);

  // ── Odczyty ───────────────────────────────────────────────

  Future<BigInt> maticBalance(String addr) async {
    final b = await _client.getBalance(EthereumAddress.fromHex(addr));
    return b.getInWei;
  }

  Future<BigInt> tokenBalance(String addr) =>
      _readUint(_rp, 'balanceOf', [EthereumAddress.fromHex(addr)]);

  // Token == pula, więc deposit wymaga approve dla samego kontraktu (spender = pula).
  Future<BigInt> allowance(String owner) =>
      _readUint(_rp, 'allowance', [EthereumAddress.fromHex(owner), _addr]);

  // Ile dany adres już odebrał łącznie (lifetime). Porównaj z cumulative z /proof.
  Future<BigInt> claimedTotal(String addr) =>
      _readUint(_rp, 'claimedTotal', [EthereumAddress.fromHex(addr)]);

  /// Personal-sign (EIP-191) wiadomości kluczem walleta — dla claim-intent na BE
  /// (BE odzyskuje adres ethers.verifyMessage; zgodne z signPersonalMessage).
  String signIntent(String pkHex, String message) {
    final key = EthPrivateKey.fromHex(pkHex);
    final sig = key.signPersonalMessageToUint8List(
        Uint8List.fromList(utf8.encode(message)));
    return bytesToHex(sig, include0x: true);
  }

  Future<BigInt> _readUint(
      DeployedContract c, String fn, List<dynamic> params) async {
    final r =
        await _client.call(contract: c, function: c.function(fn), params: params);
    return r.first as BigInt;
  }

  // ── Transakcje ────────────────────────────────────────────

  Future<String> approve(String pkHex, BigInt amount) {
    final c = _rp;
    return _send(pkHex, c, c.function('approve'), [_addr, amount]);
  }

  Future<String> deposit(String pkHex, BigInt amount) {
    final c = _rp;
    return _send(pkHex, c, c.function('deposit'), [amount]);
  }

  /// Cumulative claim — odbiera nieodebraną część lifetime entitlement.
  Future<String> claim(
      String pkHex, BigInt cumulativeAmount, List<String> proofHex) {
    final c = _rp;
    final proof =
        proofHex.map<Uint8List>((p) => hexToBytes(p)).toList(growable: false);
    return _send(pkHex, c, c.function('claim'), [cumulativeAmount, proof]);
  }

  /// Zwykły przelew GALU (ERC-20 transfer) na dowolny adres. Gas płacony w POL.
  Future<String> transfer(String pkHex, String to, BigInt amount) {
    final c = _rp;
    return _send(pkHex, c, c.function('transfer'),
        [EthereumAddress.fromHex(to.trim()), amount]);
  }

  /// Natywny przelew POL (gaz Polygon) na dowolny adres.
  Future<String> sendNative(String pkHex, String to, BigInt amountWei) async {
    final cred = EthPrivateKey.fromHex(pkHex);
    return _client.sendTransaction(
      cred,
      Transaction(
          to: EthereumAddress.fromHex(to.trim()),
          value: EtherAmount.inWei(amountWei),
          gasPrice: await _gasPrice()),
      chainId: _chainId,
    );
  }

  // Cena gazu z RPC + 20% bezpiecznika — na Polygonie auto-estimate bywa zaniżony i tx utyka.
  Future<EtherAmount> _gasPrice() async {
    final gp = await _client.getGasPrice();
    return EtherAmount.inWei(gp.getInWei * BigInt.from(120) ~/ BigInt.from(100));
  }

  /// Walidacja adresu odbiorcy (checksum/format) bez rzucania w UI.
  static bool isValidAddress(String a) {
    try {
      EthereumAddress.fromHex(a.trim());
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<String> _send(String pkHex, DeployedContract c,
      ContractFunction fn, List<dynamic> params) async {
    final cred = EthPrivateKey.fromHex(pkHex);
    return _client.sendTransaction(
      cred,
      Transaction.callContract(
          contract: c, function: fn, parameters: params,
          gasPrice: await _gasPrice()),
      chainId: _chainId,
    );
  }

  /// Czekaj na receipt (polling). Zwraca true gdy tx sukces, false gdy revert,
  /// rzuca TimeoutException po przekroczeniu czasu.
  Future<bool> waitReceipt(String hash,
      {Duration timeout = const Duration(seconds: 90)}) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      final r = await _client.getTransactionReceipt(hash);
      if (r != null) return r.status ?? true;
      await Future.delayed(const Duration(seconds: 3));
    }
    throw Exception('Timeout — tx $hash niepotwierdzona');
  }

  void dispose() => _client.dispose();
}

// SensmosRewardPool — funkcje używane przez apkę (ERC-20 + pula w jednym kontrakcie).
const _rpAbi = '''
[
  {"type":"function","stateMutability":"view","name":"balanceOf",
   "inputs":[{"name":"account","type":"address"}],
   "outputs":[{"name":"","type":"uint256"}]},
  {"type":"function","stateMutability":"view","name":"allowance",
   "inputs":[{"name":"owner","type":"address"},{"name":"spender","type":"address"}],
   "outputs":[{"name":"","type":"uint256"}]},
  {"type":"function","stateMutability":"view","name":"claimedTotal",
   "inputs":[{"name":"user","type":"address"}],
   "outputs":[{"name":"","type":"uint256"}]},
  {"type":"function","stateMutability":"nonpayable","name":"approve",
   "inputs":[{"name":"spender","type":"address"},{"name":"amount","type":"uint256"}],
   "outputs":[{"name":"","type":"bool"}]},
  {"type":"function","stateMutability":"nonpayable","name":"transfer",
   "inputs":[{"name":"to","type":"address"},{"name":"amount","type":"uint256"}],
   "outputs":[{"name":"","type":"bool"}]},
  {"type":"function","stateMutability":"nonpayable","name":"deposit",
   "inputs":[{"name":"amount","type":"uint256"}],"outputs":[]},
  {"type":"function","stateMutability":"nonpayable","name":"claim",
   "inputs":[{"name":"cumulativeAmount","type":"uint256"},{"name":"proof","type":"bytes32[]"}],
   "outputs":[]}
]
''';
