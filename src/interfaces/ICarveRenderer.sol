// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import {
    GenerativeSettings,
    TraitDTO,
    LinkedTraitDTO,
    Trait,
    Layer
} from "../CarveRenderer.sol";

/**
 * @title ICarveRenderer
 * @notice Interface for the CarveRenderer contract used by CarveGenerative collections.
 */
interface ICarveRenderer {
    function settings() external view returns (GenerativeSettings memory);

    function assignRandomDataIds(uint256 quantity, uint256 startTokenId) external;

    function getTokenDataId(uint256 tokenId) external view returns (uint256);

    function dataIdToTraits(uint256 dataId)
        external
        view
        returns (uint256[] memory);

    function tokenURI(
        string memory tokenName,
        uint256 tokenId,
        string memory tokenBaseURI
    ) external view returns (string memory);

    function isRevealed() external view returns (bool);

    function tokenIdToSVG(uint256 tokenId) external view returns (string memory);

    function traitDetails(uint256 layerIndex, uint256 traitIndex)
        external
        view
        returns (Trait memory);

    function traitData(uint256 layerIndex, uint256 traitIndex)
        external
        view
        returns (bytes memory);

    function getLinkedTraits(uint256 layerIndex, uint256 traitIndex)
        external
        view
        returns (uint256[] memory);

    function addLayer(
        uint256 index,
        string calldata name,
        uint256 primeNumber,
        TraitDTO[] calldata _traits,
        uint256 _numberOfLayers
    ) external;

    function addTrait(
        uint256 layerIndex,
        uint256 traitIndex,
        TraitDTO calldata _trait
    ) external;

    function setLinkedTraits(LinkedTraitDTO[] calldata _linkedTraits) external;

    function setRenderOfTokenId(uint256 tokenId, bool renderOffChain) external;

    function setPlaceholderImage(string calldata placeholderImage) external;

    function setDescription(string calldata description) external;

    function commitReveal() external;

    function finalizeReveal() external;

    function setTraitOverride(
        uint256 dataId,
        uint256[] calldata traitIndices
    ) external;
}

