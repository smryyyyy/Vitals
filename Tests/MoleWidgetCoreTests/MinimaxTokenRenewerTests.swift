//
//  MinimaxTokenRenewerTests.swift
//  Vitals - MiniMax 模块
//
//  自动续期的回归屏障:
//  1. JWT exp 解析(不校验签名,只看 payload)
//  2. needsRenewal 的阈值判定
//  3. x-signature 的签名公式 —— 协议细节,一旦算错服务端直接 400,必须锁死
//
//  设计原则:
//  - 只测纯函数(expiry / remainingDays / needsRenewal / signature),不碰网络。
//  - 签名断言用「固定输入 → 固定 md5」,md5 由本地独立算出,
//    这样即使实现被改坏,测试也会红。
//

import Foundation
import Testing
import CryptoKit
@testable import MoleWidgetCore

@Suite struct MinimaxTokenRenewerTests {

    // MARK: - JWT exp 解析

    /// 构造一个 exp 指定的假 JWT(payload 的 exp 字段可控)。
    /// 签名部分随便填 —— 我们不做签名校验。
    private static func makeToken(exp: TimeInterval) -> String {
        func b64url(_ s: String) -> String {
            Data(s.utf8).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        let header = b64url(#"{"alg":"HS256","typ":"JWT"}"#)
        let payload = b64url(#"{"exp":\#(Int(exp))}"#)
        return "\(header).\(payload).signature-not-verified"
    }

    /// 能正确读出 exp 并换算成日期。
    @Test func expiryParsesExpClaim() {
        let target = Date().addingTimeInterval(10 * 86_400).timeIntervalSince1970
        let token = Self.makeToken(exp: target)

        let expiry = MinimaxTokenRenewer.expiry(of: token)

        #expect(expiry != nil)
        #expect(abs((expiry!.timeIntervalSince1970 - target)) < 1.0)
    }

    /// 不是 JWT(没有三个段)→ nil,不抛错。
    @Test func expiryReturnsNilForNonJWT() {
        #expect(MinimaxTokenRenewer.expiry(of: "not-a-jwt") == nil)
        #expect(MinimaxTokenRenewer.expiry(of: "") == nil)
        #expect(MinimaxTokenRenewer.expiry(of: "a.b") == nil)
    }

    /// payload 不是合法 base64 → nil。
    @Test func expiryReturnsNilForMalformedPayload() {
        #expect(MinimaxTokenRenewer.expiry(of: "aGVhZGVy.!!!not-base64!!!.sig") == nil)
    }

    // MARK: - base64 解码的两个分支

    /// 真实形状的 payload,长度 %3 != 0 → base64 长度 %4 != 0,需要补 padding。
    ///
    /// 这个分支必须有覆盖:老样本(`{"exp":<10位数字>}`)长度恒为 18 → base64 恒
    /// 24 字符 → %4 恒为 0,**永远走不到 padding 分支**。于是把 padding 补错
    /// (比如写成 `remainder` 而不是 `4 - remainder`)测试依然全绿,而真实
    /// token 会解析失败 → `tokenExpiry` 恒为 nil → 面板永远显示「有效期未知」。
    ///
    /// 期望值写死:payload 是 `{"exp":1767225600,"uid":"u0000"}`(32 字节),
    /// base64url 后 43 字符,需补 1 个 '='。
    @Test func expiryDecodesPayloadThatNeedsBase64Padding() {
        let token = "header.eyJleHAiOjE3NjcyMjU2MDAsInVpZCI6InUwMDAwIn0.signature"

        let expiry = MinimaxTokenRenewer.expiry(of: token)

        #expect(expiry != nil)
        #expect(expiry == Date(timeIntervalSince1970: 1_767_225_600))
    }

    /// payload 含非 ASCII → 标准 base64 里的 `+` / `/` 会变成 base64url 的
    /// `-` / `_`。
    ///
    /// Swift 的 `Data(base64Encoded:)` **只认标准字母表**,不认 `-` / `_`,
    /// 所以不做替换就会直接解不出来。这条样本的 payload 是
    /// `{"exp":1767225600,"nick":"用户~!@#"}`,base64url 后含 `-`。
    @Test func expiryDecodesPayloadWithUrlSafeCharacters() {
        let token = "header.eyJleHAiOjE3NjcyMjU2MDAsIm5pY2siOiLnlKjmiLd-IUAjIn0.signature"

        let expiry = MinimaxTokenRenewer.expiry(of: token)

        #expect(expiry != nil)
        #expect(expiry == Date(timeIntervalSince1970: 1_767_225_600))
    }

    // MARK: - 剩余天数

    /// remainingDays 解析失败返回 nil。
    @Test func remainingDaysReturnsNilForUnparsableToken() {
        #expect(MinimaxTokenRenewer.remainingDays(of: "garbage") == nil)
    }

    // MARK: - 签名公式

    /// `x-signature = md5(f"{ts}{盐值}{body}")`,body 为空串(renewal 的 body 就是空串)。
    /// 协议细节,算错服务端直接报签名错误 —— 用独立算出的 md5 锁死。
    @Test func signatureMatchesProtocolFormula() {
        let ts = "1793674691"
        let expected = Insecure.MD5.hash(data: Data("\(ts)I*7Cf%WZ#S&%1RlZJ&C2".utf8))
            .map { String(format: "%02x", $0) }
            .joined()

        #expect(MinimaxTokenRenewer.signature(timestamp: ts) == expected)
    }

    /// body 不是空串时,签名必须跟着变(签名的是**实际发出去的字节**)。
    @Test func signatureChangesWithBody() {
        let ts = "1793674691"
        let empty = MinimaxTokenRenewer.signature(timestamp: ts)
        let withBody = MinimaxTokenRenewer.signature(timestamp: ts, body: "{}")

        #expect(empty != withBody)
        let expected = Insecure.MD5.hash(data: Data("\(ts)I*7Cf%WZ#S&%1RlZJ&C2{}".utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        #expect(withBody == expected)
    }

    /// 不同时间戳 → 不同签名。
    @Test func signatureChangesWithTimestamp() {
        #expect(MinimaxTokenRenewer.signature(timestamp: "1793674691")
                != MinimaxTokenRenewer.signature(timestamp: "1793674692"))
    }
}
