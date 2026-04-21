// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

/**
 * @dev Base contract to aid in writing upgradeable contracts.
 * This replicates OpenZeppelin's Initializable but adapted for ERC721A.
 *
 * NOTE:
 *  - Proxied contracts do not run constructors.
 *  - Initialization must be done via an external `initialize()` function.
 *  - This contract prevents multiple initializations.
 */
abstract contract ERC721A__Initializable {
    /**
     * @dev Indicates that the contract has been initialized.
     */
    bool private _initialized;

    /**
     * @dev Indicates that the contract is in the process of being initialized.
     */
    bool private _initializing;

    /**
     * @dev Modifier to protect an initializer function from being invoked twice.
     */
    modifier initializer() {
        if (_initialized) revert AlreadyInitialized();

        bool isTopLevelCall = !_initializing;
        if (isTopLevelCall) {
            _initializing = true;
            _initialized = true;
        }
        _;
        if (isTopLevelCall) {
            _initializing = false;
        }
    }

    /**
     * @dev Modifier to protect functions so they can only be initialized once,
     * or only while initializing.
     */
    modifier onlyInitializing() {
        if (!_initializing) revert NotInitializing();
        _;
    }

    /**
     * @dev Error thrown when attempting to reinitialize.
     */
    error AlreadyInitialized();

    /**
     * @dev Error thrown when a function requires initializing state.
     */
    error NotInitializing();
}