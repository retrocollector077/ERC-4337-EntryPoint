// SPDX-License-Identifier: MIT 

pragma solidity ^0.8.29; 

 

import "@openzeppelin/contracts/token/ERC721/IERC721.sol"; 

import "@openzeppelin/contracts/token/ERC721/ERC721.sol"; 

import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol"; 

import "@openzeppelin/contracts/security/ReentrancyGuard.sol"; 

import "@openzeppelin/contracts/security/Pausable.sol"; 

import "@openzeppelin/contracts/access/Ownable.sol"; 

import "@openzeppelin/contracts/token/common/ERC2981.sol"; 

import "@openzeppelin/contracts/token/ERC20/IERC20.sol"; 

 

contract VerifyVaultWrapped721 is 

    ERC721, 

    ERC2981, 

    IERC721Receiver, 

    Ownable, 

    Pausable, 

    ReentrancyGuard 

{ 

    // ========= Types ========= 

 

    struct Original { 

        address collection; // original ERC-721 contract 

        uint256 tokenId;    // original tokenId 

    } 

 

    // ========= Storage ========= 

 

    // Vault that receives all tolls / fees / royalties 

    address public vault; 

 

    // (collection, tokenId) -> wrappedId exists 

    mapping(bytes32 => uint256) private _wrappedIdOf; 

 

    // wrappedId -> Original 

    mapping(uint256 => Original) private _originalOf; 

 

    // prepaid transfer credits per wrapped token 

    mapping(uint256 => uint256) public credits; 

 

    // default ETH fee (wei) per transfer 

    uint256 public defaultFeeWei; 

 

    // optional ERC-20 token used for fees (if set != address(0)) 

    address public feeToken; 

 

    // optional per-token custom ETH fee override 

    mapping(uint256 => uint256) public customFeeWei; 

 

    // monotonically increasing seed to avoid unlikely id collisions 

    uint256 private _mintSeq; 

 

    // ========= Events ========= 

 

    event Wrapped(address indexed collection, uint256 indexed tokenId, uint256 indexed wrappedId, address owner); 

    event Unwrapped(uint256 indexed wrappedId, address to); 

    event FeePaid(uint256 indexed wrappedId, address indexed payer, uint256 creditsAdded, uint256 amountWei, address feeToken); 

    event VaultUpdated(address indexed newVault); 

    event DefaultFeeUpdated(uint256 feeWei); 

    event CustomFeeUpdated(uint256 indexed wrappedId, uint256 feeWei); 

    event FeeTokenUpdated(address token); 

 

    // ========= Constructor ========= 

 

    constructor(address _vault, uint96 royaltyBps, uint256 _defaultFeeWei) 

        ERC721("VerifyVault Wrapped NFT", "VV-WNFT") 

    { 

        vault = _vault == address(0) ? msg.sender : _vault; 

        defaultFeeWei = _defaultFeeWei; // e.g., 0.0005 ether 

        _setDefaultRoyalty(vault, royaltyBps); // e.g., 1000 = 10% 

    } 

 

    // ========= Modifiers / Internal helpers ========= 

 

    function _originalKey(address collection, uint256 tokenId) internal pure returns (bytes32) { 

        return keccak256(abi.encodePacked(collection, tokenId)); 

    } 

 

    function _effectiveFeeWei(uint256 wrappedId) internal view returns (uint256) { 

        uint256 c = customFeeWei[wrappedId]; 

        return c == 0 ? defaultFeeWei : c; 

    } 

 

    // ========= Wrap / Unwrap ========= 

 

    /** 

     * @notice Wrap an ERC-721. Requires prior approval to this contract. 

     * @param collection Original ERC-721 contract 

     * @param tokenId    Original tokenId 

     * @param to         Recipient of wrapped token 

     */ 

    function wrap(address collection, uint256 tokenId, address to) 

        external 

        nonReentrant 

        whenNotPaused 

    { 

        require(collection != address(0), "bad collection"); 

        require(to != address(0), "bad recipient"); 

 

        // pull the NFT into escrow 

        IERC721(collection).safeTransferFrom(msg.sender, address(this), tokenId); 

 

        // derive / assign a stable wrappedId 

        bytes32 key = _originalKey(collection, tokenId); 

        require(_wrappedIdOf[key] == 0, "already wrapped"); 

 

        // simple ever-increasing seq to avoid zero-id 

        _mintSeq++; 

        uint256 wrappedId = uint256(keccak256(abi.encodePacked(key, _mintSeq))); 

 

        _wrappedIdOf[key] = wrappedId; 

        _originalOf[wrappedId] = Original({collection: collection, tokenId: tokenId}); 

 

        _safeMint(to, wrappedId); 

 

        emit Wrapped(collection, tokenId, wrappedId, to); 

    } 

 

    /** 

     * @notice Unwrap to redeem the original NFT. Burns the wrapped token. 

     * @param wrappedId Wrapped tokenId 

     * @param to        Recipient of the original NFT 

     */ 

    function unwrap(uint256 wrappedId, address to) 

        external 

        nonReentrant 

    { 

        require(_exists(wrappedId), "no such wrapped"); 

        require(_isApprovedOrOwner(msg.sender, wrappedId), "not owner/approved"); 

        require(to != address(0), "bad recipient"); 

 

        Original memory o = _originalOf[wrappedId]; 

 

        // burn wrapped and release original 

        _burn(wrappedId); 

 

        // clear mappings 

        bytes32 key = _originalKey(o.collection, o.tokenId); 

        delete _wrappedIdOf[key]; 

        delete _originalOf[wrappedId]; 

        delete credits[wrappedId]; 

        delete customFeeWei[wrappedId]; 

 

        IERC721(o.collection).safeTransferFrom(address(this), to, o.tokenId); 

 

        emit Unwrapped(wrappedId, to); 

    } 

 

    // ========= Transfer Toll (prepaid credits) ========= 

 

    /** 

     * @notice Pay ETH transfer fees to add credits (1 credit = 1 transfer). 

     *         ETH is immediately forwarded to the Vault. 

     * @param wrappedId token to credit 

     * @param count     number of credits to add (>=1) 

     */ 

    function payTransferFeeETH(uint256 wrappedId, uint256 count) 

        external 

        payable 

        whenNotPaused 

    { 

        require(_exists(wrappedId), "no such wrapped"); 

        require(count >= 1, "count=0"); 

 

        uint256 fee = _effectiveFeeWei(wrappedId) * count; 

        require(msg.value == fee, "wrong ETH sent"); 

 

        credits[wrappedId] += count; 

        (bool ok, ) = payable(vault).call{value: fee}(""); 

        require(ok, "vault transfer failed"); 

 

        emit FeePaid(wrappedId, msg.sender, count, fee, address(0)); 

    } 

 

    /** 

     * @notice Pay ERC-20 transfer fees (if feeToken is set) to add credits. 

     * @param wrappedId token to credit 

     * @param count     number of credits to add 

     */ 

    function payTransferFeeToken(uint256 wrappedId, uint256 count) 

        external 

        whenNotPaused 

    { 

        address t = feeToken; 

        require(t != address(0), "fee token not set"); 

        require(_exists(wrappedId), "no such wrapped"); 

        require(count >= 1, "count=0"); 

 

        uint256 fee = _effectiveFeeWei(wrappedId) * count; // use wei field as "token units" for simplicity 

        require(IERC20(t).transferFrom(msg.sender, vault, fee), "token xfer failed"); 

 

        credits[wrappedId] += count; 

        emit FeePaid(wrappedId, msg.sender, count, 0, t); 

    } 

 

    /** 

     * @dev Core enforcement: any transfer requires at least 1 credit. 

     *      Consumes exactly 1 credit per transfer (mint/burn excluded). 

     */ 

    function _beforeTokenTransfer( 

        address from, 

        address to, 

        uint256 firstTokenId, 

        uint256 batchSize 

    ) internal override whenNotPaused { 

        super._beforeTokenTransfer(from, to, firstTokenId, batchSize); 

 

        // Ignore mints and burns 

        if (from != address(0) && to != address(0)) { 

            require(batchSize == 1, "no batching"); 

            uint256 id = firstTokenId; 

            require(credits[id] >= 1, "toll not paid"); 

            unchecked { credits[id] -= 1; } 

        } 

    } 

 

    // ========= Admin controls ========= 

 

    function setVault(address newVault) external onlyOwner { 

        require(newVault != address(0), "bad vault"); 

        vault = newVault; 

        // keep royalties aligned with vault 

        (address recv, ) = royaltyInfo(0, 10_000); // dummy call to silence warnings 

        recv; // no-op 

        _setDefaultRoyalty(newVault, _feeDenominator()); // keep bps same 

        emit VaultUpdated(newVault); 

    } 

 

    function setDefaultFeeWei(uint256 feeWei) external onlyOwner { 

        defaultFeeWei = feeWei; 

        emit DefaultFeeUpdated(feeWei); 

    } 

 

    function setCustomFeeWei(uint256 wrappedId, uint256 feeWei) external onlyOwner { 

        require(_exists(wrappedId), "no such wrapped"); 

        customFeeWei[wrappedId] = feeWei; 

        emit CustomFeeUpdated(wrappedId, feeWei); 

    } 

 

    function setRoyaltyBps(uint96 bps) external onlyOwner { 

        _setDefaultRoyalty(vault, bps); 

    } 

 

    function setFeeToken(address token) external onlyOwner { 

        feeToken = token; // set to 0x0 to disable ERC-20 fee path 

        emit FeeTokenUpdated(token); 

    } 

 

    function pause() external onlyOwner { _pause(); } 

    function unpause() external onlyOwner { _unpause(); } 

 

    /** 

     * @notice Emergency rescue: return an escrowed original NFT if something goes wrong. 

     *         Only callable by owner when the corresponding wNFT no longer exists. 

     */ 

    function emergencyRescueOriginal(address collection, uint256 tokenId, address to) 

        external 

        onlyOwner 

        nonReentrant 

    { 

        require(to != address(0), "bad to"); 

        bytes32 key = _originalKey(collection, tokenId); 

        uint256 wid = _wrappedIdOf[key]; 

        require(wid == 0 || !_exists(wid), "still wrapped"); 

        IERC721(collection).safeTransferFrom(address(this), to, tokenId); 

    } 

 

    // ========= Views ========= 

 

    function originalOf(uint256 wrappedId) external view returns (Original memory) { 

        require(_exists(wrappedId), "no such wrapped"); 

        return _originalOf[wrappedId]; 

    } 

 

    function wrappedIdOf(address collection, uint256 tokenId) external view returns (uint256) { 

        return _wrappedIdOf[_originalKey(collection, tokenId)]; 

    } 

 

    // ========= ERC-721 Receiver ========= 

 

    function onERC721Received(address, address, uint256, bytes calldata) external pure override returns (bytes4) { 

        return IERC721Receiver.onERC721Received.selector; 

    } 

 

    // ========= ERC-165 ========= 

 

    function supportsInterface(bytes4 interfaceId) 

        public 

        view 

        override(ERC721, ERC2981) 

        returns (bool) 

    { 

        return super.supportsInterface(interfaceId); 

    } 

 

    // ========= Royalty denominator exposure (helper) ========= 

    function _feeDenominator() internal pure returns (uint96) { 

        return 10_000; // 100% = 10_000 bps 

    } 

} 

 

