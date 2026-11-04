import Foundation

extension KachatNames {

    // MARK: - Version-1 transaction model (rusty-kaspa a41a333, consensus/core/src/tx.rs)

    struct Outpoint: Equatable, Hashable {
        /// Transaction id, 32 bytes in hashing order (the hex string as written by the node).
        var txid: Data
        var index: UInt32
    }

    struct CovenantBinding: Equatable {
        var authorizingInput: UInt16
        var covenantId: Data
    }

    struct TxOutput: Equatable {
        var value: UInt64
        var scriptVersion: UInt16 = 0
        var script: Data
        var covenant: CovenantBinding?
    }

}
