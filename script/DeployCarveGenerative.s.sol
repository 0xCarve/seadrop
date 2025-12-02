// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import { Script } from "forge-std/Script.sol";
import { CarveGenerative, GenerativeSettings } from "../src/CarveGenerative.sol";

/**
 * @notice Foundry script to deploy `CarveGenerative`.
 *
 * Environment variables:
 *  - SEADROP_ADDRESS : address of the allowed SeaDrop contract (required)
 *  - TOKEN_NAME      : optional, defaults to "Carve Test"
 *  - TOKEN_SYMBOL    : optional, defaults to "CARVE"
 *  - TOKEN_DESC      : optional, defaults to "Carve generative collection"
 *  - PLACEHOLDER_URI : optional, defaults to empty string (immediate reveal)
 *  - MAX_SUPPLY      : uint256 max supply (required)
 *
 * Example:
 *  forge script script/DeployCarveGenerative.s.sol:DeployCarveGenerative \
 *      --rpc-url $BASE_RPC_URL \
 *      --broadcast \
 *      --private-key $PRIVATE_KEY
 */
contract DeployCarveGenerative is Script {
    address internal constant DEFAULT_SEADROP =
        0x00005EA00Ac477B1030CE78506496e8C2dE24bf5;

    function run() external returns (CarveGenerative deployed) {
        address seaDropAddress = DEFAULT_SEADROP;
        if (vm.envExists("SEADROP_ADDRESS")) {
            seaDropAddress = vm.envAddress("SEADROP_ADDRESS");
        }
        uint256 maxSupply = vm.envUint("MAX_SUPPLY");

        string memory name = vm.envOr("TOKEN_NAME", string("Carve Test"));
        string memory symbol = vm.envOr("TOKEN_SYMBOL", string("CARVE"));
        string memory description = vm.envOr(
            "TOKEN_DESC",
            string("Carve generative collection")
        );
        string memory placeholder = vm.envOr(
            "PLACEHOLDER_URI",
            string("")
        );

        address[] memory allowedSeaDrop = new address[](1);
        allowedSeaDrop[0] = seaDropAddress;

        GenerativeSettings memory settings = GenerativeSettings({
            description: description,
            placeholderImage: placeholder,
            maxSupply: maxSupply
        });

        vm.startBroadcast();
        deployed = new CarveGenerative(
            name,
            symbol,
            allowedSeaDrop,
            settings
        );
        vm.stopBroadcast();
    }
}


