// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import './IERC721AUpgradeable.sol';
import {ERC721AStorage} from './ERC721AStorage.sol';
import './ERC721A__Initializable.sol';

/**
 * @dev ERC721AUpgradeable is a highly optimized upgradeable implementation
 * of ERC721 supporting batch minting and reduced gas for transfers.
 */
abstract contract ERC721AUpgradeable is IERC721AUpgradeable, ERC721A__Initializable {
    using ERC721AStorage for ERC721AStorage.Layout;

    function __ERC721A_init(string memory name_, string memory symbol_) internal onlyInitializing {
        ERC721AStorage.Layout storage layout = ERC721AStorage.layout();
        layout._name = name_;
        layout._symbol = symbol_;
        __ERC721A_init_unchained();
    }

    function __ERC721A_init_unchained() internal onlyInitializing {}

    // IERC165 support
    function supportsInterface(bytes4 interfaceId)
        public
        view
        virtual
        override
        returns (bool)
    {
        return
            interfaceId == type(IERC721AUpgradeable).interfaceId ||
            interfaceId == type(IERC721AQueryableUpgradeable).interfaceId ||
            super.supportsInterface(interfaceId);
    }

    // Token info
    function name() public view virtual override returns (string memory) {
        return ERC721AStorage.layout()._name;
    }

    function symbol() public view virtual override returns (string memory) {
        return ERC721AStorage.layout()._symbol;
    }

    function tokenURI(uint256 tokenId) public view virtual override returns (string memory) {
        _requireMinted(tokenId);
        string memory baseURI = _baseURI();
        return bytes(baseURI).length != 0 ? string(abi.encodePacked(baseURI, _toString(tokenId))) : '';
    }

    function _baseURI() internal view virtual returns (string memory) {
        return '';
    }

    // Internal minting
    function _mint(address to, uint256 quantity) internal virtual {
        ERC721AStorage.Layout storage layout = ERC721AStorage.layout();
        uint256 startTokenId = layout._currentIndex;
        if (to == address(0)) revert MintToZeroAddress();
        if (quantity == 0) revert MintZeroQuantity();

        _beforeTokenTransfers(address(0), to, startTokenId, quantity);

        // Update balances
        layout._packedAddressData[to] += quantity * ((1 << 64) | 1);

        // Ownership of first token
        layout._packedOwnerships[startTokenId] = _packOwnershipData(to, _nextInitializedFlag(quantity));

        uint256 updatedIndex = startTokenId;
        uint256 end = updatedIndex + quantity;

        do {
            emit Transfer(address(0), to, updatedIndex);
        } while (++updatedIndex < end);

        layout._currentIndex = updatedIndex;

        _afterTokenTransfers(address(0), to, startTokenId, quantity);
    }

    // Transfer logic
    function transferFrom(address from, address to, uint256 tokenId) public virtual override {
        _transfer(from, to, tokenId);
    }

    function _transfer(address from, address to, uint256 tokenId) internal virtual {
        if (to == address(0)) revert TransferToZeroAddress();

        ERC721AStorage.Layout storage layout = ERC721AStorage.layout();
        uint256 prevOwnershipPacked = _packedOwnershipOf(tokenId);
        address owner = address(uint160(prevOwnershipPacked));

        if (owner != from) revert TransferFromIncorrectOwner();

        (address approvedAddress, ) = _getApprovedAddress(tokenId);
        if (!_isSenderApprovedOrOwner(approvedAddress, from, msg.sender))
            revert ApprovalCallerNotOwnerNorApproved();

        _beforeTokenTransfers(from, to, tokenId, 1);

        delete layout._tokenApprovals[tokenId];

        layout._packedAddressData[from] -= 1;
        layout._packedAddressData[to] += 1;

        layout._packedOwnerships[tokenId] = _packOwnershipData(to, _nextInitializedFlag(1));

        emit Transfer(from, to, tokenId);

        _afterTokenTransfers(from, to, tokenId, 1);
    }

    // Approvals
    function approve(address to, uint256 tokenId) public virtual override {
        address owner = ownerOf(tokenId);
        if (msg.sender != owner && !isApprovedForAll(owner, msg.sender))
            revert ApprovalCallerNotOwnerNorApproved();

        ERC721AStorage.layout()._tokenApprovals[tokenId] = to;
        emit Approval(owner, to, tokenId);
    }

    function getApproved(uint256 tokenId) public view virtual override returns (address) {
        _requireMinted(tokenId);
        return ERC721AStorage.layout()._tokenApprovals[tokenId];
    }

    // Internal helpers
    function _packedOwnershipOf(uint256 tokenId) internal view returns (uint256) {
        return ERC721AStorage.layout()._packedOwnerships[tokenId];
    }

    function ownerOf(uint256 tokenId) public view virtual override returns (address) {
        return address(uint160(_packedOwnershipOf(tokenId)));
    }

    function _requireMinted(uint256 tokenId) internal view {
        if (!_exists(tokenId)) revert OwnerQueryForNonexistentToken();
    }

    function _exists(uint256 tokenId) internal view returns (bool) {
        return tokenId < ERC721AStorage.layout()._currentIndex && ERC721AStorage.layout()._packedOwnerships[tokenId] != 0;
    }

    function _getApprovedAddress(uint256 tokenId) internal view returns (address, uint256) {
        return (ERC721AStorage.layout()._tokenApprovals[tokenId], tokenId);
    }

    function _isSenderApprovedOrOwner(address approved, address owner, address sender) internal pure returns (bool) {
        return sender == owner || sender == approved;
    }

    function _packOwnershipData(address owner, uint256 flags) internal pure returns (uint256) {
        return uint256(uint160(owner)) | flags;
    }

    function _nextInitializedFlag(uint256 quantity) internal pure returns (uint256) {
        return quantity == 1 ? 1 << 224 : 0;
    }

    function _toString(uint256 value) internal pure returns (string memory) {
        assembly {
            let ptr := add(mload(0x40), 0x80)
            mstore(0x40, ptr)
            let end := ptr
            for { let temp := value } temp { temp := div(temp, 10) } {
                end := sub(end, 1)
                mstore8(end, add(48, mod(temp, 10)))
            }
            let len := sub(add(mload(0x40), 0x80), end)
            mstore(end, len)
            mstore(add(end, 32), len)
            mstore(0x40, add(add(end, 32), 0))
            return end
        }
    }
}