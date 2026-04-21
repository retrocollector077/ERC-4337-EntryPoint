// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

/**
 * @dev Storage layout for ERC721A Initializable support.
 * Mirrors OpenZeppelin's Initializable storage slot pattern.
 */
library ERC721A__InitializableStorage {
    // keccak256(abi.encode(uint256(keccak256("ERC721A.initializable.storage")) - 1)) & ~uint256(0xff)
    bytes32 internal constant STORAGE_SLOT = 0x7fe9c947d0c80739d268f8b6a82cbdf2828b0481219777084ff57c4b6213b6400;

    struct Layout {
        /**
         * @dev Indicates that the contract has been initialized.
         */
        bool _initialized;

        /**
         * @dev Indicates that the contract is in the process of being initialized.
         */
        bool _initializing;
    }

    /**
     * @dev Returns a pointer to the storage layout.
     */
    function layout() internal pure returns (Layout storage l) {
        bytes32 slot = STORAGE_SLOT;
        assembly {
            l.slot := slot
        }
    }
}