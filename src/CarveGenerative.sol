// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import { ERC721SeaDrop } from "./ERC721SeaDrop.sol";

import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";

import { ISeaDrop } from "./interfaces/ISeaDrop.sol";
import { PublicDrop } from "./lib/SeaDropStructs.sol";
import { CarveRenderer, GenerativeSettings, TraitDTO, LinkedTraitDTO, Trait, Layer } from "./CarveRenderer.sol";

/**
 * @title  CarveGenerative
 * @notice A generative art NFT contract that integrates with SeaDrop for minting.
 *         This contract handles trait/layer management and on-chain rendering.
 *         Minting is handled entirely through SeaDrop.
 */
contract CarveGenerative is ERC721SeaDrop {
    event MetadataUpdate(uint256 _tokenId);
    event ContractSealed();
    event RevealCommitScheduled(uint256 targetBlockNumber);
    event CreatorProceedsWithdrawn(address recipient, uint256 amount);

    error NotAvailable();
    error InvalidInput();
    error NotAuthorized();

    bool private _sealed;

    uint256 private constant COLLECTOR_FEE_PER_TOKEN = 0.000777 ether;
    address payable private constant CARVE_FEE_RECIPIENT =
        payable(0x29FbB84b835F892EBa2D331Af9278b74C595EDf1);
    uint256 private pendingSeaDropQuantity;
    CarveRenderer public renderer;

    modifier whenUnsealed() {
        if (_sealed) {
            revert NotAuthorized();
        }
        _;
    }

    receive() external payable {
        uint256 quantity = pendingSeaDropQuantity;
        if (quantity == 0) {
            revert InvalidInput();
        }

        pendingSeaDropQuantity = 0;

        uint256 cappedFee = COLLECTOR_FEE_PER_TOKEN * quantity;
        uint256 fee = msg.value > cappedFee ? cappedFee : msg.value;
        if (fee > 0) {
            SafeTransferLib.safeTransferETH(CARVE_FEE_RECIPIENT, fee);
        }
    }

    function withdrawCreatorProceeds(address payable recipient, uint256 amount)
        external
        onlyOwner
        nonReentrant
    {
        if (amount == 0 || amount > address(this).balance) {
            revert InvalidInput();
        }
        if (recipient == address(0)) {
            recipient = payable(owner());
        }
        SafeTransferLib.safeTransferETH(recipient, amount);
        emit CreatorProceedsWithdrawn(recipient, amount);
    }

    /**
     * @notice Deploy the token contract with its name, symbol,
     *         allowed SeaDrop addresses, and generative settings.
     */
    constructor(
        string memory name,
        string memory symbol,
        address[] memory allowedSeaDrop,
        GenerativeSettings memory _settings
    ) ERC721SeaDrop(name, symbol, allowedSeaDrop) {
        _setMaxSupplyInternal(_settings.maxSupply);
        _lockMaxSupply();

        renderer = new CarveRenderer(_settings);
    }

    /**
     * @notice Override internal _mint to assign random dataIds at mint time.
     *         This hooks into both SeaDrop mints and any other mint functions.
     *
     * @param to       The address to mint to.
     * @param quantity The number of tokens to mint.
     */
    function _mint(address to, uint256 quantity) internal virtual override {
        uint256 totalMinted = _totalMinted();

        // Check max supply before minting
        if (totalMinted + quantity > _maxSupply) {
            revert MintQuantityExceedsMaxSupply(
                totalMinted + quantity,
                _maxSupply
            );
        }

        pendingSeaDropQuantity = quantity;

        // Use _nextTokenId() to get the actual starting token ID
        // This accounts for _startTokenId() = 1
        uint256 startTokenId = _nextTokenId();

        // Always assign random dataIds at mint time using Fisher-Yates
        // Even in delayed reveal, we store them - reveal just adds rotation offset
        renderer.assignRandomDataIds(quantity, startTokenId);

        // Call parent _mint to actually mint the tokens
        super._mint(to, quantity);
    }

    function sealContract() external onlyOwner {
        if (_sealed) {
            return;
        }
        _sealed = true;
        emit ContractSealed();
    }

    function updatePublicDrop(
        address seaDropImpl,
        PublicDrop calldata publicDrop
    ) external override {
        if (publicDrop.mintPrice < COLLECTOR_FEE_PER_TOKEN) {
            revert InvalidInput();
        }
        _onlyOwnerOrSelf();
        _onlyAllowedSeaDrop(seaDropImpl);
        ISeaDrop(seaDropImpl).updatePublicDrop(publicDrop);
    }

    function updateCreatorPayoutAddress(
        address seaDropImpl,
        address /* payoutAddress */
    ) external override {
        _onlyOwnerOrSelf();
        _onlyAllowedSeaDrop(seaDropImpl);
        ISeaDrop(seaDropImpl).updateCreatorPayoutAddress(address(this));
    }

    /**
     * @notice Get the dataId for a given tokenId
     * @dev Supports both immediate reveal and delayed reveal modes
     */
    function getTokenDataId(uint256 tokenId) public view returns (uint256) {
        if (!_exists(tokenId)) {
            revert NotAvailable();
        }

        return renderer.getTokenDataId(tokenId);
    }

    /**
     * @notice Get trait indices for a given dataId
     * @dev This is the core function - returns array of trait indices
     */
    function dataIdToTraits(uint256 dataId)
        public
        view
        returns (uint256[] memory)
    {
        return renderer.dataIdToTraits(dataId);
    }

    function tokenURI(uint256 tokenId)
        public
        view
        override
        returns (string memory)
    {
        if (!_exists(tokenId)) {
            revert InvalidInput();
        }

        return renderer.tokenURI(name(), tokenId, _tokenBaseURI);
    }

    function didMintEnd() public view returns (bool) {
        return _totalMinted() == _maxSupply;
    }

    function isRevealed() public view returns (bool) {
        return renderer.isRevealed();
    }

    function tokenIdToSVG(uint256 tokenId) public view returns (string memory) {
        if (!_exists(tokenId)) {
            revert NotAvailable();
        }

        return renderer.tokenIdToSVG(tokenId);
    }

    function traitDetails(uint256 layerIndex, uint256 traitIndex)
        public
        view
        returns (Trait memory)
    {
        return renderer.traitDetails(layerIndex, traitIndex);
    }

    function traitData(uint256 layerIndex, uint256 traitIndex)
        public
        view
        returns (bytes memory)
    {
        return renderer.traitData(layerIndex, traitIndex);
    }

    function getLinkedTraits(uint256 layerIndex, uint256 traitIndex)
        public
        view
        returns (uint256[] memory)
    {
        return renderer.getLinkedTraits(layerIndex, traitIndex);
    }

    function addLayer(
        uint256 index,
        string calldata name,
        uint256 primeNumber,
        TraitDTO[] calldata _traits,
        uint256 _numberOfLayers
    ) public onlyOwner whenUnsealed {
        renderer.addLayer(index, name, primeNumber, _traits, _numberOfLayers);
    }

    function addTrait(
        uint256 layerIndex,
        uint256 traitIndex,
        TraitDTO calldata _trait
    ) public onlyOwner whenUnsealed {
        renderer.addTrait(layerIndex, traitIndex, _trait);
    }

    function setLinkedTraits(LinkedTraitDTO[] calldata _linkedTraits)
        public
        onlyOwner
        whenUnsealed
    {
        renderer.setLinkedTraits(_linkedTraits);
    }

    function setRenderOfTokenId(uint256 tokenId, bool renderOffChain) external {
        if (msg.sender != ownerOf(tokenId)) {
            revert NotAuthorized();
        }
        renderer.setRenderOfTokenId(tokenId, renderOffChain);

        emit MetadataUpdate(tokenId);
    }

    function setPlaceholderImage(string calldata placeholderImage)
        external
        onlyOwner
    {
        renderer.setPlaceholderImage(placeholderImage);
    }

    function setDescription(string calldata description) external onlyOwner {
        renderer.setDescription(description);
    }

    function commitReveal() external onlyOwner {
        renderer.commitReveal();

        emit RevealCommitScheduled(block.number + 32);
    }

    function finalizeReveal() external onlyOwner {
        renderer.finalizeReveal();

        emit BatchMetadataUpdate(1, _maxSupply);
    }

    function setTraitOverride(
        uint256 dataId,
        uint256[] calldata traitIndices,
        uint256 tokenId
    )
        external
        onlyOwner
    {
        renderer.setTraitOverride(dataId, traitIndices);

        if (tokenId != 0 && _exists(tokenId)) {
            emit MetadataUpdate(tokenId);
        }
    }
}
