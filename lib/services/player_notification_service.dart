import 'dart:async';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

class PlayerNotificationService {
  static final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  static StreamSubscription<QuerySnapshot>? _tournamentsSub;

  /// بدء الاستماع الموحد
  /// ملاحظة: تحديثات الحجوزات العادية (قبول/رفض) لا تحتاج نافذة منبثقة —
  /// يكفيها الدائرة (Badge) وتلوين الكارت بتبويب "حجوزاتي" (يرجع طبيعي بالضغط عليه).
  /// هذا الاستماع مخصص فقط لإشعارات البطولات (طرد/تحديد موعد) وقبول التحديات.
  static void listen(BuildContext context, String userPhone) {
    stop(); // إلغاء أي استماع سابق لتجنب التكرار

    _tournamentsSub = _firestore
        .collection('notifications')
        .where('userPhone', isEqualTo: userPhone)
        .where('seen', isEqualTo: false)
        .snapshots()
        .listen((snapshot) {
      for (var doc in snapshot.docs) {
        final data = doc.data();
        if (!context.mounted) return;
        _showTournamentNotificationDialog(context, doc.reference, data);
      }
    });
  }

  /// إيقاف الاستماع عند مغادرة الشاشة أو تسجيل الخروج
  static void stop() {
    _tournamentsSub?.cancel();
    _tournamentsSub = null;
  }

  static void _showTournamentNotificationDialog(
    BuildContext context,
    DocumentReference docRef,
    Map<String, dynamic> data,
  ) {
    final type = data['type'] ?? '';
    final title = data['title'] ?? 'إشعار بطولة';
    final tournamentName = data['tournamentName'] ?? 'البطولة';
    final reason = data['reason'] ?? '';
    final isRemoval = type == 'tournament_removal';
    final isChallengeAccepted = type == 'challenge_accepted';
    final opponentTeamName = data['opponentTeamName'] ?? 'فريق منافس';
    final pitchNameForChallenge = data['pitchName'] ?? 'الملعب';
    final matchDate = data['matchDate'] ?? '';
    final matchTime = data['matchTime'] ?? '';

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => Directionality(
        textDirection: ui.TextDirection.rtl,
        child: AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
          title: Row(
            children: [
              Icon(
                isRemoval
                    ? Icons.warning_rounded
                    : (isChallengeAccepted ? Icons.sports_kabaddi_rounded : Icons.emoji_events_rounded),
                color: isRemoval ? Colors.red : (isChallengeAccepted ? Colors.deepOrange : Colors.amber.shade800),
                size: 24,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  title,
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.bold,
                    color: isRemoval ? Colors.red : const Color(0xFF0F172A),
                  ),
                ),
              ),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                isChallengeAccepted
                    ? 'قبل فريق ($opponentTeamName) تحديك بملعب ($pitchNameForChallenge). تم تثبيت الحجز رسمياً.'
                    : (isRemoval
                        ? 'تم استبعاد فريقك من بطولة ($tournamentName).'
                        : 'تم تحديد موعد رسمي لمباراتكم القادمة في ($tournamentName).'),
                style: const TextStyle(fontSize: 13, height: 1.4),
              ),
              if (isChallengeAccepted && matchDate.toString().isNotEmpty) ...[
                const SizedBox(height: 10),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: Colors.deepOrange.shade50,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: Colors.deepOrange.shade100),
                  ),
                  child: Text(
                    'الموعد: $matchDate  •  $matchTime',
                    style: TextStyle(fontSize: 12, color: Colors.deepOrange.shade900, fontWeight: FontWeight.bold),
                  ),
                ),
              ],
              if (isRemoval && reason.toString().isNotEmpty) ...[
                const SizedBox(height: 10),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: Colors.red.shade50,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: Colors.red.shade200),
                  ),
                  child: Text(
                    'السبب: $reason',
                    style: TextStyle(fontSize: 12, color: Colors.red.shade900, fontWeight: FontWeight.bold),
                  ),
                ),
              ],
            ],
          ),
          actions: [
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: isRemoval ? Colors.red.shade700 : const Color(0xFF1B5E20),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              ),
              onPressed: () async {
                await docRef.update({'seen': true});
                if (ctx.mounted) Navigator.pop(ctx);
              },
              child: const Text('تم الاطلاع', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
            ),
          ],
        ),
      ),
    );
  }
}
