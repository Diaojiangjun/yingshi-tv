import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/legal/agreement_providers.dart';
import '../../../core/legal/agreement_terms.dart';
import '../../theme/app_icon_assets.dart';
import '../../theme/app_palette.dart';
import '../../theme/app_tokens.dart';
import 'app_dialog.dart';

/// 首启遮罩：没同意条款之前挡住整个应用。
///
/// 刻意不用 `showDialog`：路由可以被 PopScope / Esc / 代码 pop 掉，
/// 而这份确认必须在用户点按钮之前一直存在。挂成 MaterialApp.builder
/// 里的一层，就是最直接的「不可关闭」。
class AgreementGuard extends ConsumerStatefulWidget {
  const AgreementGuard({super.key});

  @override
  ConsumerState<AgreementGuard> createState() => _AgreementGuardState();
}

class _AgreementGuardState extends ConsumerState<AgreementGuard> {
  late bool _accepted;

  @override
  void initState() {
    super.initState();
    _accepted = ref.read(agreementInitialProvider);
  }

  @override
  Widget build(BuildContext context) {
    if (_accepted) return const SizedBox.shrink();
    return Stack(
      children: [
        const ModalBarrier(dismissible: false, color: Color(0xD9000000)),
        Material(
          type: MaterialType.transparency,
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: AgreementCard(onAccept: _accept),
            ),
          ),
        ),
      ],
    );
  }

  void _accept() {
    // 先放行再落盘：写文件失败不该把用户锁在协议页里，
    // 代价只是下次启动再确认一次。
    setState(() => _accepted = true);
    unawaited(_persist());
  }

  Future<void> _persist() async {
    try {
      await ref.read(agreementStoreProvider).accept();
    } catch (error) {
      debugPrint('[yingshi-tv] 协议同意状态保存失败: $error');
    }
  }
}

/// 只读查看（设置 → 关于）。与首启遮罩共用同一份卡片，避免两处文案漂移。
Future<void> showAgreementTermsDialog(BuildContext context) {
  return showAppDialog<void>(
    context: context,
    barrierLabel: '关闭用户协议与免责声明',
    builder: (dialogContext) => Dialog(
      backgroundColor: Colors.transparent,
      elevation: 0,
      insetPadding: const EdgeInsets.all(32),
      child: AgreementCard(
        onClose: () => Navigator.of(dialogContext).pop(),
      ),
    ),
  );
}

class AgreementCard extends StatelessWidget {
  const AgreementCard({super.key, this.onAccept, this.onClose});

  final VoidCallback? onAccept;
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final accepting = onAccept != null;
    return ConstrainedBox(
      constraints: BoxConstraints(
        maxWidth: 620,
        maxHeight: MediaQuery.of(context).size.height * 0.84,
      ),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: palette.raised,
          borderRadius: BorderRadius.circular(AppRadii.lg),
          border: Border.all(color: palette.border),
          boxShadow: const [
            BoxShadow(color: Color(0x66000000), blurRadius: 28, offset: Offset(0, 10)),
          ],
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(32, 28, 32, 22),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: Image.asset(
                  appIconAsset,
                  width: 52,
                  height: 52,
                  filterQuality: FilterQuality.high,
                ),
              ),
              const SizedBox(height: 14),
              Text(
                AgreementTerms.title,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: AppType.h2,
                  fontWeight: FontWeight.bold,
                  color: palette.textTitle,
                ),
              ),
              const SizedBox(height: 18),
              Flexible(
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        AgreementTerms.welcome,
                        style: TextStyle(
                          fontSize: AppType.body,
                          height: 1.7,
                          color: palette.textBody,
                        ),
                      ),
                      for (var i = 0; i < AgreementTerms.clauses.length; i++)
                        _Clause(index: i + 1, text: AgreementTerms.clauses[i]),
                      const SizedBox(height: 16),
                      Text(
                        AgreementTerms.footnote,
                        style: TextStyle(
                          fontSize: AppType.caption,
                          height: 1.6,
                          color: palette.textDim,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 20),
              Align(
                alignment: Alignment.centerRight,
                child: ElevatedButton(
                  key: const ValueKey('agreement-accept'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: palette.accent,
                    foregroundColor: Theme.of(context).colorScheme.onPrimary,
                    padding: const EdgeInsets.symmetric(
                        horizontal: 26, vertical: 15),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(AppRadii.sm),
                    ),
                  ),
                  onPressed: accepting ? onAccept : onClose,
                  child: Text(
                    accepting
                        ? AgreementTerms.acceptLabel
                        : AgreementTerms.closeLabel,
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Clause extends StatelessWidget {
  const _Clause({required this.index, required this.text});

  final int index;
  final String text;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Padding(
      padding: const EdgeInsets.only(top: 14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 22,
            child: Text(
              '$index.',
              style: TextStyle(
                fontSize: AppType.body,
                height: 1.7,
                fontWeight: FontWeight.w600,
                color: palette.accentInk,
              ),
            ),
          ),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                fontSize: AppType.body,
                height: 1.7,
                color: palette.textMain,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
