// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

/**
 * @title ERC721AStorage
 * @dev Storage layout for ERC721A upgradeable contracts.
 *      This library ensures upgrade-safe storage by isolating
 *      struct layout in a known storage slot.
 */
library ERC721AStorage {
    // keccak256(abi.encode("ERC721A.storage")) - 1 & ~0xff
    bytes32 internal constant STORAGE_SLOT = 0x6e7a0b0481219777084ff57c4b6213b5636e33a7146d2da52a06480396c02000;

    struct TokenApprovalRef {
        address value;
    }

    struct Layout {
        // =============================================================
        //                           TOKEN COUNTERS
        // =============================================================
        uint256 _currentIndex;
        uint256 _burnCounter;

        // =============================================================
        //                        TOKEN NAME & SYMBOL
        // =============================================================
        string _name;
        string _symbol;

        // =============================================================
        //      MAPPING: TOKEN ID → OWNERSHIP DATA
        // =============================================================
        mapping(uint256 => uint256) _packedOwnerships;

        // =============================================================
        //      MAPPING: OWNER → ADDRESS DATA
        // =============================================================
        mapping(address => uint256) _packedAddressData;

        // =============================================================
        //      MAPPING: TOKEN ID → APPROVED ADDRESS
        // =============================================================
        mapping(uint256 => address) _tokenApprovals;

        // =============================================================
        //      MAPPING: OWNER → OPERATOR APPROVALS
        // =============================================================
        mapping(address => mapping(address => bool)) _operatorApprovals;
    }

    /**
     * @notice Returns the storage layout at the designated slot.
     */
    function layout() internal pure returns (Layout storage l) {
        bytes32 slot = STORAGE_SLOT;
        assembly {
            l.slot := slot
        }
    }
}