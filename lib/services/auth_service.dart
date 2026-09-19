import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:shared_preferences/shared_preferences.dart';

class AuthResult {
  final bool success;
  final String? errorMessage;
  final String? role;
  final String? pitchName;
  final String? phone;
  final bool needsProfileCompletion;
  final String? googleName;
  final String? firebaseUid;

  AuthResult({
    required this.success,
    this.errorMessage,
    this.role,
    this.pitchName,
    this.phone,
    this.needsProfileCompletion = false,
    this.googleName,
    this.firebaseUid,
  });
}

class AuthService {
  static final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  static final FirebaseAuth _auth = FirebaseAuth.instance;
  static final GoogleSignIn _googleSignIn = GoogleSignIn();

  /// Firebase Auth يتطلب بريد إلكتروني صيغة صحيحة، فنبني بريد اصطناعي من رقم الهاتف
  /// (المستخدم يبقى يدخل رقم الهاتف والرمز السري فقط زي ما هو، بدون أي تغيير بالواجهة)
  static String _syntheticEmail(String phone) {
    final cleanPhone = phone.replaceAll(RegExp(r'[^\d]'), '');
    return '$cleanPhone@malaabi.app';
  }

  static String _mapFirebaseError(String code) {
    switch (code) {
      case 'user-not-found':
        return 'الحساب غير موجود، يرجى إنشاء حساب جديد';
      case 'wrong-password':
      case 'invalid-credential':
        return 'الرمز السري غير صحيح';
      case 'invalid-email':
        return 'رقم الهاتف غير صالح';
      case 'user-disabled':
        return 'تم تعطيل هذا الحساب، تواصل مع الدعم';
      case 'too-many-requests':
        return 'محاولات كثيرة متتالية، يرجى المحاولة لاحقاً';
      case 'network-request-failed':
        return 'تحقق من اتصال الإنترنت وحاول مجدداً';
      case 'email-already-in-use':
        return 'رقم الهاتف مسجل مسبقاً، يرجى تسجيل الدخول';
      case 'weak-password':
        return 'الرمز السري ضعيف، اختر رمزاً أقوى (6 خانات على الأقل)';
      default:
        return 'حدث خطأ أثناء المصادقة، حاول مجدداً';
    }
  }

  static Future<AuthResult> login(String phone, String password) async {
    try {
      await _auth.signInWithEmailAndPassword(
        email: _syntheticEmail(phone),
        password: password,
      );

      final doc = await _firestore.collection('users').doc(phone).get();
      if (!doc.exists) {
        // الحساب موجود بـ Firebase Auth بس بيانات ناقصة بـ Firestore (حالة نادرة)
        await _auth.signOut();
        return AuthResult(success: false, errorMessage: 'تعذر إيجاد بيانات الحساب، تواصل مع الدعم');
      }

      final data = doc.data() as Map<String, dynamic>;
      final role = data['role'] ?? 'player';
      final pName = data['pitchName'] ?? '';

      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('phone', phone);
      await prefs.setString('role', role);
      if (role == 'owner') await prefs.setString('pitchName', pName);

      return AuthResult(success: true, role: role, pitchName: pName);
    } on FirebaseAuthException catch (e) {
      return AuthResult(success: false, errorMessage: _mapFirebaseError(e.code));
    } catch (e) {
      return AuthResult(success: false, errorMessage: 'حدث خطأ: $e');
    }
  }

