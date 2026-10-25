import Foundation

enum KaspaFeePolicy {
    static let minimumRelayFeePerGramSompi: UInt64 = 100
    static let normalizedTransientMassPerByte: UInt64 = 2

    static func minimumStandardFee(computeMass: UInt64, estimatedTransactionBytes: UInt64) -> UInt64 {
        let transientMass = estimatedTransactionBytes.saturatingMultiplied(by: normalizedTransientMassPerByte)
        let feeMass = max(computeMass, transientMass)
        return feeMass.saturatingMultiplied(by: minimumRelayFeePerGramSompi)
    }
}

private extension UInt64 {
    func saturatingMultiplied(by value: UInt64) -> UInt64 {
        let result = multipliedReportingOverflow(by: value)
        return result.overflow ? UInt64.max : result.partialValue
    }
}

// MARK: - Fee editor (moved from Cold Storage's send engine, 2026-10-24)

extension KaspaFeePolicy {
    /// Standard Schnorr signature script size (0x41 push + 64-byte sig + 0x01 sighash).
    private static let schnorrSigScriptLen: UInt64 = 66

    /// Transaction mass for a plain transfer (KaspaMass.kt port). Verified against Android's own
    /// cited real-world result: 1 input, two 34-byte outputs, no payload -> mass 2036.
    static func calculateMass(numInputs: Int, outputScriptLens: [Int], payloadSize: Int, sigOpCountPerInput: Int = 1) -> UInt64 {
        let totalSigScriptBytes = UInt64(numInputs) * schnorrSigScriptLen

        var byteSize: UInt64 = 2 // version (u16)
        byteSize += 8 // input count
        byteSize += UInt64(numInputs) * (36 + 8 + 8) + totalSigScriptBytes // outpoint + sigscript-len field + sequence, + actual sigscript bytes
        byteSize += 8 // output count

        var scriptPubKeyMass: UInt64 = 0
        for scriptLen in outputScriptLens {
            byteSize += 8 + 2 + 8 + UInt64(scriptLen) // value + scriptVersion + scriptLen + script
            scriptPubKeyMass += (2 + UInt64(scriptLen)) * 10
        }

        byteSize += 8  // lockTime
        byteSize += 20 // subnetworkId
        byteSize += 8  // gas
        byteSize += 32 // payload hash (fixed 32 bytes regardless of payload length)
        byteSize += 8  // payload length
        byteSize += UInt64(payloadSize)

        let sigOpMass = UInt64(numInputs) * UInt64(sigOpCountPerInput) * 1000
        let computeMass = byteSize * 1 + scriptPubKeyMass + sigOpMass

        // Post-"Toccata" RPC minimum-standard-fee policy: the real fee floor is
        // 100 sompi * max(computeMass, 2 * transactionByteSize), not compute mass alone.
        return max(computeMass, byteSize * 2)
    }

    /// fee = mass * max(networkMinimum, rate)
    static func calculateFee(mass: UInt64, rateSompiPerGram: UInt64) -> UInt64 {
        mass * max(rateSompiPerGram, minimumRelayFeePerGramSompi)
    }

    /// Reference mass (1 input, two standard 34-byte P2PK outputs) - used only to convert a
    /// user-entered total fee (KAS) into a sompi-per-gram rate in a send screen's fee editor.
    /// The real per-send mass can differ slightly by input count; Android uses this identical
    /// shortcut for the same conversion.
    static let referenceMassForFeeEditor: UInt64 = calculateMass(numInputs: 1, outputScriptLens: [34, 34], payloadSize: 0)
}
