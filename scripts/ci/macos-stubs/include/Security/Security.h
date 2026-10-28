// Public C ABI used by github.com/tailscale/certstore at 3638fb84b77d.
// No implementation, SDK contents, or unreferenced API surface is included.
#pragma once
#include <CoreFoundation/CoreFoundation.h>
typedef int32_t OSStatus;
// Security handles are opaque pointers, just like CoreFoundation handles.
// Using the same named pointer keeps cgo's explicit CFTypeRef casts valid
// while preserving the platform ABI (all handles are one pointer wide).
typedef struct __CFType *SecCertificateRef;
typedef struct __CFType *SecIdentityRef;
typedef struct __CFType *SecKeyRef;
typedef struct __CFType *SecPolicyRef;
typedef struct __CFType *SecTrustRef;
typedef CFStringRef SecKeyAlgorithm;
enum { errSecSuccess = 0, errSecItemNotFound = -25300 };
extern OSStatus SecItemCopyMatching(CFDictionaryRef, CFTypeRef *);
extern OSStatus SecItemDelete(CFDictionaryRef);
extern OSStatus SecPKCS12Import(CFDataRef, CFDictionaryRef, CFArrayRef *);
extern OSStatus SecIdentityCopyCertificate(SecIdentityRef, SecCertificateRef *);
extern OSStatus SecIdentityCopyPrivateKey(SecIdentityRef, SecKeyRef *);
extern CFDataRef SecCertificateCopyData(SecCertificateRef);
extern SecPolicyRef SecPolicyCreateSSL(Boolean, CFStringRef);
extern OSStatus SecTrustCreateWithCertificates(CFTypeRef, CFTypeRef, SecTrustRef *);
extern bool SecTrustEvaluateWithError(SecTrustRef, CFErrorRef *);
extern CFArrayRef SecTrustCopyCertificateChain(SecTrustRef);
extern CFDataRef SecKeyCreateSignature(SecKeyRef, SecKeyAlgorithm, CFDataRef, CFErrorRef *);
extern const CFStringRef kSecClass, kSecClassIdentity, kSecReturnRef;
extern const CFStringRef kSecMatchLimit, kSecMatchLimitAll, kSecMatchItemList;
extern const CFStringRef kSecImportExportPassphrase;
extern const SecKeyAlgorithm kSecKeyAlgorithmECDSASignatureDigestX962SHA256;
extern const SecKeyAlgorithm kSecKeyAlgorithmECDSASignatureDigestX962SHA384;
extern const SecKeyAlgorithm kSecKeyAlgorithmECDSASignatureDigestX962SHA512;
extern const SecKeyAlgorithm kSecKeyAlgorithmRSASignatureDigestPKCS1v15SHA256;
extern const SecKeyAlgorithm kSecKeyAlgorithmRSASignatureDigestPKCS1v15SHA384;
extern const SecKeyAlgorithm kSecKeyAlgorithmRSASignatureDigestPKCS1v15SHA512;
extern const SecKeyAlgorithm kSecKeyAlgorithmRSASignatureDigestPSSSHA256;
extern const SecKeyAlgorithm kSecKeyAlgorithmRSASignatureDigestPSSSHA384;
extern const SecKeyAlgorithm kSecKeyAlgorithmRSASignatureDigestPSSSHA512;
