import 'package:flutter/material.dart';

/// Pure-Flutter shimmer placeholders shown while first-load data is still in
/// flight — no dependency, all theme-driven so they track the active theme.
///
/// A [Shimmer] wraps a subtree and sweeps a light band across every [Skeleton]
/// block inside it via a single shared [AnimationController] + [ShaderMask].
/// Compose page-shaped placeholders ([homeSkeleton], [detailSkeleton]) from
/// [Skeleton] boxes so a cold start reads as "the real screen, loading" rather
/// than a bare spinner.

/// A single grey placeholder block. Sized by [width]/[height]; the [Shimmer]
/// ancestor animates the sheen across it.
class Skeleton extends StatelessWidget {
  final double? width;
  final double height;
  final double radius;

  const Skeleton({
    super.key,
    this.width,
    this.height = 16,
    this.radius = 8,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(radius),
      ),
    );
  }
}

/// Sweeps a translucent highlight band across its subtree, left to right, on a
/// loop. Colors come from the theme so it works in light/dark/green/purple.
class Shimmer extends StatefulWidget {
  final Widget child;
  const Shimmer({super.key, required this.child});

  @override
  State<Shimmer> createState() => _ShimmerState();
}

class _ShimmerState extends State<Shimmer>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1200),
  )..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final base = Theme.of(context).colorScheme.surface;
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        return ShaderMask(
          blendMode: BlendMode.srcATop,
          shaderCallback: (bounds) {
            // A moving highlight: the band travels from off-screen left to
            // off-screen right as t goes 0→1.
            final t = _controller.value;
            final dx = bounds.width;
            return LinearGradient(
              begin: Alignment.centerLeft,
              end: Alignment.centerRight,
              colors: [
                base.withValues(alpha: 0.0),
                base.withValues(alpha: 0.55),
                base.withValues(alpha: 0.0),
              ],
              stops: const [0.35, 0.5, 0.65],
              transform: _SlideGradient(dx * (t * 2 - 1)),
            ).createShader(bounds);
          },
          child: child,
        );
      },
      child: widget.child,
    );
  }
}

/// Translates a gradient horizontally by [dx] logical pixels.
class _SlideGradient extends GradientTransform {
  final double dx;
  const _SlideGradient(this.dx);

  @override
  Matrix4? transform(Rect bounds, {TextDirection? textDirection}) =>
      Matrix4.translationValues(dx, 0, 0);
}

/// Just the transaction-rows placeholder — used on the detail page, where the
/// hero and spending summary already show real data and only the history is
/// still loading.
Widget txnRowsSkeleton() {
  return Shimmer(
    child: Column(
      children: [
        for (var i = 0; i < 7; i++) ...[
          Row(
            children: const [
              Skeleton(width: 38, height: 38, radius: 19),
              SizedBox(width: 12),
              Expanded(child: Skeleton(height: 14)),
              SizedBox(width: 12),
              Skeleton(width: 52, height: 14),
            ],
          ),
          const SizedBox(height: 20),
        ],
      ],
    ),
  );
}

/// Dashboard tab placeholder: the "updated" pill, meal-plan card, and a couple
/// of account hero cards.
Widget dashboardSkeleton() {
  return Shimmer(
    child: ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 140),
      children: const [
        Align(
          alignment: Alignment.centerRight,
          child: Skeleton(width: 96, height: 24, radius: 20),
        ),
        SizedBox(height: 20),
        Skeleton(height: 128, radius: 24),
        SizedBox(height: 20),
        Skeleton(height: 132, radius: 28),
        SizedBox(height: 12),
        Skeleton(height: 132, radius: 28),
      ],
    ),
  );
}

/// Analytics tab placeholder: summary card, chart card, and the stat row.
Widget analyticsSkeleton() {
  return Shimmer(
    child: ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 140),
      children: [
        const Skeleton(height: 132, radius: 24),
        const SizedBox(height: 16),
        const Skeleton(height: 236, radius: 24),
        const SizedBox(height: 16),
        Row(
          children: const [
            Expanded(child: Skeleton(height: 64, radius: 18)),
            SizedBox(width: 12),
            Expanded(child: Skeleton(height: 64, radius: 18)),
            SizedBox(width: 12),
            Expanded(child: Skeleton(height: 64, radius: 18)),
          ],
        ),
      ],
    ),
  );
}

/// Extras tab placeholder: two section-card bubbles.
Widget extrasSkeleton() {
  return Shimmer(
    child: ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 140),
      children: const [
        Skeleton(height: 160, radius: 24),
        SizedBox(height: 16),
        Skeleton(height: 130, radius: 24),
      ],
    ),
  );
}

/// Settings tab placeholder: three section-card bubbles (theme, logs, sign
/// out).
Widget settingsSkeleton() {
  return Shimmer(
    child: ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 140),
      children: const [
        Skeleton(height: 150, radius: 24),
        SizedBox(height: 16),
        Skeleton(height: 110, radius: 24),
        SizedBox(height: 16),
        Skeleton(height: 110, radius: 24),
      ],
    ),
  );
}