  static Future<AuthResult> register({
    required bool isOwner,
    required String phone,
    required String password,
    required String name,
    required String gov,
    required String area,
    String? teamName,
    String? pitchName,
    double? hourlyRate,
    String? addressDetails,
    String? pitchType,
    String? surfaceType,
  }) async {
    try {
      final existingDoc = await _firestore.collection('users').doc(phone).get();
      if (existingDoc.exists) {
        return AuthResult(success: false, errorMessage: 'رقم الهاتف مسجل مسبقاً، يرجى تسجيل الدخول');
      }

      if (isOwner && (pitchName == null || pitchName.isEmpty)) {
        return AuthResult(success: false, errorMessage: 'يرجى كتابة اسم الملعب');
      }

      if (password.length < 6) {
        return AuthResult(success: false, errorMessage: 'الرمز السري يجب أن يكون 6 خانات على الأقل');
      }

      // 1. إنشاء حساب حقيقي بـ Firebase Authentication (كلمة المرور تُشفَّر وتُدار من Firebase مباشرة)
      await _auth.createUserWithEmailAndPassword(
        email: _syntheticEmail(phone),
        password: password,
      );

      final role = isOwner ? 'owner' : 'player';
      final firebaseUid = _auth.currentUser?.uid ?? '';

      // 2. إنشاء وثيقة المستخدم بـ Firestore (بدون تخزين كلمة المرور إطلاقاً)
      try {
        await _firestore.collection('users').doc(phone).set({
          'phone': phone,
          'name': name.isEmpty ? 'مستخدم' : name,
          'role': role,
          'firebaseUid': firebaseUid,
          'loginMethod': 'password',
          'pitchName': isOwner ? pitchName : null,
          'teamName': !isOwner ? teamName : null,
          'governorate': gov,
          'area': area,
          'createdAt': FieldValue.serverTimestamp(),
        });

        // 3. إنشاء وثيقة الملعب (للمالك فقط)
        if (isOwner && pitchName != null) {
          await _firestore.collection('pitches').doc(pitchName).set({
            'name': pitchName,
            'ownerPhone': phone,
            'phone': phone,
            'hourlyRate': hourlyRate ?? 25000.0,
            'governorate': gov,
            'area': area,
            'addressDetails': addressDetails,
            'pitchType': pitchType,
            'surfaceType': surfaceType,
            'description': 'ملعب معتمد ومجهز بالإنارة والخدمات',
            'createdAt': FieldValue.serverTimestamp(),
          }, SetOptions(merge: true));
        }
      } catch (e) {
        // لو فشل حفظ بيانات Firestore بعد نجاح إنشاء الحساب، نلغي حساب Auth لتفادي حساب يتيم
        await _auth.currentUser?.delete();
        return AuthResult(success: false, errorMessage: 'حدث خطأ أثناء حفظ بيانات الحساب، حاول مجدداً');
      }

      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('phone', phone);
      await prefs.setString('role', role);
      if (isOwner && pitchName != null) await prefs.setString('pitchName', pitchName);

      return AuthResult(success: true, role: role, pitchName: pitchName);
    } on FirebaseAuthException catch (e) {
      return AuthResult(success: false, errorMessage: _mapFirebaseError(e.code));
    } catch (e) {
      return AuthResult(success: false, errorMessage: 'حدث خطأ: $e');
    }
  }