// SPDX-License-Identifier: MIT 

pragma solidity ^0.8.24; 

 

/** 

 *  VerifyVault Wrapped ERC-721 (wNFT) – with Auto-Vault Routing 

 * 

 *  Vault set to: 0xDD2Be2Fe65Cac7F1772C9C5DeE5a0216Ac5CB6a7 

 * 

 *  - Wrap any ERC-721 into escrow + mint wrapped ERC-721. 

 *  - Enforces prepaid transfer tolls (ETH or ERC-20). 

 *  - Every fee is auto-forwarded to your Vault above. 

 *  - Royalties set at 10% for marketplaces that honor ERC-2981. 

 * 

 *  Deploy-and-go. No placeholders. 

 */ 

 

import "@openzeppelin/contracts/token/ERC721/IERC721.sol"; 

import "@openzeppelin/contracts/token/ERC721/ERC721.sol"; 

import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol"; 

import "@openzeppelin/contracts/security/ReentrancyGuard.sol"; 

import "@openzeppelin/contracts/security/Pausable.sol"; 

import "@openzeppelin/contracts/access/Ownable.sol"; 

import "@openzeppelin/contracts/token/common/ERC2981.sol"; 

import "@openzeppelin/contracts/token/ERC20/IERC20.sol"; 

 

