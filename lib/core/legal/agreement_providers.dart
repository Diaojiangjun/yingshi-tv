import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'agreement_store.dart';

/// 协议接受状态：main.dart 启动时读完本地文件后用真实值 override。
final agreementStoreProvider =
    Provider<AgreementStore>((ref) => AgreementStore());

final agreementInitialProvider = Provider<bool>((ref) => false);
