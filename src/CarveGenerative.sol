// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import { ERC721SeaDrop } from "./ERC721SeaDrop.sol";

import { LibPRNG } from "solady/utils/LibPRNG.sol";
import { Base64 } from "solady/utils/Base64.sol";
import { SSTORE2 } from "solady/utils/SSTORE2.sol";
import { DynamicBufferLib } from "solady/utils/DynamicBufferLib.sol";

struct LinkedTraitDTO {
    uint256[] traitA;
    uint256[] traitB;
}

struct TraitDTO {
    string name;
    string mimetype;
    uint256 occurrence;
    bytes data;
    bool hide;
    bool useExistingData;
    uint256 existingDataIndex;
}

struct Trait {
    string name;
    string mimetype;
    uint256 occurrence;
    address dataPointer;
    bool hide;
}

struct Layer {
    string name;
    uint256 primeNumber;
    uint256 numberOfTraits;
}

struct GenerativeSettings {
    string description;
    string placeholderImage;
}

/**
 * @title  CarveGenerative
 * @notice A generative art NFT contract that integrates with SeaDrop for minting.
 *         This contract handles trait/layer management and on-chain rendering.
 *         Minting is handled entirely through SeaDrop.
 */
contract CarveGenerative is ERC721SeaDrop {
    using DynamicBufferLib for DynamicBufferLib.DynamicBuffer;
    using LibPRNG for LibPRNG.PRNG;

    event MetadataUpdate(uint256 _tokenId);

    error NotAvailable();
    error InvalidInput();
    error NotAuthorized();
    error InvalidTraitSelection(uint256 layerIndex, uint256 randomInput);

    mapping(uint256 => Layer) private layers;
    mapping(uint256 => mapping(uint256 => Trait)) private traits;
    mapping(uint256 => mapping(uint256 => uint256[])) private linkedTraits;
    mapping(uint256 => bool) private renderTokenOffChain;
    mapping(uint256 => uint256[]) private traitOverride;

    // Fisher-Yates storage for mint-time randomness
    mapping(uint256 => uint256) private tokenDataIds;
    mapping(uint256 => uint256) private _availableDataIds;
    uint256 private remainingDataIds;

    uint256 private revealSeed;
    uint256 private numberOfLayers;

    GenerativeSettings public settings;

    modifier whenUnsealed() {
        if (_maxSupply > 0 && _totalMinted() >= _maxSupply) {
            revert NotAuthorized();
        }
        _;
    }

    /**
     * @notice Deploy the token contract with its name, symbol,
     *         allowed SeaDrop addresses, and generative settings.
     */
    constructor(
        string memory name,
        string memory symbol,
        address[] memory allowedSeaDrop,
        GenerativeSettings memory _settings,
        uint256 _maxSupply
    ) ERC721SeaDrop(name, symbol, allowedSeaDrop) {
        settings = _settings;

        // Initialize Fisher-Yates dataId pool
        remainingDataIds = _maxSupply;

        // Auto-reveal if no placeholder is set (immediate reveal mode)
        if (bytes(_settings.placeholderImage).length == 0) {
            revealSeed = uint256(
                keccak256(
                    abi.encodePacked(
                        block.timestamp,
                        block.number,
                        block.difficulty,
                        tx.gasprice
                    )
                )
            );
        }
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

        // Use _nextTokenId() to get the actual starting token ID
        // This accounts for _startTokenId() = 1
        uint256 startTokenId = _nextTokenId();

        // Always assign random dataIds at mint time using Fisher-Yates
        // Even in delayed reveal, we store them - reveal just adds rotation offset
        assignRandomDataIds(quantity, startTokenId);

        // Call parent _mint to actually mint the tokens
        super._mint(to, quantity);
    }

    function selectTrait(uint256 layerIndex, uint256 randomInput)
        internal
        view
        returns (uint256)
    {
        uint256 currentLowerBound = 0;
        for (uint256 i = 0; i < layers[layerIndex].numberOfTraits; ) {
            uint256 thisPercentage = traits[layerIndex][i].occurrence;
            if (
                randomInput >= currentLowerBound &&
                randomInput < currentLowerBound + thisPercentage
            ) return i;
            currentLowerBound = currentLowerBound + thisPercentage;
            unchecked {
                ++i;
            }
        }

        revert InvalidTraitSelection(layerIndex, randomInput);
    }

    /**
     * @notice Gas-efficient Fisher-Yates: gets and removes a dataId from the pool
     * @dev Only stores swapped values, not the entire array
     */
    function getAvailableDataIdAtIndex(
        uint256 indexToUse,
        uint256 currentArraySize
    ) private returns (uint256 result) {
        uint256 valAtIndex = _availableDataIds[indexToUse];
        uint256 lastIndex = currentArraySize - 1;
        uint256 lastValInArray = _availableDataIds[lastIndex];

        // Return actual value or index if unset (virtual array)
        result = valAtIndex == 0 ? indexToUse : valAtIndex;

        // Swap with last element (Fisher-Yates)
        if (indexToUse != lastIndex) {
            _availableDataIds[indexToUse] = lastValInArray == 0
                ? lastIndex
                : lastValInArray;
        }

        // Clean up last element if it was swapped
        if (lastValInArray != 0) {
            delete _availableDataIds[lastIndex];
        }
    }

    /**
     * @notice Assigns random dataIds to tokens at mint time using Fisher-Yates
     * @dev Called by mintSeaDrop to assign dataIds before minting
     */
    function assignRandomDataIds(uint256 quantity, uint256 startTokenId)
        private
    {
        // Generate pseudo-random entropy for this batch
        uint256 batchEntropy = uint256(
            keccak256(
                abi.encodePacked(
                    block.timestamp,
                    block.difficulty,
                    block.number,
                    blockhash(block.number - 1),
                    tx.gasprice,
                    msg.sender,
                    startTokenId
                )
            )
        );

        LibPRNG.PRNG memory prng = LibPRNG.PRNG(batchEntropy);

        // Fisher-Yates: pick random dataId from remaining pool for each token
        for (uint256 i = 0; i < quantity; i++) {
            uint256 currentSize = remainingDataIds - i;
            uint256 randomIndex = prng.uniform(currentSize);
            uint256 dataId = getAvailableDataIdAtIndex(
                randomIndex,
                currentSize
            );
            tokenDataIds[startTokenId + i] = dataId;
        }

        remainingDataIds -= quantity;
    }

    /**
     * @notice Get the dataId for a given tokenId
     * @dev Supports both immediate reveal and delayed reveal modes
     */
    function getTokenDataId(uint256 tokenId) public view returns (uint256) {
        if (!_exists(tokenId)) {
            revert NotAvailable();
        }

        // Get the stored dataId from mint time (Fisher-Yates assigned)
        uint256 storedDataId = tokenDataIds[tokenId];

        // Check if using immediate reveal or delayed reveal
        if (bytes(settings.placeholderImage).length == 0) {
            // Immediate reveal: use stored dataId as-is
            return storedDataId;
        } else {
            // Delayed reveal: apply rotation offset once revealed
            if (revealSeed == 0) {
                revert NotAvailable();
            }

            // Rotate all dataIds by revealSeed
            // This shifts everyone equally, maintaining Fisher-Yates randomness
            return (storedDataId + revealSeed) % _maxSupply;
        }
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
        if (revealSeed == 0) {
            revert NotAvailable();
        }

        // Check for trait override first
        if (traitOverride[dataId].length > 0) {
            return traitOverride[dataId];
        }

        uint256[] memory traitIndices = new uint256[](numberOfLayers);
        bool[] memory modifiedLayers = new bool[](numberOfLayers);
        uint256 traitSeed = revealSeed % _maxSupply;

        for (uint256 i = 0; i < numberOfLayers; ) {
            if (modifiedLayers[i] == false) {
                uint256 traitRangePosition = ((dataId + i + traitSeed) *
                    layers[i].primeNumber) % _maxSupply;
                traitIndices[i] = selectTrait(i, traitRangePosition);
            }

            uint256 traitIndex = traitIndices[i];
            if (linkedTraits[i][traitIndex].length > 0) {
                uint256 linkedLayer = linkedTraits[i][traitIndex][0];
                traitIndices[linkedLayer] = linkedTraits[i][traitIndex][1];
                modifiedLayers[linkedLayer] = true;
            }
            unchecked {
                ++i;
            }
        }

        return traitIndices;
    }

    /**
     * @notice Generate SVG from trait indices
     * @dev Works directly with uint256[] - no string parsing!
     */
    function traitsToSVG(uint256[] memory traitIndices)
        internal
        view
        returns (string memory)
    {
        DynamicBufferLib.DynamicBuffer memory svgBuffer;
        svgBuffer.reserve(1024 * 64); // Pre-allocate 64KB

        svgBuffer.p(
            '<svg width="1200" height="1200" viewBox="0 0 1200 1200" version="1.2" xmlns="http://www.w3.org/2000/svg" style="background-image:url('
        );

        for (uint256 i = 0; i < numberOfLayers - 1; ) {
            uint256 thisTraitIndex = traitIndices[i];
            svgBuffer.p(
                abi.encodePacked(
                    "data:",
                    traits[i][thisTraitIndex].mimetype,
                    ";base64,",
                    Base64.encode(
                        SSTORE2.read(traits[i][thisTraitIndex].dataPointer)
                    ),
                    "),url("
                )
            );
            unchecked {
                ++i;
            }
        }

        uint256 lastTraitIndex = traitIndices[numberOfLayers - 1];
        svgBuffer.p(
            abi.encodePacked(
                "data:",
                traits[numberOfLayers - 1][lastTraitIndex].mimetype,
                ";base64,",
                Base64.encode(
                    SSTORE2.read(
                        traits[numberOfLayers - 1][lastTraitIndex].dataPointer
                    )
                ),
                ');background-repeat:no-repeat;background-size:contain;background-position:center;image-rendering:-webkit-optimize-contrast;-ms-interpolation-mode:nearest-neighbor;image-rendering:-moz-crisp-edges;image-rendering:pixelated;"></svg>'
            )
        );

        return
            string(
                abi.encodePacked(
                    "data:image/svg+xml;base64,",
                    Base64.encode(svgBuffer.data)
                )
            );
    }

    /**
     * @notice Generate metadata attributes from trait indices
     * @dev Works directly with uint256[] - no string parsing!
     */
    function traitsToMetadata(uint256[] memory traitIndices)
        internal
        view
        returns (string memory)
    {
        DynamicBufferLib.DynamicBuffer memory metadataBuffer;
        metadataBuffer.reserve(1024 * 8); // Pre-allocate 8KB
        metadataBuffer.p("[");
        bool afterFirstTrait;

        for (uint256 i = 0; i < numberOfLayers; ) {
            uint256 thisTraitIndex = traitIndices[i];
            if (traits[i][thisTraitIndex].hide == false) {
                if (afterFirstTrait) {
                    metadataBuffer.p(",");
                }
                metadataBuffer.p(
                    abi.encodePacked(
                        '{"trait_type":"',
                        layers[i].name,
                        '","value":"',
                        traits[i][thisTraitIndex].name,
                        '"}'
                    )
                );
                if (afterFirstTrait == false) {
                    afterFirstTrait = true;
                }
            }

            if (i == numberOfLayers - 1) {
                metadataBuffer.p("]");
            }

            unchecked {
                ++i;
            }
        }

        return string(metadataBuffer.data);
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

        DynamicBufferLib.DynamicBuffer memory jsonBuffer;

        jsonBuffer.p(
            abi.encodePacked(
                '{"name":"',
                name(),
                " #",
                _toString(tokenId),
                '","description":"',
                settings.description,
                '",'
            )
        );

        if (revealSeed == 0) {
            jsonBuffer.p(
                abi.encodePacked('"image":"', settings.placeholderImage, '"}')
            );
        } else {
            // Get traits directly - no string conversion needed!
            uint256[] memory traitIndices = dataIdToTraits(
                getTokenDataId(tokenId)
            );

            if (
                bytes(_tokenBaseURI).length > 0 && renderTokenOffChain[tokenId]
            ) {
                // Off-chain rendering URL
                // External renderer can call dataIdToTraits(getTokenDataId(tokenId)) to get traits
                jsonBuffer.p(
                    abi.encodePacked(
                        '"image":"',
                        _tokenBaseURI,
                        _toString(tokenId),
                        "?chainId=",
                        _toString(block.chainid),
                        '",'
                    )
                );
            } else {
                // On-chain rendering - use traits directly, no parsing!
                string memory svgCode = traitsToSVG(traitIndices);

                jsonBuffer.p(abi.encodePacked('"image":"', svgCode, '",'));
            }

            // Use traits directly for metadata - no parsing!
            jsonBuffer.p(
                abi.encodePacked(
                    '"attributes":',
                    traitsToMetadata(traitIndices),
                    "}"
                )
            );
        }

        return
            string(
                abi.encodePacked(
                    "data:application/json;base64,",
                    Base64.encode(jsonBuffer.data)
                )
            );
    }

    function didMintEnd() public view returns (bool) {
        return _totalMinted() == _maxSupply;
    }

    function isRevealed() public view returns (bool) {
        return revealSeed != 0;
    }

    function tokenIdToSVG(uint256 tokenId) public view returns (string memory) {
        if (revealSeed == 0) {
            return settings.placeholderImage;
        }
        // Use traits directly - no string conversion!
        return traitsToSVG(dataIdToTraits(getTokenDataId(tokenId)));
    }

    function traitDetails(uint256 layerIndex, uint256 traitIndex)
        public
        view
        returns (Trait memory)
    {
        return traits[layerIndex][traitIndex];
    }

    function traitData(uint256 layerIndex, uint256 traitIndex)
        public
        view
        returns (bytes memory)
    {
        return SSTORE2.read(traits[layerIndex][traitIndex].dataPointer);
    }

    function getLinkedTraits(uint256 layerIndex, uint256 traitIndex)
        public
        view
        returns (uint256[] memory)
    {
        return linkedTraits[layerIndex][traitIndex];
    }

    function addLayer(
        uint256 index,
        string calldata name,
        uint256 primeNumber,
        TraitDTO[] calldata _traits,
        uint256 _numberOfLayers
    ) public onlyOwner whenUnsealed {
        layers[index] = Layer(name, primeNumber, _traits.length);
        numberOfLayers = _numberOfLayers;
        for (uint256 i = 0; i < _traits.length; ) {
            address dataPointer;
            if (_traits[i].useExistingData) {
                dataPointer = traits[index][_traits[i].existingDataIndex]
                    .dataPointer;
            } else {
                dataPointer = SSTORE2.write(_traits[i].data);
            }
            traits[index][i] = Trait(
                _traits[i].name,
                _traits[i].mimetype,
                _traits[i].occurrence,
                dataPointer,
                _traits[i].hide
            );
            unchecked {
                ++i;
            }
        }
    }

    function addTrait(
        uint256 layerIndex,
        uint256 traitIndex,
        TraitDTO calldata _trait
    ) public onlyOwner whenUnsealed {
        address dataPointer;
        if (_trait.useExistingData) {
            dataPointer = traits[layerIndex][traitIndex].dataPointer;
        } else {
            dataPointer = SSTORE2.write(_trait.data);
        }
        traits[layerIndex][traitIndex] = Trait(
            _trait.name,
            _trait.mimetype,
            _trait.occurrence,
            dataPointer,
            _trait.hide
        );
    }

    function setLinkedTraits(LinkedTraitDTO[] calldata _linkedTraits)
        public
        onlyOwner
        whenUnsealed
    {
        for (uint256 i = 0; i < _linkedTraits.length; ) {
            linkedTraits[_linkedTraits[i].traitA[0]][
                _linkedTraits[i].traitA[1]
            ] = [_linkedTraits[i].traitB[0], _linkedTraits[i].traitB[1]];
            unchecked {
                ++i;
            }
        }
    }

    function setRenderOfTokenId(uint256 tokenId, bool renderOffChain) external {
        if (msg.sender != ownerOf(tokenId)) {
            revert NotAuthorized();
        }
        renderTokenOffChain[tokenId] = renderOffChain;

        emit MetadataUpdate(tokenId);
    }

    function setPlaceholderImage(string calldata placeholderImage)
        external
        onlyOwner
    {
        // Only allow setting placeholder if not yet revealed
        if (revealSeed == 0 && bytes(placeholderImage).length != 0) {
            settings.placeholderImage = placeholderImage;
        }
    }

    function setDescription(string calldata description) external onlyOwner {
        settings.description = description;
    }

    function setRevealSeed() external onlyOwner {
        if (revealSeed != 0) {
            revert NotAuthorized();
        }
        revealSeed = uint256(
            keccak256(
                abi.encodePacked(
                    tx.gasprice,
                    block.number,
                    block.timestamp,
                    block.difficulty,
                    blockhash(block.number - 1),
                    msg.sender
                )
            )
        );

        emit BatchMetadataUpdate(1, _maxSupply);
    }

    function setTraitOverride(uint256 tokenId, uint256[] calldata traitIndices)
        external
        onlyOwner
    {
        if (traitIndices.length != numberOfLayers) {
            revert InvalidInput();
        }

        uint256 dataId = getTokenDataId(tokenId);
        traitOverride[dataId] = traitIndices;

        emit MetadataUpdate(tokenId);
    }
}
