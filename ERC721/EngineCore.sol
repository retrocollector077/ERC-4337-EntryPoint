// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {ERC721AUpgradeable} from "erc721a-upgradeable/ERC721AUpgradeable.sol";
import {IERC2981} from "@openzeppelin/contracts/interfaces/IERC2981.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";

// External interfaces
interface IMetadataRenderer {
    function tokenURI(uint256 tokenId) external view returns (string memory);
}
interface IRc77Oracle {
    function getSpotPrice() external view returns (uint256);
}
interface IAssetAuthorityRegistry {
    function registerAsset(address assetAddress, uint256 tokenId, uint256 vaultId, address owner) external;
}
interface IBTBBZVault {
    function depositNFT(address nft, uint256 tokenId) external returns (uint256 shares);
    function redeemShares(uint256 shares) external returns (uint256 tokenId);
}

// Main Contract
contract Mint721Enhanced is
    ERC721AUpgradeable,
    UUPSUpgradeable,
    AccessControl,
    Pausable,
    ReentrancyGuard,
    IERC2981
{
    // -----------------------------------------------
    // STORAGE VARIABLES
    // -----------------------------------------------
    // External component references
    IMetadataRenderer public metadataRenderer;
    IRc77Oracle public rc77Oracle;
    IBTBBZVault public btbbzVault;
    IAssetAuthorityRegistry public assetRegistry;

    // Token-specific data
    mapping(uint256 => uint256) public vaultIdOf;
    mapping(uint256 => string) public arweaveHash;
    mapping(uint256 => bytes32) public porHash;

    // Royalty info
    address private _royaltyRecipient;
    uint96 private _royaltyBasisPoints; // e.g., 500 = 5%

    // Roles
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");
    bytes32 public constant ROLE_MANAGER = keccak256("ROLE_MANAGER");

    // -----------------------------------------------
    // EVENTS
    // -----------------------------------------------
    event Minted(address indexed to, uint256[] tokenIds, uint256 vaultId);
    event VaultRegistered(uint256 indexed tokenId, uint256 vaultId);
    event DepositedToVault(address indexed owner, uint256 indexed tokenId, uint256 shares);
    event RedeemedFromVault(address indexed owner, uint256 indexed tokenId, uint256 shares);
    event MetadataUpdated(uint256 indexed tokenId, string arweaveHash);
    event PoRUpdated(uint256 indexed tokenId, bytes32 porHash);
    event RoyaltyInfoSet(address indexed recipient, uint96 bps);
    event RoleGranted(bytes32 indexed role, address indexed account, address indexed sender);
    event RoleRevoked(bytes32 indexed role, address indexed account, address indexed sender);
    event Paused(address account);
    event Unpaused(address account);
    event UpgradeAuthorized(address indexed implementation, address indexed admin);
    event EmergencyStop(address account);
    event EmergencyResume(address account);
    event RoleManagement(address indexed manager, bool granted);

    // -----------------------------------------------
    // INITIALIZER
    // -----------------------------------------------
    function initialize(
        string memory name_,
        string memory symbol_,
        address renderer_,
        address oracle_,
        address registry_,
        address vault_,
        address admin_,
        address minter_,
        address pauser_,
        address upgrader_,
        address royaltyRecipient_,
        uint96 royaltyBps_
    ) external initializer {
        __ERC721A_init(name_, symbol_);
        __UUPSUpgradeable_init();
        __AccessControl_init();
        __Pausable_init();
        __ReentrancyGuard_init();

        // Setup roles
        _setupRole(DEFAULT_ADMIN_ROLE, admin_);
        _setupRole(ADMIN_ROLE, admin_);
        _setupRole(MINTER_ROLE, minter_);
        _setupRole(PAUSER_ROLE, pauser_);
        _setupRole(UPGRADER_ROLE, upgrader_);
        _setupRole(ROLE_MANAGER, admin_);

        // External components
        metadataRenderer = IMetadataRenderer(renderer_);
        rc77Oracle = IRc77Oracle(oracle_);
        assetRegistry = IAssetAuthorityRegistry(registry_);
        btbbzVault = IBTBBZVault(vault_);

        // Royalty
        _royaltyRecipient = royaltyRecipient_;
        _royaltyBasisPoints = royaltyBps_;

        emit RoleGranted(ADMIN_ROLE, admin_, msg.sender);
        emit RoleGranted(MINTER_ROLE, minter_, msg.sender);
        emit RoleGranted(PAUSER_ROLE, pauser_, msg.sender);
        emit RoleGranted(UPGRADER_ROLE, upgrader_, msg.sender);
        emit RoleGranted(ROLE_MANAGER, admin_, msg.sender);
        emit RoyaltyInfoSet(royaltyRecipient_, royaltyBps_);
    }

    // -----------------------------------------------
    // UUPS upgrade authorization
    // -----------------------------------------------
    function _authorizeUpgrade(address implementation) internal override onlyRole(UPGRADER_ROLE) {
        emit UpgradeAuthorized(implementation, msg.sender);
    }

    // -----------------------------------------------
    // ROLE MANAGEMENT
    // -----------------------------------------------
    function grantRole(bytes32 role, address account) public override onlyRole(getRoleAdmin(role)) {
        super.grantRole(role, account);
        emit RoleGranted(role, account, msg.sender);
    }

    function revokeRole(bytes32 role, address account) public override onlyRole(getRoleAdmin(role)) {
        super.revokeRole(role, account);
        emit RoleRevoked(role, account, msg.sender);
    }

    function renounceRole(bytes32 role, address account) public override {
        require(account == msg.sender, "Can only renounce own role");
        super.renounceRole(role, account);
        emit RoleRevoked(role, account, msg.sender);
    }

    // -----------------------------------------------
    // PAUSABLE & EMERGENCY
    // -----------------------------------------------
    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
        emit Paused(msg.sender);
    }

    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
        emit Unpaused(msg.sender);
    }

    function emergencyStop() external onlyRole(ADMIN_ROLE) {
        _pause();
        emit EmergencyStop(msg.sender);
    }

    function emergencyResume() external onlyRole(ADMIN_ROLE) {
        _unpause();
        emit EmergencyResume(msg.sender);
    }

    // -----------------------------------------------
    // MINT & Vault Registration
    // -----------------------------------------------
    function mintVaultAsset(
        address to,
        uint256 quantity,
        uint256 vaultId,
        string calldata arweaveMirror
    ) external onlyRole(MINTER_ROLE) whenNotPaused {
        uint256 startId = _nextTokenId();
        _mint(to, quantity);
        uint256[] memory mintedIds = new uint256[](quantity);
        for (uint256 i = 0; i < quantity; i++) {
            uint256 tokenId = startId + i;
            _registerVault(tokenId, vaultId);
            arweaveHash[tokenId] = arweaveMirror;
            // Generate PoR using oracle valuation
            uint256 valuation = rc77Oracle.getSpotPrice();
            bytes32 por = keccak256(abi.encodePacked(block.timestamp, valuation, tokenId, vaultId));
            porHash[tokenId] = por;
            mintedIds[i] = tokenId;
            emit VaultRegistered(tokenId, vaultId);
        }
        emit Minted(to, mintedIds, vaultId);
    }

    function _registerVault(uint256 tokenId, uint256 vaultId) internal {
        vaultIdOf[tokenId] = vaultId;
        assetRegistry.registerAsset(address(this), tokenId, vaultId, ownerOf(tokenId));
    }

    // -----------------------------------------------
    // RC77 Vault Hooks
    // -----------------------------------------------
    function depositToRC77(uint256 tokenId) external nonReentrant whenNotPaused returns (uint256 shares) {
        require(ownerOf(tokenId) == msg.sender, "Not owner");
        _transfer(msg.sender, address(btbbzVault), tokenId);
        shares = btbbzVault.depositNFT(address(this), tokenId);
        emit DepositedToVault(msg.sender, tokenId, shares);
    }

    function redeemFromRC77(uint256 shares) external nonReentrant whenNotPaused returns (uint256 tokenId) {
        tokenId = btbbzVault.redeemShares(shares);
        _transfer(address(btbbzVault), msg.sender, tokenId);
        emit RedeemedFromVault(msg.sender, tokenId, shares);
    }

    // -----------------------------------------------
    // Metadata & PoR Updates
    // -----------------------------------------------
    function updateArweaveHash(uint256 tokenId, string calldata newHash) external onlyRole(ADMIN_ROLE) {
        arweaveHash[tokenId] = newHash;
        emit MetadataUpdated(tokenId, newHash);
    }

    function updatePoRHash(uint256 tokenId) external onlyRole(ADMIN_ROLE) {
        uint256 valuation = rc77Oracle.getSpotPrice();
        bytes32 newPor = keccak256(abi.encodePacked(block.timestamp, valuation, tokenId));
        porHash[tokenId] = newPor;
        emit PoRUpdated(tokenId, newPor);
    }

    // -----------------------------------------------
    // Royalty Functions
    // -----------------------------------------------
    function setRoyaltyInfo(address recipient, uint96 basisPoints) external onlyRole(ADMIN_ROLE) {
        _royaltyRecipient = recipient;
        _royaltyBasisPoints = basisPoints;
        emit RoyaltyInfoSet(recipient, basisPoints);
    }

    function royaltyInfo(uint256, uint256 salePrice) external view override returns (address, uint256) {
        return (_royaltyRecipient, (salePrice * _royaltyBasisPoints) / 10000);
    }

    // -----------------------------------------------
    // Support Interface
    // -----------------------------------------------
    function supportsInterface(bytes4 interfaceId) public view override(ERC721AUpgradeable, IERC2981, AccessControl) returns (bool) {
        return super.supportsInterface(interfaceId);
    }

    // -----------------------------------------------
    // OWNER OR ROLE-BASED ADMIN FUNCTIONS
    // -----------------------------------------------
    function setMetadataRenderer(address newRenderer) external onlyRole(ADMIN_ROLE) {
        metadataRenderer = IMetadataRenderer(newRenderer);
    }

    function setOracle(address newOracle) external onlyRole(ADMIN_ROLE) {
        rc77Oracle = IRc77Oracle(newOracle);
    }

    function setAssetRegistry(address newRegistry) external onlyRole(ADMIN_ROLE) {
        assetRegistry = IAssetAuthorityRegistry(newRegistry);
    }

    function setVault(address newVault) external onlyRole(ADMIN_ROLE) {
        btbbzVault = IBTBBZVault(newVault);
    }

    // -----------------------------------------------
    // BATCH TRANSFER (optional)
    // -----------------------------------------------
    function batchTransfer(address[] calldata recipients, uint256[] calldata tokenIds) external nonReentrant whenNotPaused {
        require(recipients.length == tokenIds.length, "Array length mismatch");
        for (uint256 i = 0; i < recipients.length; i++) {
            transferFrom(_msgSender(), recipients[i], tokenIds[i]);
        }
    }
}