contract VerifyVaultWrapped721 is 

    ERC721, 

    ERC2981, 

    IERC721Receiver, 

    Ownable, 

    Pausable, 

    ReentrancyGuard 

{ 

    struct Original { 

        address collection; 

        uint256 tokenId; 

    } 

 

    address public constant vault = 0xDD2Be2Fe65Cac7F1772C9C5DeE5a0216Ac5CB6a7; 

 

    mapping(bytes32 => uint256) private _wrappedIdOf; 

    mapping(uint256 => Original) private _originalOf; 

    mapping(uint256 => uint256) public credits; 

 

    uint256 public defaultFeeWei; 

    address public feeToken; 

    mapping(uint256 => uint256) public customFeeWei; 

    uint256 private _mintSeq; 

 

    event Wrapped(address indexed collection, uint256 indexed tokenId, uint256 indexed wrappedId, address owner); 

    event Unwrapped(uint256 indexed wrappedId, address to); 

    event FeePaid(uint256 indexed wrappedId, address indexed payer, uint256 creditsAdded, uint256 amount, address feeToken); 

 

    constructor(uint256 _defaultFeeWei) ERC721("VerifyVault Wrapped NFT", "VV-WNFT") { 

        defaultFeeWei = _defaultFeeWei; // e.g., 0.0005 ether 

        _setDefaultRoyalty(vault, 1000); // 10% royalties 

    } 

 

    function _originalKey(address collection, uint256 tokenId) internal pure returns (bytes32) { 

        return keccak256(abi.encodePacked(collection, tokenId)); 

    } 

 

    function _effectiveFeeWei(uint256 wrappedId) internal view returns (uint256) { 

        uint256 c = customFeeWei[wrappedId]; 

        return c == 0 ? defaultFeeWei : c; 

    } 

 

    function wrap(address collection, uint256 tokenId, address to) external nonReentrant whenNotPaused { 

        IERC721(collection).safeTransferFrom(msg.sender, address(this), tokenId); 

        bytes32 key = _originalKey(collection, tokenId); 

        require(_wrappedIdOf[key] == 0, "already wrapped"); 

 

        _mintSeq++; 

        uint256 wrappedId = uint256(keccak256(abi.encodePacked(key, _mintSeq))); 

        _wrappedIdOf[key] = wrappedId; 

        _originalOf[wrappedId] = Original(collection, tokenId); 

 

        _safeMint(to, wrappedId); 

        emit Wrapped(collection, tokenId, wrappedId, to); 

    } 

 

    function unwrap(uint256 wrappedId, address to) external nonReentrant { 

        require(_exists(wrappedId), "no such wrapped"); 

        require(_isApprovedOrOwner(msg.sender, wrappedId), "not owner/approved"); 

 

        Original memory o = _originalOf[wrappedId]; 

        _burn(wrappedId); 

        delete _wrappedIdOf[_originalKey(o.collection, o.tokenId)]; 

        delete _originalOf[wrappedId]; 

        delete credits[wrappedId]; 

        delete customFeeWei[wrappedId]; 

 

        IERC721(o.collection).safeTransferFrom(address(this), to, o.tokenId); 

        emit Unwrapped(wrappedId, to); 

    } 

 

    function payTransferFeeETH(uint256 wrappedId, uint256 count) external payable whenNotPaused { 

        require(_exists(wrappedId), "no such wrapped"); 

        require(count >= 1, "count=0"); 

 

        uint256 fee = _effectiveFeeWei(wrappedId) * count; 

        require(msg.value == fee, "wrong ETH sent"); 

 

        credits[wrappedId] += count; 

        (bool ok, ) = payable(vault).call{value: fee}(""); 

        require(ok, "vault transfer failed"); 

 

        emit FeePaid(wrappedId, msg.sender, count, fee, address(0)); 

    } 

 

    function payTransferFeeToken(uint256 wrappedId, uint256 count) external whenNotPaused { 

        require(feeToken != address(0), "fee token not set"); 

        require(_exists(wrappedId), "no such wrapped"); 

        require(count >= 1, "count=0"); 

 

        uint256 fee = _effectiveFeeWei(wrappedId) * count; 

        require(IERC20(feeToken).transferFrom(msg.sender, vault, fee), "token xfer failed"); 

 

        credits[wrappedId] += count; 

        emit FeePaid(wrappedId, msg.sender, count, fee, feeToken); 

    } 

 

    function _beforeTokenTransfer(address from, address to, uint256 id, uint256 batchSize) 

        internal 

        override 

        whenNotPaused 

    { 

        super._beforeTokenTransfer(from, to, id, batchSize); 

        if (from != address(0) && to != address(0)) { 

            require(batchSize == 1, "no batching"); 

            require(credits[id] >= 1, "toll not paid"); 

            credits[id] -= 1; 

        } 

    } 

 

    // Admin 

    function setDefaultFeeWei(uint256 feeWei) external onlyOwner { defaultFeeWei = feeWei; } 

    function setCustomFeeWei(uint256 wrappedId, uint256 feeWei) external onlyOwner { customFeeWei[wrappedId] = feeWei; } 

    function setFeeToken(address token) external onlyOwner { feeToken = token; } 

 

    // Views 

    function originalOf(uint256 wrappedId) external view returns (Original memory) { return _originalOf[wrappedId]; } 

    function wrappedIdOf(address collection, uint256 tokenId) external view returns (uint256) { return _wrappedIdOf[_originalKey(collection, tokenId)]; } 

 

    function onERC721Received(address, address, uint256, bytes calldata) external pure override returns (bytes4) { 

        return IERC721Receiver.onERC721Received.selector; 

    } 

 

    function supportsInterface(bytes4 interfaceId) public view override(ERC721, ERC2981) returns (bool) { 

        return super.supportsInterface(interfaceId); 

    } 

} 

 

