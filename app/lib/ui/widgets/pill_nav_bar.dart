import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme.dart';

class NavItem {
  final IconData icon;
  final IconData selectedIcon;
  final String label;
  final bool dot; // a red dot: something new on this tab
  const NavItem(this.icon, this.selectedIcon, this.label, {this.dot = false});
}

/// The bottom bar: a soft pill slides behind the selected tab and its icon pops.
class PillNavBar extends StatelessWidget {
  final int index;
  final ValueChanged<int> onTap;
  final List<NavItem> items;
  const PillNavBar({super.key, required this.index, required this.onTap, required this.items});

  @override
  Widget build(BuildContext context) {
    final still = MediaQuery.of(context).disableAnimations;
    final move = still ? Duration.zero : const Duration(milliseconds: 380);
    final rtl = Directionality.of(context) == TextDirection.rtl;
    return DecoratedBox(
      decoration: const BoxDecoration(color: kSurface, border: Border(top: BorderSide(color: Color(0x14FFFFFF)))),
      child: SafeArea(
        top: false,
        child: MediaQuery.withClampedTextScaling(
          minScaleFactor: 1,
          maxScaleFactor: 1.15,
          child: SizedBox(
            height: 66,
            child: LayoutBuilder(builder: (context, box) {
              final w = box.maxWidth / items.length;
              final slot = rtl ? items.length - 1 - index : index;
              return Stack(children: [
                AnimatedPositioned(
                  duration: move,
                  curve: Curves.easeOutCubic,
                  left: slot * w + 6,
                  top: 6,
                  width: w - 12,
                  height: 54,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: kAccent.withValues(alpha: 0.2),
                      borderRadius: BorderRadius.circular(18),
                      border: Border.all(color: kAccent.withValues(alpha: 0.25)),
                    ),
                  ),
                ),
                Row(children: [
                  for (var i = 0; i < items.length; i++)
                    Expanded(
                      child: _Item(
                        item: items[i],
                        selected: i == index,
                        still: still,
                        onTap: () {
                          if (i != index) HapticFeedback.selectionClick();
                          onTap(i);
                        },
                      ),
                    ),
                ]),
              ]);
            }),
          ),
        ),
      ),
    );
  }
}

class _Item extends StatelessWidget {
  final NavItem item;
  final bool selected;
  final bool still;
  final VoidCallback onTap;
  const _Item({required this.item, required this.selected, required this.still, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Semantics(
      button: true,
      selected: selected,
      label: item.dot ? '${item.label}, new' : item.label,
      excludeSemantics: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            AnimatedScale(
              scale: selected ? 1.14 : 1,
              duration: still ? Duration.zero : const Duration(milliseconds: 320),
              curve: Curves.easeOutBack,
              child: Stack(clipBehavior: Clip.none, children: [
                Icon(selected ? item.selectedIcon : item.icon, size: 24, color: selected ? kAccent : t.colorScheme.onSurfaceVariant),
                if (item.dot)
                  Positioned(
                    right: -3,
                    top: -2,
                    child: Container(width: 10, height: 10, decoration: BoxDecoration(color: const Color(0xFFFF5C6C), shape: BoxShape.circle, border: Border.all(color: kSurface, width: 1.6))),
                  ),
              ]),
            ),
            const SizedBox(height: 3),
            AnimatedDefaultTextStyle(
              duration: still ? Duration.zero : const Duration(milliseconds: 200),
              style: TextStyle(fontFamily: kFontFamily, fontSize: 11.5, fontWeight: FontWeight.w600, color: selected ? t.colorScheme.onSurface : t.colorScheme.onSurfaceVariant),
              child: Text(item.label, maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
          ]),
        ),
      ),
    );
  }
}