  /// تسجيل الدخول أو الربط بحساب Google
  /// - إذا الحساب موجود مسبقاً (مربوط بـ firebaseUid) → يرجع بياناته مباشرة
  /// - إذا حساب جديد → يرجع needsProfileCompletion=true عشان نطلب رقم الهاتف والدور
  static Future<AuthResult> signInWithGoogle() async {
    try {
      final googleUser = await _googleSignIn.signIn();
      if (googleUser == null) {
        return AuthResult(success: false, errorMessage: 'تم إلغاء تسجيل الدخول');
      }

      final googleAuth = await googleUser.authentication;
      final credential = GoogleAuthProvider.credential(
        accessToken: googleAuth.accessToken,
        idToken: googleAuth.idToken,
      );

      final userCred = await _auth.signInWithCredential(credential);
      final firebaseUser = userCred.user;
      if (firebaseUser == null) {
        return AuthResult(success: false, errorMessage: 'تعذر تسجيل الدخول عبر Google');
      }

      // هل هذا الحساب مربوط مسبقاً بملف مستخدم موجود؟
      final query = await _firestore
          .collection('users')
          .where('firebaseUid', isEqualTo: firebaseUser.uid)
          .limit(1)
          .get();

      if (query.docs.isNotEmpty) {
        final data = query.docs.first.data();
        final phone = (data['phone'] ?? query.docs.first.id).toString();
        final role = data['role'] ?? 'player';
        final pName = data['pitchName'] ?? '';

        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('phone', phone);
        await prefs.setString('role', role);
        if (role == 'owner') await prefs.setString('pitchName', pName);

        return AuthResult(success: true, role: role, pitchName: pName, phone: phone);
      }

      // حساب Google جديد كلياً بهذا التطبيق - يحتاج يكمل بياناته (رقم الهاتف والدور)
      return AuthResult(
        success: false,
        needsProfileCompletion: true,
        googleName: firebaseUser.displayName,
        firebaseUid: firebaseUser.uid,
      );
    } on FirebaseAuthException catch (e) {
      return AuthResult(success: false, errorMessage: _mapFirebaseError(e.code));
    } catch (e) {
      return AuthResult(success: false, errorMessage: 'حدث خطأ أثناء تسجيل الدخول عبر Google');
    }
  }

  /// إكمال إنشاء الملف الشخصي بعد أول تسجيل دخول ناجح بـ Google (يحتاج رقم هاتف ودور)
  static Future<AuthResult> completeGoogleRegistration({
    required bool isOwner,
    required String phone,
    required String firebaseUid,
    required String name,
    required String gov,
    required String area,
    String? teamName,
    String? pitchName,
    double? hourlyRate,
    String? addressDetails,
    String? pitchType,
    String? surfaceType,
  }) async {
    try {
      final existingDoc = await _firestore.collection('users').doc(phone).get();
      if (existingDoc.exists) {
        return AuthResult(success: false, errorMessage: 'رقم الهاتف مسجل مسبقاً بحساب آخر، يرجى تسجيل الدخول بالطريقة الأصلية');
      }

      if (isOwner && (pitchName == null || pitchName.isEmpty)) {
        return AuthResult(success: false, errorMessage: 'يرجى كتابة اسم الملعب');
      }

      final role = isOwner ? 'owner' : 'player';

      await _firestore.collection('users').doc(phone).set({
        'phone': phone,
        'name': name.isEmpty ? 'مستخدم' : name,
        'role': role,
        'firebaseUid': firebaseUid,
        'loginMethod': 'google',
        'pitchName': isOwner ? pitchName : null,
        'teamName': !isOwner ? teamName : null,
        'governorate': gov,
        'area': area,
        'createdAt': FieldValue.serverTimestamp(),
      });

      if (isOwner && pitchName != null) {
        await _firestore.collection('pitches').doc(pitchName).set({
          'name': pitchName,
          'ownerPhone': phone,
          'phone': phone,
          'hourlyRate': hourlyRate ?? 25000.0,
          'governorate': gov,
          'area': area,
          'addressDetails': addressDetails,
          'pitchType': pitchType,
          'surfaceType': surfaceType,
          'description': 'ملعب معتمد ومجهز بالإنارة والخدمات',
          'createdAt': FieldValue.serverTimestamp(),
        }, SetOptions(merge: true));
      }

      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('phone', phone);
      await prefs.setString('role', role);
      if (isOwner && pitchName != null) await prefs.setString('pitchName', pitchName);

      return AuthResult(success: true, role: role, pitchName: pitchName, phone: phone);
    } catch (e) {
      return AuthResult(success: false, errorMessage: 'حدث خطأ أثناء حفظ بيانات الحساب، حاول مجدداً');
    }
  }

  /// تسجيل الخروج من كل من Firebase Auth و Google (يستخدمها logout_dialog.dart)
  static Future<void> signOutAll() async {
    await _googleSignIn.signOut();
    await _auth.signOut();
  }
}