// SPDX-License-Identifier: MIT 

pragma solidity ^0.8.24; 

 

/* 

 * VerifyVault Universal Wrapped NFT (ERC721 + ERC1155) 

 * 

 * Vault (all fees/royalties): 

 *   0xDD2Be2Fe65Cac7F1772C9C5DeE5a0216Ac5CB6a7 

 * 

 * Features 

 * - Wrap ERC721 or ERC1155 (e.g., ENS NameWrapper) into a single wrapped ERC721 (wNFT). 

 * - Prepaid transfer tolls (ETH or ERC20). 1 credit = 1 transfer. No credit => revert. 

 * - All fees instantly forwarded to the vault; default 10% ERC-2981 royalties to vault. 

 * - Metadata & ENS snapshot at wrap-time: 

 *      * Stores tokenURI hash + hints 

 *      * Stores ENS name, node (namehash), resolver 

 *      * Emits event with (keys, values) arrays for ENS text records (cheap evidence). 

 * 

 * Notes 

 * - For ERC1155 wrap, typical ENS NameWrapper "amount" is 1. We support any amount >=1. 

 * - Underlying approvals are required before calling wrap. 

 * - Owner can tune fees & set optional ERC20 fee token. 

 */ 

 

import "@openzeppelin/contracts/token/ERC721/IERC721.sol"; 

import "@openzeppelin/contracts/token/ERC721/ERC721.sol"; 

import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol"; 

 

import "@openzeppelin/contracts/token/ERC1155/IERC1155.sol"; 

import "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Receiver.sol"; 

 

import "@openzeppelin/contracts/token/common/ERC2981.sol"; 

import "@openzeppelin/contracts/security/ReentrancyGuard.sol"; 

import "@openzeppelin/contracts/security/Pausable.sol"; 

import "@openzeppelin/contracts/access/Ownable.sol"; 

import "@openzeppelin/contracts/token/ERC20/IERC20.sol"; 

 

contract VerifyVaultUniversalWrapper is 

    ERC721, 

    ERC2981, 

    IERC721Receiver, 

    ERC1155Receiver, 

    Ownable, 

    Pausable, 

    ReentrancyGuard 

{ 

    // ====== Constants ====== 

    address public constant VAULT = 0xDD2Be2Fe65Cac7F1772C9C5DeE5a0216Ac5CB6a7; 

 

    // ====== Types ====== 

    enum AssetType { ERC721Asset, ERC1155Asset } 

 

    struct Original { 

        AssetType aType; 

        address   collection; // ERC721 or ERC1155 contract 

        uint256   id;         // tokenId (721) or id (1155) 

        uint256   amount;     // 1 for 721, >=1 for 1155 

    } 

 

    // Minimal on-chain snapshot (extra details emitted in events) 

    struct Snapshot { 

        string  tokenURIHint;     // optional human-readable hint/URI 

        bytes32 tokenURIHash;     // keccak256 of original tokenURI string (if supplied) 

        string  ensName;          // e.g. "verifyvault.eth" 

        bytes32 ensNode;          // namehash(node) 

        address ensResolver;      // resolver at wrap time 

    } 

 

    // ====== Storage ====== 

    mapping(bytes32 => uint256) private _wrappedIdOf; // original key => wId (exists) 

    mapping(uint256 => Original) private _originalOf; // wId => original 

    mapping(uint256 => Snapshot) private _snapshotOf; // wId => snapshot 

    mapping(uint256 => uint256) public credits;       // transfer credits 

    mapping(uint256 => uint256) public customFeeWei;  // per-token ETH fee 

    uint256 public defaultFeeWei;                     // global ETH fee 

    address public feeToken;                          // optional ERC20 fee 

    uint256 private _seq;                             // id salt 

 

    // ====== Events ====== 

    event Wrapped(address indexed collection, uint256 indexed id, uint256 amount, uint256 indexed wrappedId, address owner, AssetType aType); 

    event Unwrapped(uint256 indexed wrappedId, address to); 

    event FeePaid(uint256 indexed wrappedId, address indexed payer, uint256 creditsAdded, uint256 value, address feeToken); 

    event ENSRecordsSnapshotted(uint256 indexed wrappedId, string[] keys, string[] values); // text records mirrored via event 

    event DefaultFeeUpdated(uint256 feeWei); 

    event CustomFeeUpdated(uint256 indexed wrappedId, uint256 feeWei); 

    event FeeTokenUpdated(address token); 

 

    // ====== Constructor ====== 

    constructor(uint256 _defaultFeeWei, uint96 royaltyBps) 

        ERC721("VerifyVault Universal wNFT", "VV-UwNFT") 

    { 

        defaultFeeWei = _defaultFeeWei; 

        _setDefaultRoyalty(VAULT, royaltyBps); // e.g., 1000 = 10% 

    } 

 

    // ====== Internal helpers ====== 

    function _key721(address c, uint256 id) internal pure returns (bytes32) { 

        return keccak256(abi.encodePacked(uint8(AssetType.ERC721Asset), c, id)); 

    } 

    function _key1155(address c, uint256 id, uint256 amount) internal pure returns (bytes32) { 

        return keccak256(abi.encodePacked(uint8(AssetType.ERC1155Asset), c, id, amount)); 

    } 

    function _effectiveFeeWei(uint256 wId) internal view returns (uint256) { 

        uint256 c = customFeeWei[wId]; 

        return c == 0 ? defaultFeeWei : c; 

    } 

 

    // ====== Wrap (ERC721) with metadata/ENS snapshot ====== 

    function wrap721( 

        address collection, 

        uint256 tokenId, 

        address to, 

        // metadata snapshot 

        string calldata tokenURIHint, 

        bytes32 tokenURIHash, 

        // ENS snapshot 

        string calldata ensName, 

        bytes32 ensNode, 

        address ensResolver, 

        // ENS text records (emit only) 

        string[] calldata textKeys, 

        string[] calldata textValues 

    ) external nonReentrant whenNotPaused { 

        require(collection != address(0), "bad collection"); 

        require(to != address(0), "bad to"); 

        require(textKeys.length == textValues.length, "kv len mismatch"); 

 

        IERC721(collection).safeTransferFrom(msg.sender, address(this), tokenId); 

 

        bytes32 k = _key721(collection, tokenId); 

        require(_wrappedIdOf[k] == 0, "already wrapped"); 

 

        _seq++; 

        uint256 wId = uint256(keccak256(abi.encodePacked(k, _seq))); 

        _wrappedIdOf[k] = wId; 

        _originalOf[wId] = Original(AssetType.ERC721Asset, collection, tokenId, 1); 

 

        _snapshotOf[wId] = Snapshot(tokenURIHint, tokenURIHash, ensName, ensNode, ensResolver); 

 

        _safeMint(to, wId); 

        emit Wrapped(collection, tokenId, 1, wId, to, AssetType.ERC721Asset); 

        if (textKeys.length > 0) emit ENSRecordsSnapshotted(wId, textKeys, textValues); 

    } 

 

    // ====== Wrap (ERC1155) with metadata/ENS snapshot ====== 

    function wrap1155( 

        address collection, 

        uint256 id, 

        uint256 amount, 

        address to, 

        // metadata snapshot 

        string calldata tokenURIHint, 

        bytes32 tokenURIHash, 

        // ENS snapshot 

        string calldata ensName, 

        bytes32 ensNode, 

        address ensResolver, 

        // ENS text records (emit only) 

        string[] calldata textKeys, 

        string[] calldata textValues 

    ) external nonReentrant whenNotPaused { 

        require(collection != address(0), "bad collection"); 

        require(to != address(0), "bad to"); 

        require(amount >= 1, "amount=0"); 

        require(textKeys.length == textValues.length, "kv len mismatch"); 

 

        IERC1155(collection).safeTransferFrom(msg.sender, address(this), id, amount, ""); 

 

        bytes32 k = _key1155(collection, id, amount); 

        require(_wrappedIdOf[k] == 0, "already wrapped"); 

 

        _seq++; 

        uint256 wId = uint256(keccak256(abi.encodePacked(k, _seq))); 

        _wrappedIdOf[k] = wId; 

        _originalOf[wId] = Original(AssetType.ERC1155Asset, collection, id, amount); 

 

        _snapshotOf[wId] = Snapshot(tokenURIHint, tokenURIHash, ensName, ensNode, ensResolver); 

 

        _safeMint(to, wId); 

        emit Wrapped(collection, id, amount, wId, to, AssetType.ERC1155Asset); 

        if (textKeys.length > 0) emit ENSRecordsSnapshotted(wId, textKeys, textValues); 

    } 

 

    // ====== Unwrap ====== 

    function unwrap(uint256 wId, address to) external nonReentrant { 

        require(_exists(wId), "no wrapped"); 

        require(_isApprovedOrOwner(msg.sender, wId), "not owner/approved"); 

        require(to != address(0), "bad to"); 

 

        Original memory o = _originalOf[wId]; 

 

        _burn(wId); 

 

        // clear keys 

        if (o.aType == AssetType.ERC721Asset) { 

            delete _wrappedIdOf[_key721(o.collection, o.id)]; 

        } else { 

            delete _wrappedIdOf[_key1155(o.collection, o.id, o.amount)]; 

        } 

        delete _originalOf[wId]; 

        delete _snapshotOf[wId]; 

        delete credits[wId]; 

        delete customFeeWei[wId]; 

 

        // return original 

        if (o.aType == AssetType.ERC721Asset) { 

            IERC721(o.collection).safeTransferFrom(address(this), to, o.id); 

        } else { 

            IERC1155(o.collection).safeTransferFrom(address(this), to, o.id, o.amount, ""); 

        } 

 

        emit Unwrapped(wId, to); 

    } 

 

    // ====== Tolls / Credits ====== 

    function payTransferFeeETH(uint256 wId, uint256 count) external payable whenNotPaused { 

        require(_exists(wId), "no wrapped"); 

        require(count >= 1, "count=0"); 

        uint256 fee = _effectiveFeeWei(wId) * count; 

        require(msg.value == fee, "wrong value"); 

        credits[wId] += count; 

        (bool ok, ) = payable(VAULT).call{value: fee}(""); 

        require(ok, "vault xfer failed"); 

        emit FeePaid(wId, msg.sender, count, fee, address(0)); 

    } 

 

    function payTransferFeeToken(uint256 wId, uint256 count) external whenNotPaused { 

        address t = feeToken; 

        require(t != address(0), "fee token unset"); 

        require(_exists(wId), "no wrapped"); 

        require(count >= 1, "count=0"); 

        uint256 fee = _effectiveFeeWei(wId) * count; // interpret as token units 

        require(IERC20(t).transferFrom(msg.sender, VAULT, fee), "token xfer failed"); 

        credits[wId] += count; 

        emit FeePaid(wId, msg.sender, count, fee, t); 

    } 

 

    function _beforeTokenTransfer(address from, address to, uint256 id, uint256 batchSize) 

        internal 

        override 

        whenNotPaused 

    { 

        super._beforeTokenTransfer(from, to, id, batchSize); 

        if (from != address(0) && to != address(0)) { 

            require(batchSize == 1, "no batch"); 

            require(credits[id] >= 1, "toll not paid"); 

            unchecked { credits[id] -= 1; } 

        } 

    } 

 

    // ====== Views ====== 

    function originalOf(uint256 wId) external view returns (Original memory) { return _originalOf[wId]; } 

    function snapshotOf(uint256 wId) external view returns (Snapshot memory) { return _snapshotOf[wId]; } 

 

    function wrappedIdOf721(address collection, uint256 tokenId) external view returns (uint256) { 

        return _wrappedIdOf[_key721(collection, tokenId)]; 

    } 

    function wrappedIdOf1155(address collection, uint256 id, uint256 amount) external view returns (uint256) { 

        return _wrappedIdOf[_key1155(collection, id, amount)]; 

    } 

 

    // ====== Admin ====== 

    function setDefaultFeeWei(uint256 feeWei) external onlyOwner { defaultFeeWei = feeWei; emit DefaultFeeUpdated(feeWei); } 

    function setCustomFeeWei(uint256 wId, uint256 feeWei) external onlyOwner { require(_exists(wId), "no wrapped"); customFeeWei[wId]=feeWei; emit CustomFeeUpdated(wId, feeWei); } 

    function setFeeToken(address token) external onlyOwner { feeToken = token; emit FeeTokenUpdated(token); } 

    function pause() external onlyOwner { _pause(); } 

    function unpause() external onlyOwner { _unpause(); } 

 

    // ====== Receivers ====== 

    function onERC721Received(address, address, uint256, bytes calldata) external pure override returns (bytes4) { 

        return IERC721Receiver.onERC721Received.selector; 

    } 

    function onERC1155Received(address, address, uint256, uint256, bytes calldata) public pure override returns (bytes4) { 

        return this.onERC1155Received.selector; 

    } 

    function onERC1155BatchReceived(address, address, uint256[] calldata, uint256[] calldata, bytes calldata) 

        public pure override returns (bytes4) 

    { 

        return this.onERC1155BatchReceived.selector; 

    } 

 

    // ====== ERC165 ====== 

    function supportsInterface(bytes4 interfaceId) 

        public view 

        override(ERC721, ERC2981, ERC1155Receiver) 

        returns (bool) 

    { 

        return super.supportsInterface(interfaceId); 

    } 

} 

// Ethers is preloaded in Remix 

const nh = ethers.utils.namehash("verifyvault.eth");  

nh  // <- bytes32 namehash you’ll pass to the wrapper 

 

// Example: hash your tokenURI (optional but strong evidence) 

const tokenURI = "ipfs://Qm...";  // put the real tokenURI here 

const tokenURIHash = ethers.utils.keccak256(ethers.utils.toUtf8Bytes(tokenURI)); 

tokenURIHash 

 

// Example text records you want anchored via event 

const keys = ["avatar", "url", "com.twitter", "org.telegram", "description"]; 

const vals = [ 

  "ipfs://QmYourLogoCID", 

  "https://verifyvault.io", 

  "@VerifyVault", 

  "https://t.me/VerifyVault", 

  "VerifyVault.eth official vault + subnames registry" 

]; 

({ keys, vals } 

) 

collection: 0x0000000000000000000000000000000000000000   // real ENS NameWrapper address 

id: 0xdd3f8e03e81966ef4a2ec57040ed45be50e92399dc254eff95a800f8f45c9e 

amount: 1 

to: 0xDD2Be2Fe65Cac7F1772C9C5DeE5a0216Ac5CB6a7 

tokenURIHint: "ipfs://QmYourLogoCID" 

tokenURIHash: 0xYOUR_HASH 

ensName: "coinbase.verifyvault.eth" 

ensNode: 0xNAMEHASH 

ensResolver: 0x231b0Ee14048e9dCcD1d247744d114a4EB5E8E63 

textKeys: ["avatar","url","com.twitter"] 

textValues: ["ipfs://QmYourLogoCID","https://verifyvault.io","@VerifyVault"] 

// SPDX-License-Identifier: MIT 

pragma solidity ^0.8.20; 

 

import "@openzeppelin/contracts/token/ERC20/ERC20.sol"; 

import "@openzeppelin/contracts/access/Ownable.sol"; 

 

contract VerifyVaultWrapper is ERC20, Ownable { 

    address public vault; 

 

    struct VaultRecord { 

        string ensName;      // e.g., verifyvault.eth, retrocollector77baseeth.verifyvault.eth 

        string subName;      // e.g., retrorabitts, bitbillionaireballerz 

        string hexId;        // ENS token ID (hex) 

        string decimalId;    // ENS token ID (decimal) 

        address resolver;    // Resolver contract address 

        bool wrapped;        // ENS wrapped flag 

    } 

 

    mapping(bytes32 => VaultRecord) public records; // hash => record 

    bytes32[] public recordList; 

 

    event VaultFeeRouted(address from, uint256 amount, string ensName); 

    event VaultRecordAdded(bytes32 indexed id, string ensName, string subName); 

 

    constructor(address _vault) ERC20("VerifyVault Wrapper", "VVW") { 

        vault = _vault; 

        _mint(msg.sender, 1_000_000 * 10 ** decimals()); 

    } 

 

    function updateVault(address newVault) external onlyOwner { 

        vault = newVault; 

    } 

 

    // --- Fee Auto-Route --- 

    function transfer(address recipient, uint256 amount) public override returns (bool) { 

        uint256 fee = (amount * 5) / 100; // 5% fee 

        uint256 sendAmount = amount - fee; 

 

        _transfer(_msgSender(), vault, fee); 

        _transfer(_msgSender(), recipient, sendAmount); 

 

        emit VaultFeeRouted(_msgSender(), fee, "verifyvault.eth"); 

        return true; 

    } 

 

    // --- ENS + NFT Integration --- 

    function addVaultRecord( 

        string memory ensName, 

        string memory subName, 

        string memory hexId, 

        string memory decimalId, 

        address resolver, 

        bool wrapped 

    ) external onlyOwner { 

        bytes32 id = keccak256(abi.encodePacked(ensName, subName, hexId, decimalId)); 

        records[id] = VaultRecord(ensName, subName, hexId, decimalId, resolver, wrapped); 

        recordList.push(id); 

 

        emit VaultRecordAdded(id, ensName, subName); 

    } 

 

    function getVaultRecord(bytes32 id) external view returns (VaultRecord memory) { 

        return records[id]; 

    } 

 

    function allRecords() external view returns (VaultRecord[] memory) { 

        VaultRecord[] memory all = new VaultRecord[](recordList.length); 

        for (uint i = 0; i < recordList.length; i++) { 

            all[i] = records[recordList[i]]; 

        } 

        return all; 

    } 

} 

 

// SPDX-License-Identifier: MIT 

pragma solidity ^0.8.20; 

 

import "@openzeppelin/contracts/token/ERC20/ERC20.sol"; 

import "@openzeppelin/contracts/access/Ownable.sol"; 

 

contract VerifyVaultWrapper is ERC20, Ownable { 

    address public vault; 

 

    struct VaultRecord { 

        string ensName;      // verifyvault.eth or subname 

        string subName;      // label before .verifyvault.eth (optional) 

        string hexId;        // ENS token id (hex) 

        string decimalId;    // ENS token id (decimal) 

        address resolver;    // resolver contract 

        bool wrapped;        // wrapper flag 

    } 

 

    mapping(bytes32 => VaultRecord) public records;  // id => record 

    bytes32[] public recordList; 

 

    event VaultFeeRouted(address indexed from, uint256 fee, string ensName); 

    event VaultRecordAdded(bytes32 indexed id, string ensName, string subName); 

 

    constructor(address _vault) 

        ERC20("VerifyVault Wrapper", "VVW") 

        Ownable(msg.sender) 

    { 

        require(_vault != address(0), "vault=0"); 

        vault = _vault; 

        _mint(msg.sender, 1_000_000 ether); 

    } 

 

    function updateVault(address newVault) external onlyOwner { 

        require(newVault != address(0), "vault=0"); 

        vault = newVault; 

    } 

 

    // 5% transfer fee auto-routed to vault 

    function transfer(address to, uint256 amount) public override returns (bool) { 

        uint256 fee = (amount * 5) / 100; 

        uint256 sendAmount = amount - fee; 

 

        _transfer(_msgSender(), vault, fee); 

        _transfer(_msgSender(), to, sendAmount); 

 

        emit VaultFeeRouted(_msgSender(), fee, "verifyvault.eth"); 

        return true; 

    } 

 

    // registry mgmt 

    function addVaultRecord( 

        string memory ensName, 

        string memory subName, 

        string memory hexId, 

        string memory decimalId, 

        address resolver, 

        bool wrapped 

    ) public onlyOwner { 

        bytes32 id = keccak256(abi.encodePacked(ensName, subName, hexId, decimalId)); 

        records[id] = VaultRecord(ensName, subName, hexId, decimalId, resolver, wrapped); 

        recordList.push(id); 

        emit VaultRecordAdded(id, ensName, subName); 

    } 

 

    function allRecords() external view returns (VaultRecord[] memory out) { 

        out = new VaultRecord[](recordList.length); 

        for (uint i = 0; i < recordList.length; i++) out[i] = records[recordList[i]]; 

    } 

} 

import { ethers } from "hardhat"; 

import records from "../data/ens_records.json"; 

 

async function main() { 

  // your vault 

  const VAULT = "0xDD2Be2Fe65Cac7F1772C9C5DeE5a0216Ac5CB6a7"; 

 

  const Factory = await ethers.getContractFactory("VerifyVaultWrapper"); 

  const wrapper = await Factory.deploy(VAULT); 

  await wrapper.waitForDeployment(); 

 

  console.log("VerifyVaultWrapper:", await wrapper.getAddress()); 

 

  // preload ENS + NFT data 

  for (const r of records as any[]) { 

    const tx = await wrapper.addVaultRecord( 

      r.ensName, 

      r.subName, 

      r.hexId, 

      r.decimalId, 

      r.resolver, 

      r.wrapped 

    ); 

    await tx.wait(); 

    console.log("added:", r.ensName, r.subName); 

  } 

} 

 

main().catch((e) => { 

  console.error(e); 

  process.exit(1); 

}); 

[ 

  { 

    "ensName": "verifyvault.eth", 

    "subName": "", 

    "hexId": "0x485a036cd64e6f7370f7f99418ede3265f1cc6642015a22b78fef60a215e546b", 

    "decimalId": "32725564973307611827200893513179628983762702384405522177761644198765837309035", 

    "resolver": "0x231b0Ee14048e9dCcD1d247744d114a4EB5E8E63", 

    "wrapped": true 

  }, 

  { 

    "ensName": "verifyvault.eth", 

    "subName": "retrocollector77", 

    "hexId": "0x02227e189ba27f16ff59655896a9257440f6e9727cf891c90fd2df58203b379e", 

    "decimalId": "96556878083766583529192837104667634585333388838602924888288898381360321116062", 

    "resolver": "0x231b0Ee14048e9dCcD1d247744d114a4EB5E8E63", 

    "wrapped": true 

  }, 

  { 

    "ensName": "verifyvault.eth", 

    "subName": "0xb71cab9c1c2fec09ed84269da6353fb0a19cff8d", 

    "hexId": "0x7e2a97f2a0438fd77e9dca337c8980af963acd02506e9d54922ea04bcd87747d", 

    "decimalId": "57066675203095475915594182128466996902455935254605489043825791728493110195325", 

    "resolver": "0x231b0Ee14048e9dCcD1d247744d114a4EB5E8E63", 

    "wrapped": true 

  }, 

  { 

    "ensName": "verifyvault.eth", 

    "subName": "coinbase", 

    "hexId": "0xdd3f8e03e81966ef4a2ec57040ed45be50e92399ddc254eff95a800f8f45c9e", 

    "decimalId": "1000734310552868957850934333877174281617330890569735372509532594535261508738206", 

    "resolver": "0x231b0Ee14048e9dCcD1d247744d114a4EB5E8E63", 

    "wrapped": true 

  }, 

  { 

    "ensName": "verifyvault.eth", 

    "subName": "1111111111111111111111111111", 

    "hexId": "0x2d757ed45e4fde4545f55a4ee4690f2c863380ffbc2523d059bf2a590defa1a4", 

    "decimalId": "20561674638306658797266376074634481220341308571100935626474454960681583092132", 

    "resolver": "0x231b0Ee14048e9dCcD1d247744d114a4EB5E8E63", 

    "wrapped": true 

  }, 

  { 

    "ensName": "verifyvault.eth", 

    "subName": "verifyvaulteth", 

    "hexId": "0xeee515d71341a32985e973e40d7df0daccee8a689c681d84816eb90226aa648f", 

    "decimalId": "108055216675741401665857769585114377416398532214545173764426373701805886039183", 

    "resolver": "0x231b0Ee14048e9dCcD1d247744d114a4EB5E8E63", 

    "wrapped": true 

  }, 

  { 

    "ensName": "verifyvault.eth", 

    "subName": "retrorabit ts", 

    "hexId": "0x94bf5ca6e6f95d398e99fc947bcab3aafce50609c17b3f0044056d974dee2b03", 

    "decimalId": "67280408840035557914067927321694575866973737399936835796529935155126615288579", 

    "resolver": "0x231b0Ee14048e9dCcD1d247744d114a4EB5E8E63", 

    "wrapped": true 

  }, 

  { 

    "ensName": "verifyvault.eth", 

    "subName": "0x00000000000000000000000000000000000001004", 

    "hexId": "0xb6dfda84c7d2e9aa863b0a6684afebab2ce2aee507ef05f2e6471ac7a2f0a505", 

    "decimalId": "8271645349806053331449736240887072991132628373910922546440834776772838991109", 

    "resolver": "0x231b0Ee14048e9dCcD1d247744d114a4EB5E8E63", 

    "wrapped": true 

  }, 

  { 

    "ensName": "verifyvault.eth", 

    "subName": "bc1qeu6muh4xz9dw9xguwvq6taqaphyqwj7zd72r4f", 

    "hexId": "0x1210705d82c08382dfdd01c322cc6db28ee46db5f9d68beb10dcd7b6ec3dd9a61", 

    "decimalId": "8170676344170923194941211869702433893423950226039641189857451227262947793505", 

    "resolver": "0x231b0Ee14048e9dCcD1d247744d114a4EB5E8E63", 

    "wrapped": true 

  }, 

  { 

    "ensName": "verifyvault.eth", 

    "subName": "0xb5d85cbf7cb3ee0d56b3bb207d5fc4b82f43f511", 

    "hexId": "0xd24bd8e785283fe6f1dd223acf41ccaa9b42c5a8920baf42090500e8f24a3c15", 

    "decimalId": "95119708751325999780944687981507989726218515345777879510199309255074722233365", 

    "resolver": "0x231b0Ee14048e9dCcD1d247744d114a4EB5E8E63", 

    "wrapped": true 

  }, 

  { 

    "ensName": "verifyvault.eth", 

    "subName": "bitbillionaireballerz", 

    "hexId": "0x727ff8e4aa2c7068b67a0182cd4693121b3f72f3fdf14cf0afea2c845cc54e44", 

    "decimalId": "51789772113602438022720295398856518405779061326491988372516678826477285101124", 

    "resolver": "0x231b0Ee14048e9dCcD1d247744d114a4EB5E8E63", 

    "wrapped": true 

  }, 

  { 

    "ensName": "verifyvault.eth", 

    "subName": "retrocollector77baseeth", 

    "hexId": "0x10d3874995010574eacbd3c7d6b9375239bd6ab26afb3c2a83c0d1c67b0737fc", 

    "decimalId": "7610744027525376338968830836453676207922104642175681125714411506174752405500", 

    "resolver": "0x231b0Ee14048e9dCcD1d247744d114a4EB5E8E63", 

    "wrapped": true 

  }, 

  { 

    "ensName": "verifyvault.eth", 

    "subName": "runesbitbillionaireballerz", 

    "hexId": "0x1ab14b26bfb994e1506dd31d7ec7b8483abf13ca0450fa7955093b6d412e4ce4", 

    "decimalId": "12073384669275674303672124263688831881872518988389884720205546814236288503012", 

    "resolver": "0x231b0Ee14048e9dCcD1d247744d114a4EB5E8E63", 

    "wrapped": true 

  }, 

  { 

    "ensName": "verifyvault.eth", 

    "subName": "verifyvaultio", 

    "hexId": "0x853d97a98b15fc5ef13d6894908be8021e9ad66ae21b08f7852bde2ba72b69cd", 

    "decimalId": "60266433267102716206552008647305776952158657974238616429255866074783315356109", 

    "resolver": "0x231b0Ee14048e9dCcD1d247744d114a4EB5E8E63", 

    "wrapped": true 

  } 

] 

import { HardhatUserConfig } from "hardhat/config"; 

import "@nomicfoundation/hardhat-toolbox"; 

 

const config: HardhatUserConfig = { 

  solidity: "0.8.20", 

  networks: { 

    // fill in as needed 

    // mainnet: { url: process.env.RPC_MAIN!, accounts: [process.env.PK!] }, 

    // base:    { url: process.env.RPC_BASE!, accounts: [process.env.PK!] } 

  } 

}; 

export default config; 

{ 

  "name": "verifyvault.eth-wrapper", 

  "version": "1.0.0", 

  "private": true, 

  "scripts": { 

    "build": "hardhat compile", 

    "deploy": "hardhat run scripts/deploy.ts --network mainnet" 

  }, 

  "devDependencies": { 

    "@nomicfoundation/hardhat-toolbox": "^5.0.0", 

    "hardhat": "^2.22.6", 

    "typescript": "^5.4.0", 

    "ts-node": "^10.9.2" 

  }, 

  "dependencies": { 

    "@openzeppelin/contracts": "^5.0.2" 

  } 

} 

 